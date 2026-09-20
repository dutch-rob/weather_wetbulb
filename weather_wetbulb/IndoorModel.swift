//
//  IndoorModel.swift
//  weather_wetbulb
//
//  The indoor comfort model: a lumped-parameter (RC) thermal model of the
//  house, fitted by least squares.
//
//  It predicts the *rate of change* of indoor dry-bulb temperature and indoor
//  dew point, rather than their levels. That matters for three reasons:
//
//   - A house has thermal mass, so the level at time t is mostly explained by
//     the level at t-1. Regressing on levels would score well while learning
//     nothing; regressing on the change forces the fit to explain the physics.
//   - Forecasting is then just integrating the model forward step by step, so
//     the same coefficients serve the "what if the cooler stays off" scenarios.
//   - The HVAC transitions we want to detect (cooler on, AC off, …) appear as
//     step changes in these rates, so they fall out as residual jumps rather
//     than needing a separate detector.
//
//  Two equations are fitted independently, sharing the same observation rows:
//
//    dT_in/dt = a0
//             + a1 (T_out - T_in)              conduction through the envelope
//             + a2 solar                       solar gain
//             + [infiltration terms] x (T_out - T_in)
//             + a7 rain                        wet walls lose heat evaporatively
//             + a8 cooler (WB_out - T_in)      evaporative cooling pulls the
//                                              indoor temperature toward the
//                                              outdoor WET-BULB, its floor
//             + a9 ac                          compressor removes heat
//             + a10 heat                       burner adds heat
//
//    dD_in/dt = b0
//             + b1 (D_out - D_in)              moisture exchange with outside
//             + [infiltration terms] x (D_out - D_in)
//             + b6 rain
//             + b7 cooler (WB_out - D_in)      the cooler adds moisture, so the
//                                              indoor dew point climbs toward
//                                              the outdoor wet-bulb
//             + b8 ac                          the coil condenses water out
//             + b9 heat                        expected ~0: heating moves
//                                              temperature, not moisture
//
//  The infiltration terms are wind, gust-excess, and wind x sin/cos of the wind
//  direction, each multiplied by the driving gradient. See InfiltrationTerms
//  for why direction is encoded as a sine/cosine pair rather than as degrees.
//
//  Fit quality is always measured on a held-out *later* slice, never in-sample.
//  Source selection swaps variables in and out looking for improvement, and
//  in-sample error would reward the swap that overfits hardest.
//

import Foundation

// MARK: - Outdoor variables and their provenance

/// An outdoor variable that both WeatherKit and the station can supply, and so
/// can be chosen per-variable when fitting.
nonisolated enum OutdoorVariable: String, CaseIterable, Sendable {
    case temperature
    case humidity
    case windSpeed
    case windGust
    case windDirection
    case rainfall
    case pressure
}

/// Where one outdoor variable's values come from.
nonisolated enum OutdoorSource: String, Sendable, Equatable {
    /// Apple WeatherKit, interpolated to the observation time.
    case weatherKit
    /// The local station feed.
    case station
}

/// Which source to use for each outdoor variable.
nonisolated struct OutdoorSourcePlan: Equatable, Sendable {
    private(set) var sources: [OutdoorVariable: OutdoorSource]

    init(all source: OutdoorSource) {
        sources = Dictionary(uniqueKeysWithValues: OutdoorVariable.allCases.map { ($0, source) })
    }

    init(sources: [OutdoorVariable: OutdoorSource]) { self.sources = sources }

    subscript(v: OutdoorVariable) -> OutdoorSource {
        get { sources[v] ?? .weatherKit }
        set { sources[v] = newValue }
    }

    /// The same plan with one variable flipped to the other source.
    func swapping(_ v: OutdoorVariable) -> OutdoorSourcePlan {
        var copy = self
        copy[v] = self[v] == .weatherKit ? .station : .weatherKit
        return copy
    }

    var description: String {
        OutdoorVariable.allCases
            .map { "\($0.rawValue)=\(self[$0].rawValue)" }
            .joined(separator: " ")
    }
}

// MARK: - Solar exposure

/// How the sun's DIRECTION enters the model, on top of its height.
///
/// The roof term already covers elevation. This covers the walls, whose gain
/// depends on which way the sun is coming from — and for a house with heavy
/// west glazing that peak arrives in late afternoon, at low elevation, when the
/// roof term is fading.
///
/// The catch worth remembering: solar azimuth is a deterministic function of
/// time of day, so these columns are also time-of-day columns and will absorb
/// any other daily rhythm — cooking, occupancy, habitual equipment use. What
/// they recover is better described as "when in the day this house gains heat"
/// than as pure solar exposure.
nonisolated enum SolarExposureEncoding: String, CaseIterable, Sendable {
    /// Roof only: no direction term.
    case none
    /// One sine/cosine pair, giving a single most-exposed bearing with the
    /// least-exposed forced opposite. Two coefficients; the pair's phase says
    /// which way the house faces the sun.
    case harmonic
    /// Eight knots around the compass, assuming no shape. Richer, and eight
    /// coefficients to pay for.
    case tentBasis

    /// Columns contributed for one observation.
    func columns(vertical: Double, azimuthDegrees: Double?) -> [Double] {
        switch self {
        case .none:
            return []
        case .harmonic:
            let pair = CircularBasis.harmonicPair(azimuthDegrees)
            return [vertical * pair.sin, vertical * pair.cos]
        case .tentBasis:
            return CircularBasis.tentWeights(azimuthDegrees).map { $0 * vertical }
        }
    }

    var columnCount: Int {
        switch self {
        case .none:      return 0
        case .harmonic:  return 2
        case .tentBasis: return CircularBasis.knotCount
        }
    }

    var labels: [String] {
        switch self {
        case .none:      return []
        case .harmonic:  return ["sun from × sin(az)", "sun from × cos(az)"]
        case .tentBasis: return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
                            .map { "sun from \($0)" }
        }
    }

    /// Bearing the house is most exposed to, recovered from a fitted harmonic
    /// pair. This is the number to sanity-check against what the building
    /// actually looks like.
    static func exposureBearing(sinCoefficient: Double, cosCoefficient: Double) -> Double? {
        guard abs(sinCoefficient) + abs(cosCoefficient) > 1e-9 else { return nil }
        var degrees = atan2(sinCoefficient, cosCoefficient) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}

// MARK: - Observations

/// HVAC state over an observation interval. `.unknown` is its own case rather
/// than a synonym for `.off`: treating unlabelled time as "off" would teach the
/// model that cooling sometimes happens for no reason.
nonisolated enum HVACState: Int, Sendable, Equatable, CaseIterable {
    /// Explicitly not known. Rows carrying this are EXCLUDED from fitting
    /// rather than guessed at: a wrong label is worse than a missing one,
    /// because it teaches the model that equipment does something it didn't.
    case unknown = -1
    case off = 0
    case evaporativeCooler = 1
    case airConditioning = 2
    case heating = 3
    /// The swamp cooler's fan running dry — no water on the pads.
    ///
    /// Physically this is not cooling at all, it is forced infiltration: it
    /// pulls outside air through the house. So it gets its own terms driving
    /// indoor conditions toward OUTDOOR temperature and dew point, quite unlike
    /// the wetted cooler, which drives temperature toward the outdoor wet-bulb
    /// and adds moisture.
    case vent = 4
}

/// Outdoor conditions from a single source at one instant. Optional throughout:
/// the station does not report everything, and history for some fields only
/// starts once the station app began publishing them.
nonisolated struct OutdoorValues: Sendable, Equatable {
    var temperatureC: Double?
    var humidity: Double?          // percent, 0…100
    var windSpeedMS: Double?
    var windGustMS: Double?
    var windDirectionDeg: Double?
    /// Millimetres of rain during THIS observation interval — not a running
    /// total. The station reports a cumulative tipping-bucket counter and
    /// WeatherKit reports an hourly amount; the builder converts both, because
    /// a raw counter used as a regressor is a monotone ramp that acts as a
    /// hidden time trend.
    var rainfallMM: Double?
    /// Absolute pressure at the site, NOT reduced to sea level. WeatherKit's
    /// figure is converted before it gets here so both sources mean the same
    /// thing; see ForecastPoint.stationPressurePa.
    var stationPressureHPa: Double?

    func value(_ v: OutdoorVariable) -> Double? {
        switch v {
        case .temperature:   return temperatureC
        case .humidity:      return humidity
        case .windSpeed:     return windSpeedMS
        case .windGust:      return windGustMS
        case .windDirection: return windDirectionDeg
        case .rainfall:      return rainfallMM
        case .pressure:      return stationPressureHPa
        }
    }
}

/// One fitted row: the indoor state now, the indoor state at the next reading,
/// and both candidate sets of outdoor conditions in between.
/// The house's slow parts, carried as state beside the room's own readings.
///
/// Each is a first-order lag — m += (1 − e^(−Δt/τ))(x − m) — and each stands
/// for something real: the indoor mass is the furniture, floors and inner
/// walls the room exchanges heat with; the envelope is the outer fabric,
/// which follows outdoor air hours behind; the two moisture buffers are
/// everything in the house that holds and releases water.
///
/// The time constants are fixed rather than fitted. A fortnight of readings
/// cannot tell 64 hours from longer, and a time constant that moved with every
/// refit would make the forecast jump about. They were chosen by forecast
/// score offline — see the stepwise tool in the analysis repository — and
/// should be revisited there as the record grows, not tuned here.
nonisolated struct ThermalLags: Sendable, Equatable, Codable {
    static let indoorMassHours = 64.0
    static let envelopeHours = 16.0
    static let slowMoistureHours = 64.0
    static let fastMoistureHours = 1.0

    var indoorMassC: Double
    var envelopeC: Double
    var slowDewPointC: Double
    var fastDewPointC: Double

    /// Lags sitting exactly where the room is, so every lag term contributes
    /// nothing. What a model falls back to when no history came with the row.
    static func matching(_ o: IndoorObservation) -> ThermalLags {
        ThermalLags(indoorMassC: o.indoorTempC, envelopeC: o.indoorTempC,
                    slowDewPointC: o.indoorDewPointC, fastDewPointC: o.indoorDewPointC)
    }

    static func starting(indoorTempC: Double, outdoorTempC: Double?, indoorDewPointC: Double) -> ThermalLags {
        ThermalLags(indoorMassC: indoorTempC, envelopeC: outdoorTempC ?? indoorTempC,
                    slowDewPointC: indoorDewPointC, fastDewPointC: indoorDewPointC)
    }

    /// Advance every lag over `dt`, driven by the values at the step's start.
    func advanced(indoorTempC: Double, outdoorTempC: Double?,
                  indoorDewPointC: Double, dt: TimeInterval) -> ThermalLags {
        let hours = dt / 3600
        func lag(_ m: Double, toward x: Double, _ tau: Double) -> Double {
            m + (1 - exp(-hours / tau)) * (x - m)
        }
        return ThermalLags(
            indoorMassC: lag(indoorMassC, toward: indoorTempC, Self.indoorMassHours),
            envelopeC: lag(envelopeC, toward: outdoorTempC ?? envelopeC, Self.envelopeHours),
            slowDewPointC: lag(slowDewPointC, toward: indoorDewPointC, Self.slowMoistureHours),
            fastDewPointC: lag(fastDewPointC, toward: indoorDewPointC, Self.fastMoistureHours))
    }

    /// Advance a lag driven only by outdoor air, for seeding the envelope from
    /// weather that predates the first indoor reading.
    func envelopeAdvanced(outdoorTempC: Double, dt: TimeInterval) -> ThermalLags {
        var out = self
        out.envelopeC += (1 - exp(-(dt / 3600) / Self.envelopeHours)) * (outdoorTempC - envelopeC)
        return out
    }
}

/// How the air conditioner follows its thermostat.
///
/// Above the setpoint it runs flat out and pulls the room down. At the
/// setpoint it cycles, running whatever share of the time cancels the heat
/// coming in — so on a hot afternoon it runs most of the time and dries hard,
/// while on a mild evening it runs briefly and the dew point drifts back
/// toward outdoors between cycles. That is why duty, not "the AC is on",
/// multiplies both the cooling and the drying.
nonisolated struct ACThermostat: Sendable, Equatable, Codable {
    /// Cooling delivered at full duty, °C per hour. Estimated with the model:
    /// it is what the duty coefficient measures.
    var capacityCPerHour: Double = 1.0
    /// How fast the thermostat is asked to close a gap to its setpoint. One
    /// reading interval: any quicker and a 20-minute step would overshoot.
    static let pullDownHours = 1.0 / 3.0

    /// Share of the interval the compressor runs, 0…1.
    func duty(indoorTempC: Double, setpointC: Double?, passiveRate: Double) -> Double {
        // With no setpoint recorded there is nothing to hold, so assume it runs.
        guard let setpointC else { return 1 }
        let demand = passiveRate + (indoorTempC - setpointC) / Self.pullDownHours
        return min(max(demand / max(capacityCPerHour, 0.05), 0), 1)
    }
}

nonisolated struct IndoorObservation: Sendable {
    let date: Date
    /// Seconds to the next reading. Rates are per hour, so this is divided out.
    let dt: Double

    let indoorTempC: Double
    let indoorDewPointC: Double
    let nextIndoorTempC: Double
    let nextIndoorDewPointC: Double

    let weatherKit: OutdoorValues
    let station: OutdoorValues

    /// Solar gain proxy. The station's light sensor (kLux) when present,
    /// otherwise derived from WeatherKit cloud cover and daylight. Already
    /// normalised to roughly 0…1 by the aligner so one coefficient fits both.
    let solar: Double
    /// cos(elevation) scaled by clear-sky fraction: what a vertical surface has
    /// available. Defaulted so callers predating solar exposure still compile.
    var solarVertical: Double = 0
    /// Compass bearing of the sun, nil at night.
    var solarAzimuthDeg: Double?
    /// 1 between sunrise and sunset, 0 at night. The daytime gain turns out to
    /// be squarer than the sun's own arc — people, appliances and windows all
    /// follow the day rather than the solar elevation.
    var daylight: Double = 0
    /// Thermostat setting in force, when one was recorded with the event.
    var setpointC: Double?
    /// The house's slow parts at this moment, from the readings before it.
    var lags: ThermalLags?
    /// True while the lags are still forgetting where they were started, which
    /// is a day or so. Such rows are dropped from fitting when enough remain.
    var withinLagBurnIn = false
    let hvac: HVACState

    /// Outdoor values under a given plan, variable by variable.
    func outdoor(_ plan: OutdoorSourcePlan) -> OutdoorValues {
        var out = OutdoorValues()
        for v in OutdoorVariable.allCases {
            let picked = plan[v] == .weatherKit ? weatherKit : station
            let fallback = plan[v] == .weatherKit ? station : weatherKit
            // Fall back to the other source rather than dropping the row: early
            // on, station history for gust/direction/rain/pressure is empty.
            let value = picked.value(v) ?? fallback.value(v)
            switch v {
            case .temperature:   out.temperatureC = value
            case .humidity:      out.humidity = value
            case .windSpeed:     out.windSpeedMS = value
            case .windGust:      out.windGustMS = value
            case .windDirection: out.windDirectionDeg = value
            case .rainfall:      out.rainfallMM = value
            case .pressure:      out.stationPressureHPa = value
            }
        }
        return out
    }
}

// MARK: - Circular predictors

/// Encoding for a predictor that lives on a circle — a compass bearing.
///
/// Shared by wind direction and solar azimuth because they pose the same
/// problem: raw degrees put 350 and 10 at opposite ends of the range although
/// they are nearly the same direction, and the shape of the response is not
/// known in advance.
nonisolated enum CircularBasis {
    /// Knots, from north, clockwise: N NE E SE S SW W NW.
    static let knotCount: Int = 8

    /// Weight on each knot for a bearing in degrees, by linear interpolation
    /// between the two neighbouring knots.
    ///
    /// Continuous rather than a lookup table, so it handles any bearing; for
    /// values on the 22.5-degree compass points it reproduces the familiar
    /// 1 / 0.5-0.5 pattern exactly.
    static func tentWeights(_ degrees: Double?) -> [Double] {
        guard let degrees, degrees.isFinite else {
            // Direction unknown. Spreading weight evenly keeps the term's total
            // effect intact — the row contributes the AVERAGE of the knots —
            // instead of silently zeroing it.
            return [Double](repeating: 1 / Double(knotCount), count: knotCount)
        }
        let spacing = 360.0 / Double(knotCount)
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        let position = angle / spacing
        let lower = Int(position.rounded(.down)) % knotCount
        let upper = (lower + 1) % knotCount
        let fraction = position - position.rounded(.down)
        var weights = [Double](repeating: 0, count: knotCount)
        weights[lower] += 1 - fraction
        weights[upper] += fraction
        return weights
    }

    /// The sine/cosine pair: one harmonic, so one best direction with its worst
    /// forced opposite.
    static func harmonicPair(_ degrees: Double?) -> (sin: Double, cos: Double) {
        guard let degrees else { return (0, 0) }
        let radians = degrees * .pi / 180
        return (sin(radians), cos(radians))
    }
}

// MARK: - Wind direction encoding

/// How the wind's bearing enters the model.
///
/// Both are fitted and compared on held-out error, because which is right
/// depends on the house and cannot be known in advance.
nonisolated enum WindDirectionEncoding: String, CaseIterable, Sendable {

    /// One sine and one cosine term.
    ///
    /// Cheap — two coefficients — but it assumes a shape: a single harmonic has
    /// exactly one best bearing and forces its worst to lie 180 degrees
    /// opposite. That is a real pattern for some buildings and wrong for
    /// others, e.g. one with two exposed faces.
    case harmonic

    /// A cyclic linear spline ("tent" basis) over eight knots at 45 degrees.
    ///
    /// Each bearing is split between its two neighbouring knots in proportion
    /// to angular distance, so a wind from NNE contributes half to N and half
    /// to NE. This assumes no shape at all: any pattern across the eight knots
    /// can be represented. It stays continuous, so bearings close on the
    /// compass still have similar effects — the property a plain 8- or 16-way
    /// categorical split throws away, since it would leave adjacent sectors
    /// unrelated and discontinuous at every bin edge.
    ///
    /// Splitting each observation across two knots also ties neighbouring
    /// coefficients together, which is useful regularisation while history is
    /// short. The cost is eight coefficients where the harmonic needs two.
    case tentBasis

    /// Knots, from north, clockwise: N NE E SE S SW W NW.
    static let knotCount: Int = CircularBasis.knotCount

    /// Interpolate a compass bearing.
    ///
    /// Bearings wrap, so plain interpolation is wrong at the seam: halfway
    /// between 350 and 10 is north, but averaging the numbers gives 180 —
    /// exactly the opposite direction. Interpolating the unit vectors instead
    /// crosses the seam correctly.
    static func lerpAngle(_ a: Double?, _ b: Double?, _ fraction: Double) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        let ra = a * .pi / 180, rb = b * .pi / 180
        let x = cos(ra) + (cos(rb) - cos(ra)) * fraction
        let y = sin(ra) + (sin(rb) - sin(ra)) * fraction
        // Both vectors cancelling means the two bearings are opposite and the
        // midpoint is genuinely undefined; keep the earlier one rather than
        // inventing a direction from rounding noise.
        guard x * x + y * y > 1e-12 else { return a }
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Weight on each knot for a bearing in degrees.
    ///
    /// Continuous rather than a 16-row lookup, so it handles WeatherKit's
    /// arbitrary bearings as well as the station's 22.5-degree steps — and for
    /// those steps it reproduces the 1 / 0.5-0.5 pattern exactly.
    static func tentWeights(_ degrees: Double?) -> [Double] {
        CircularBasis.tentWeights(degrees)
    }
}

// MARK: - Evaporative cooling

/// How completely the swamp cooler saturates the air passing its pads.
///
/// A direct evaporative cooler drives air along a line of constant wet-bulb
/// temperature, from outdoor conditions toward saturation. Perfect saturation
/// would deliver air AT the outdoor wet bulb; real pads reach only part way,
/// and the fraction they reach is the effectiveness.
///
/// This matters in both equations, and the second half is easy to miss. Falling
/// short of saturation means the supply air is warmer than the wet bulb — the
/// obvious part — but it also means the air is DRIER than the wet bulb, because
/// it picked up less moisture crossing the pads. So the indoor dew point never
/// climbs all the way to the outdoor wet bulb, which is exactly what the
/// readings show.
///
/// The default is measured rather than assumed: supply air at 22.2 °C with
/// 34.6 °C outdoor and a 19.7 °C wet bulb gives 0.83, in the usual 0.75–0.90
/// band for this kind of cooler.
nonisolated struct CoolerEffectiveness: Sendable, Equatable, Codable {
    var fraction: Double = 0.83

    /// Temperature of the air the cooler delivers.
    func supplyTemperatureC(outdoorC: Double, wetBulbC: Double) -> Double {
        outdoorC - fraction * (outdoorC - wetBulbC)
    }

    /// Dew point of the air the cooler delivers: part way from the outdoor dew
    /// point toward the wet bulb, by the same fraction.
    func supplyDewPointC(outdoorDewPointC: Double, wetBulbC: Double) -> Double {
        outdoorDewPointC + fraction * (wetBulbC - outdoorDewPointC)
    }
}

// MARK: - Air conditioning

/// Temperature of the AC's cooling coil, which sets how far it can dry the air.
///
/// The coil is what condenses moisture out: the indoor dew point falls only
/// while it is above the coil, and asymptotically approaches it. So the coil
/// temperature is both the threshold for dehumidification and the floor it
/// heads toward, which is what makes it estimable from how the dew point
/// behaves while the AC runs.
///
/// It is not a constant. A compressor cannot bring its refrigerant as low when
/// the outdoor unit is rejecting heat into hot air, so the coil runs warmer on
/// hot days. That is modelled as a straight line in outdoor temperature,
/// centred at 25 °C so `baseC` reads as "coil temperature on a 25 °C day"
/// rather than an extrapolation to freezing.
nonisolated struct CoilTemperature: Sendable, Equatable, Codable {
    /// Coil temperature when it is 25 °C outside.
    var baseC: Double = 7
    /// How much warmer the coil runs per degree of outdoor warmth.
    var perOutdoorDegree: Double = 0

    static let referenceOutdoorC: Double = 25

    func celsius(outdoorC: Double?) -> Double {
        baseC + perOutdoorDegree * ((outdoorC ?? Self.referenceOutdoorC) - Self.referenceOutdoorC)
    }

    /// How hard the AC is working to dry the air, as the dew point's distance
    /// above the coil. Zero once the air is already drier than the coil, when
    /// no condensation happens at all.
    func latentDrive(indoorDewPointC: Double, outdoorC: Double?) -> Double {
        max(0, indoorDewPointC - celsius(outdoorC: outdoorC))
    }
}

// MARK: - Infiltration terms

/// The wind-driven infiltration regressors, shared by both equations.
///
/// Direction never acts alone: it always multiplies the wind term, because a
/// bearing means nothing without a wind behind it.
nonisolated struct InfiltrationTerms {
    /// Sustained wind, m/s.
    let wind: Double
    /// How much the gusts exceed the sustained wind. Gust and wind are strongly
    /// correlated, so the excess is used instead of the raw gust: it carries
    /// the part gustiness adds without duplicating a column the model already
    /// has, which would leave the ridge splitting one effect across two terms.
    let gustExcess: Double
    let directionDegrees: Double?
    /// Rain during the interval, mm.
    let rain: Double

    init(_ o: OutdoorValues) {
        let w = o.windSpeedMS ?? 0
        wind = w
        gustExcess = max(0, (o.windGustMS ?? w) - w)
        directionDegrees = o.windDirectionDeg
        rain = o.rainfallMM ?? 0
    }

    /// Wind, gust and bearing taken from ONE source.
    ///
    /// The plan picks a source per variable, which once left the model with
    /// gusts from the station and sustained wind from WeatherKit. Their
    /// difference was zero in half the readings — not because the air was
    /// still, but because the two sources disagree about the wind's level, the
    /// station sitting low behind a wall. Gustiness is a difference, so both
    /// sides of it have to come from the same instrument.
    init(_ o: IndoorObservation, _ plan: OutdoorSourcePlan) {
        let primary = plan[.windSpeed] == .weatherKit ? o.weatherKit : o.station
        let fallback = plan[.windSpeed] == .weatherKit ? o.station : o.weatherKit
        let source = primary.windSpeedMS != nil ? primary : fallback
        let w = source.windSpeedMS ?? 0
        wind = w
        gustExcess = max(0, (source.windGustMS ?? w) - w)
        directionDegrees = source.windDirectionDeg
        rain = source.rainfallMM ?? 0
    }
}

// MARK: - Psychrometric helpers

nonisolated enum IndoorPsychrometrics {
    /// Magnus-form dew point. psychropy.swift has saturation pressure and wet
    /// bulb but no inverse for dew point, and both feeds give temperature and
    /// relative humidity rather than dew point directly.
    static func dewPointC(temperatureC t: Double, relativeHumidity rh: Double) -> Double? {
        let h = rh > 1.5 ? rh / 100 : rh          // accept 0…1 or 0…100
        guard h > 0.001, h <= 1.0, t.isFinite else { return nil }
        let a = 17.62, b = 243.12
        let gamma = log(h) + (a * t) / (b + t)
        let denom = a - gamma
        guard abs(denom) > 1e-9 else { return nil }
        return (b * gamma) / denom
    }

    /// Wet bulb at a site's actual pressure.
    static func wetBulbC(temperatureC t: Double, relativeHumidity rh: Double,
                         pressureHPa: Double?) -> Double? {
        guard t.isFinite else { return nil }
        let kPa = (pressureHPa ?? 1013.25) / 10.0
        let value = PsychrometryCalculator.wetBulb(
            dryBulb: t, relativeHumidity: rh, pressure: kPa)
        return value.isFinite ? value : nil
    }
}

// MARK: - Least squares

/// Ridge-regularised ordinary least squares via the normal equations.
///
/// The design matrices here are small (at most a few thousand rows, under ten
/// columns), so forming XᵀX directly is fine. The ridge term is small and
/// exists only to keep the solve stable when two columns are nearly collinear —
/// which happens readily, e.g. wind and wind gust, or during a long stretch
/// with the cooler never on so its column is all zeros.
nonisolated enum LeastSquares {

    /// Sign a coefficient is physically permitted to take.
    enum SignConstraint {
        case free
        case nonNegative
        case nonPositive

        func violated(by value: Double) -> Bool {
            switch self {
            case .free:        return false
            case .nonNegative: return value < 0
            case .nonPositive: return value > 0
            }
        }
    }

    /// Least squares subject to sign constraints, by active set.
    ///
    /// Some coefficients have signs that physics fixes: a cooler cannot warm a
    /// house, a heater cannot cool one, conduction cannot flow uphill. Left
    /// free, whichever of them sits closest to an unexplained residual will
    /// take the wrong sign to absorb it — which is how a swamp cooler ends up
    /// fitted as a heater on a day when the model under-credits solar gain.
    ///
    /// Each pass drops the worst offender to zero and refits the rest, so the
    /// error it was absorbing is pushed back onto terms that can legitimately
    /// carry it. That makes the misfit visible in the baseline or the solar
    /// term instead of hiding it behind an impossible coefficient.
    static func fit(x: [[Double]], y: [Double],
                    constraints: [SignConstraint],
                    ridge: Double = 1e-6) -> [Double]? {
        guard let width = x.first?.count, constraints.count == width else {
            return fit(x: x, y: y, ridge: ridge)
        }
        var active = Set<Int>()          // columns forced to zero

        for _ in 0...width {
            let free = (0..<width).filter { !active.contains($0) }
            guard !free.isEmpty else { return [Double](repeating: 0, count: width) }

            let reduced = x.map { row in free.map { row[$0] } }
            guard let solved = fit(x: reduced, y: y, ridge: ridge) else { return nil }

            var beta = [Double](repeating: 0, count: width)
            for (slot, column) in free.enumerated() { beta[column] = solved[slot] }

            // Drop the single worst violation, not all of them: removing several
            // at once can eliminate a column that would have been fine once
            // another was gone.
            var worst: (column: Int, size: Double)?
            for column in free where constraints[column].violated(by: beta[column]) {
                let size = abs(beta[column])
                if worst == nil || size > worst!.size { worst = (column, size) }
            }
            guard let worst else { return beta }
            active.insert(worst.column)
        }
        return nil
    }

    /// Solve (XᵀX + λI)β = Xᵀy. Returns nil if the system is not solvable.
    static func fit(x: [[Double]], y: [Double], ridge: Double = 1e-6) -> [Double]? {
        guard let first = x.first, !y.isEmpty, x.count == y.count else { return nil }
        let n = x.count, p = first.count
        guard n > p else { return nil }        // need more rows than unknowns

        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            let row = x[i]
            guard row.count == p else { return nil }
            for a in 0..<p {
                let ra = row[a]
                guard ra.isFinite else { return nil }
                xty[a] += ra * y[i]
                for b in a..<p { xtx[a][b] += ra * row[b] }
            }
        }
        // Mirror the symmetric half and add the ridge.
        for a in 0..<p {
            for b in 0..<a { xtx[a][b] = xtx[b][a] }
            xtx[a][a] += ridge
        }
        return solveSymmetric(xtx, xty)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solveSymmetric(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { a.swapAt(pivot, col); b.swapAt(pivot, col) }
            let d = a[col][col]
            for r in (col + 1)..<n {
                let f = a[r][col] / d
                guard f.isFinite else { return nil }
                if f == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var out = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r][c] * out[c] }
            out[r] = s / a[r][r]
            guard out[r].isFinite else { return nil }
        }
        return out
    }
}

// MARK: - The model

/// A fitted indoor model: coefficients for the two rate equations, plus the
/// plan that says where each outdoor variable came from.
nonisolated struct IndoorModel: Sendable, Equatable {
    var plan: OutdoorSourcePlan
    /// Coil model used for the AC's latent term.
    var coil: CoilTemperature
    /// How completely the swamp cooler saturates its air.
    var cooler: CoolerEffectiveness
    /// How the sun's direction enters, on top of its height.
    var exposure: SolarExposureEncoding
    /// How the AC follows its setpoint, including the capacity fitted with it.
    var thermostat: ACThermostat = ACThermostat()
    /// Coefficients of the dT_in/dt equation, in `temperatureFeatures` order.
    var temperature: [Double]
    /// Coefficients of the dD_in/dt equation, in `dewPointFeatures` order.
    var dewPoint: [Double]
    /// Held-out fit, lower is better. See `Score`.
    var score: Score
    var fittedAt: Date
    var observationCount: Int

    /// Held-out error, in °C per hour, plus a combined figure.
    ///
    /// The combined number divides each equation's RMSE by the spread of that
    /// target in the test slice before averaging, so temperature and dew point
    /// count equally regardless of which happened to vary more.
    struct Score: Sendable, Equatable, Comparable {
        var temperatureRMSE: Double
        var dewPointRMSE: Double
        /// Error scaled by how much each quantity varied, for human reading.
        /// 1.0 means no better than predicting the average.
        var combined: Double
        /// Small-sample corrected information criterion on the HELD-OUT slice,
        /// summed over both equations. Lower is better; this is what model
        /// selection compares.
        var criterion: Double

        /// Selection compares the criterion, never the raw error.
        ///
        /// Held-out error already discourages overfitting, but not enough on
        /// its own: with a few dozen validation rows, a model with eight extra
        /// coefficients can win by chance. The criterion charges for every
        /// coefficient, so a richer encoding has to earn its keep rather than
        /// merely tie.
        static func < (a: Score, b: Score) -> Bool { a.criterion < b.criterion }
    }

    /// AICc on validation residuals.
    ///
    /// Not textbook AIC, which is computed in-sample: here the residuals come
    /// from data the fit never saw, and the penalty guards against a richer
    /// model flattering itself on a small validation slice. The small-sample
    /// correction matters — with 40-odd held-out rows and up to twenty
    /// coefficients the plain 2k term badly understates the cost.
    ///
    /// Coefficients clamped to zero by the sign constraints are not counted:
    /// they were removed from the fit and contribute nothing.
    static func informationCriterion(residualSumOfSquares: Double,
                                     observations n: Int,
                                     parameters k: Int) -> Double {
        guard n > 0, residualSumOfSquares > 0 else { return .infinity }
        // Too many parameters for the validation set to say anything: refuse
        // rather than return a flattering number.
        guard n - k - 1 > 0 else { return .infinity }
        let aic = Double(n) * log(residualSumOfSquares / Double(n)) + 2 * Double(k)
        let correction = 2 * Double(k) * Double(k + 1) / Double(n - k - 1)
        return aic + correction
    }

    // MARK: Feature construction
    //
    // The model is in two halves, fitted separately.
    //
    // The PASSIVE half is the house with nothing running: conduction to the
    // outdoor air, the daytime gain, the sun by the bearing it comes from, and
    // the building's slow parts carried as lagged state. Dew point has the
    // same shape, with two moisture buffers standing in for everything in the
    // house that holds water.
    //
    // The EQUIPMENT half is what each machine adds on top, fitted on what the
    // passive half leaves unexplained during that machine's own hours. Fitting
    // the two together let one absorb the other's misfit, which is how an AC
    // coefficient once came out at zero.

    /// Columns the equipment half contributes to either equation.
    static let equipmentColumns = 5

    /// dT_in/dt passive row. Order must match the head of `temperature`.
    static func passiveTemperatureRow(_ o: IndoorObservation,
                                      _ plan: OutdoorSourcePlan,
                                      _ exposure: SolarExposureEncoding) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC else { return nil }
        let lags = o.lags ?? ThermalLags.matching(o)
        return [tOut - o.indoorTempC,
                o.daylight,
                lags.indoorMassC - o.indoorTempC]
            + exposure.columns(vertical: o.solarVertical, azimuthDegrees: o.solarAzimuthDeg)
            + [lags.envelopeC - o.indoorTempC]
    }

    /// dDp_in/dt passive row. Order must match the head of `dewPoint`.
    static func passiveDewPointRow(_ o: IndoorObservation, _ plan: OutdoorSourcePlan) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC, let rhOut = out.humidity,
              let dOut = IndoorPsychrometrics.dewPointC(temperatureC: tOut, relativeHumidity: rhOut)
        else { return nil }
        let lags = o.lags ?? ThermalLags.matching(o)
        let gradient = dOut - o.indoorDewPointC
        let wind = InfiltrationTerms(o, plan)
        return [gradient,
                lags.slowDewPointC - o.indoorDewPointC,
                1,
                wind.wind * gradient,
                wind.gustExcess * gradient,
                lags.fastDewPointC - o.indoorDewPointC]
    }

    /// What the running equipment adds to dT_in/dt, given what the passive
    /// half says the room is doing. Order must match the tail of `temperature`.
    static func equipmentTemperatureRow(_ o: IndoorObservation,
                                        _ plan: OutdoorSourcePlan,
                                        _ coil: CoilTemperature,
                                        _ cooler: CoolerEffectiveness,
                                        _ thermostat: ACThermostat,
                                        passiveRate: Double) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC, let rhOut = out.humidity else { return nil }
        let wetBulb = IndoorPsychrometrics.wetBulbC(temperatureC: tOut, relativeHumidity: rhOut,
                                                    pressureHPa: out.stationPressureHPa) ?? tOut
        let duty = o.hvac == .airConditioning
            ? thermostat.duty(indoorTempC: o.indoorTempC, setpointC: o.setpointC, passiveRate: passiveRate)
            : 0
        return [// Energy spent condensing water is energy not spent cooling, so
                // this is expected POSITIVE: the harder it dries, the less it cools.
                duty * coil.latentDrive(indoorDewPointC: o.indoorDewPointC, outdoorC: tOut),
                o.hvac == .evaporativeCooler
                    ? cooler.supplyTemperatureC(outdoorC: tOut, wetBulbC: wetBulb) - o.indoorTempC : 0,
                // Venting drags the room toward outdoor AIR temperature: there
                // is no evaporation without water.
                o.hvac == .vent ? tOut - o.indoorTempC : 0,
                duty,
                o.hvac == .heating ? 1 : 0]
    }

    /// The same for dDp_in/dt.
    static func equipmentDewPointRow(_ o: IndoorObservation,
                                     _ plan: OutdoorSourcePlan,
                                     _ coil: CoilTemperature,
                                     _ cooler: CoolerEffectiveness,
                                     _ thermostat: ACThermostat,
                                     passiveRate: Double) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC, let rhOut = out.humidity,
              let dOut = IndoorPsychrometrics.dewPointC(temperatureC: tOut, relativeHumidity: rhOut)
        else { return nil }
        let wetBulb = IndoorPsychrometrics.wetBulbC(temperatureC: tOut, relativeHumidity: rhOut,
                                                    pressureHPa: out.stationPressureHPa) ?? tOut
        let duty = o.hvac == .airConditioning
            ? thermostat.duty(indoorTempC: o.indoorTempC, setpointC: o.setpointC, passiveRate: passiveRate)
            : 0
        return [// Drying happens only while the compressor runs and only while
                // the dew point is above the coil. Between cycles the passive
                // terms take it back toward outdoors, which is why the duty
                // matters rather than merely "the AC is on".
                duty * coil.latentDrive(indoorDewPointC: o.indoorDewPointC, outdoorC: tOut),
                o.hvac == .evaporativeCooler
                    ? cooler.supplyDewPointC(outdoorDewPointC: dOut, wetBulbC: wetBulb) - o.indoorDewPointC : 0,
                o.hvac == .vent ? dOut - o.indoorDewPointC : 0,
                duty,
                o.hvac == .heating ? 1 : 0]
    }

    /// Observed rates, per hour.
    static func temperatureTarget(_ o: IndoorObservation) -> Double {
        (o.nextIndoorTempC - o.indoorTempC) / (o.dt / 3600)
    }
    static func dewPointTarget(_ o: IndoorObservation) -> Double {
        (o.nextIndoorDewPointC - o.indoorDewPointC) / (o.dt / 3600)
    }

    // MARK: Labels

    static let equipmentLabels = ["AC dehumidifying", "evaporative cooler",
                                  "vent (cooler, dry)", "air conditioning", "heating"]

    /// Human-readable names for `temperature`, in coefficient order.
    var temperatureLabels: [String] {
        ["conduction (out − in)", "daytime gain",
         String(format: "slow indoor mass (τ %.0f h)", ThermalLags.indoorMassHours)]
            + exposure.labels
            + [String(format: "envelope, lagged outdoor (τ %.0f h)", ThermalLags.envelopeHours)]
            + Self.equipmentLabels
    }

    /// Human-readable names for `dewPoint`, in coefficient order.
    var dewPointLabels: [String] {
        ["moisture exchange (out − in)",
         String(format: "slow moisture buffer (τ %.0f h)", ThermalLags.slowMoistureHours),
         "baseline moisture (occupants)",
         "wind × ΔDp", "gustiness × ΔDp",
         String(format: "fast moisture buffer (τ %.0f h)", ThermalLags.fastMoistureHours)]
            + Self.equipmentLabels
    }

    /// Index of the coefficient for a given piece of equipment. Equipment
    /// occupies the last four slots of either equation, in this order.
    static let equipmentOrder: [HVACState] = [.evaporativeCooler, .vent,
                                              .airConditioning, .heating]

    static func equipmentIndex(_ state: HVACState, in count: Int) -> Int? {
        guard let offset = equipmentOrder.firstIndex(of: state) else { return nil }
        return count - equipmentOrder.count + offset
    }

    /// What physics permits each temperature coefficient to be.
    static func temperatureConstraints(_ exposure: SolarExposureEncoding) -> [LeastSquares.SignConstraint] {
        passiveTemperatureConstraints(exposure) + equipmentTemperatureConstraints
    }
    static func passiveTemperatureConstraints(_ exposure: SolarExposureEncoding) -> [LeastSquares.SignConstraint] {
        // Exposure columns are free for the harmonic pair, whose signs encode a
        // bearing rather than a direction of effect. Tent knots are each a real
        // gain and cannot be negative.
        let exposureConstraints: [LeastSquares.SignConstraint]
        switch exposure {
        case .none:      exposureConstraints = []
        case .harmonic:  exposureConstraints = [.free, .free]
        case .tentBasis: exposureConstraints = [LeastSquares.SignConstraint](
                            repeating: .nonNegative, count: CircularBasis.knotCount)
        }
        return [.nonNegative,   // conduction: heat flows toward the outside
                .nonNegative,   // daylight warms
                .nonNegative]   // the mass gives heat back toward the room
            + exposureConstraints
            + [.nonNegative]    // so does the envelope
    }
    static let equipmentTemperatureConstraints: [LeastSquares.SignConstraint] = [
        .nonNegative,   // AC drying costs cooling power
        .nonNegative,   // cooler pulls toward its supply air
        .nonNegative,   // vent pulls toward outdoor
        .nonPositive,   // AC cools
        .nonNegative,   // heating warms
    ]

    /// The same for the dew point equation.
    static func dewPointConstraints() -> [LeastSquares.SignConstraint] {
        passiveDewPointConstraints + equipmentDewPointConstraints
    }
    static let passiveDewPointConstraints: [LeastSquares.SignConstraint] = [
        .nonNegative,   // moisture moves toward the outdoor dew point
        .nonNegative,   // and toward what the house has been holding
        .free,          // occupants add moisture; an empty house loses it
        .free, .free,   // wind and gustiness modulate the exchange
        .nonNegative,   // the fast buffer, likewise
    ]
    static let equipmentDewPointConstraints: [LeastSquares.SignConstraint] = [
        .nonPositive,   // the AC condenses moisture out
        .nonNegative,   // the cooler adds moisture toward its supply dew point
        .nonNegative,   // venting pulls toward outdoor
        .free,          // what the AC does beyond the coil term
        .free,          // heating should not move moisture at all
    ]

    // MARK: Fitting

    /// Fit both equations on `train` and score on `test`.
    ///
    /// The passive half is fitted on the stretches with nothing running; each
    /// machine is then fitted on the residual of its own hours. The AC's duty
    /// depends on its capacity, and its capacity is what the duty coefficient
    /// measures, so the two are settled by repeating the fit a few times.
    static func fit(train: [IndoorObservation],
                    test: [IndoorObservation],
                    plan: OutdoorSourcePlan,
                    coil: CoilTemperature = CoilTemperature(),
                    cooler: CoolerEffectiveness = CoolerEffectiveness(),
                    exposure: SolarExposureEncoding = .none,
                    thermostat: ACThermostat = ACThermostat(),
                    now: Date = .now) -> IndoorModel? {

        // Rows whose lags still remember where they were started teach the
        // model the seed rather than the house, so they are left out — unless
        // dropping them would leave too little to fit, which is the case in the
        // first days of a new installation.
        let known = train.filter { $0.hvac != .unknown }
        let seasoned = known.filter { !$0.withinLagBurnIn }
        let usable = seasoned.filter { $0.hvac == .off }.count >= 30 ? seasoned : known
        let passiveRows = usable.filter { $0.hvac == .off }
        var xT: [[Double]] = [], yT: [Double] = [], xD: [[Double]] = [], yD: [Double] = []
        for o in passiveRows {
            guard let rt = passiveTemperatureRow(o, plan, exposure),
                  let rd = passiveDewPointRow(o, plan) else { continue }
            let tT = temperatureTarget(o), tD = dewPointTarget(o)
            guard tT.isFinite, tD.isFinite, rt.allSatisfy(\.isFinite), rd.allSatisfy(\.isFinite) else { continue }
            xT.append(rt); yT.append(tT); xD.append(rd); yD.append(tD)
        }
        guard let passiveT = LeastSquares.fit(x: xT, y: yT, constraints: passiveTemperatureConstraints(exposure)),
              let passiveD = LeastSquares.fit(x: xD, y: yD, constraints: passiveDewPointConstraints)
        else { return nil }

        let equipmentRows = usable.filter { $0.hvac != .off }
        var thermo = thermostat
        var equipmentT = [Double](repeating: 0, count: equipmentColumns)
        var equipmentD = equipmentT
        if equipmentRows.count > equipmentColumns + 1 {
            for _ in 0..<3 {
                var eT: [[Double]] = [], eD: [[Double]] = [], rT: [Double] = [], rD: [Double] = []
                for o in equipmentRows {
                    guard let pt = passiveTemperatureRow(o, plan, exposure),
                          let pd = passiveDewPointRow(o, plan) else { continue }
                    let passiveRate = zip(pt, passiveT).reduce(0) { $0 + $1.0 * $1.1 }
                    let passiveRateD = zip(pd, passiveD).reduce(0) { $0 + $1.0 * $1.1 }
                    guard let rowT = equipmentTemperatureRow(o, plan, coil, cooler, thermo, passiveRate: passiveRate),
                          let rowD = equipmentDewPointRow(o, plan, coil, cooler, thermo, passiveRate: passiveRate)
                    else { continue }
                    let tT = temperatureTarget(o), tD = dewPointTarget(o)
                    guard tT.isFinite, tD.isFinite else { continue }
                    eT.append(rowT); rT.append(tT - passiveRate)
                    eD.append(rowD); rD.append(tD - passiveRateD)
                }
                guard let bT = LeastSquares.fit(x: eT, y: rT, constraints: equipmentTemperatureConstraints),
                      let bD = LeastSquares.fit(x: eD, y: rD, constraints: equipmentDewPointConstraints)
                else { break }
                equipmentT = bT; equipmentD = bD
                // The cooling coefficient IS the capacity the duty was computed
                // with; where they disagree, take the fitted one and go again.
                let cooling = abs(bT[equipmentColumns - 2])
                let settled = abs(cooling - thermo.capacityCPerHour) < 0.02
                if cooling > 0.05 { thermo.capacityCPerHour = min(max(cooling, 0.25), 8) }
                if settled || cooling <= 0.05 { break }
            }
        }

        let candidate = IndoorModel(plan: plan, coil: coil, cooler: cooler, exposure: exposure,
                                    thermostat: thermo,
                                    temperature: passiveT + equipmentT, dewPoint: passiveD + equipmentD,
                                    score: Score(temperatureRMSE: 0, dewPointRMSE: 0, combined: 0, criterion: 0),
                                    fittedAt: now, observationCount: xT.count + equipmentRows.count)
        guard let score = candidate.scored(on: test) else { return nil }
        var fitted = candidate
        fitted.score = score
        return fitted
    }

    /// Held-out error of this model, measured on rates it never saw.
    func scored(on test: [IndoorObservation]) -> Score? {
        var errorsT: [Double] = [], errorsD: [Double] = [], targetsT: [Double] = [], targetsD: [Double] = []
        for o in test where o.hvac != .unknown {
            guard let r = rates(o) else { continue }
            let aT = Self.temperatureTarget(o), aD = Self.dewPointTarget(o)
            guard aT.isFinite, aD.isFinite, r.temperature.isFinite, r.dewPoint.isFinite else { continue }
            errorsT.append(r.temperature - aT); errorsD.append(r.dewPoint - aD)
            targetsT.append(aT); targetsD.append(aD)
        }
        guard errorsT.count > 1 else { return nil }
        func rootMean(_ e: [Double]) -> Double { (e.reduce(0) { $0 + $1 * $1 } / Double(e.count)).squareRoot() }
        let rmseT = rootMean(errorsT), rmseD = rootMean(errorsD)
        let usedT = temperature.filter { $0 != 0 }.count
        let usedD = dewPoint.filter { $0 != 0 }.count
        let criterion = Self.informationCriterion(residualSumOfSquares: rmseT * rmseT * Double(errorsT.count),
                                                  observations: errorsT.count, parameters: usedT)
            + Self.informationCriterion(residualSumOfSquares: rmseD * rmseD * Double(errorsD.count),
                                        observations: errorsD.count, parameters: usedD)
        // Normalise by the spread of each target so neither equation dominates
        // just by being measured on a livelier quantity.
        let combined = (rmseT / max(Self.spread(targetsT), 0.05) + rmseD / max(Self.spread(targetsD), 0.05)) / 2
        guard combined.isFinite else { return nil }
        return Score(temperatureRMSE: rmseT, dewPointRMSE: rmseD, combined: combined, criterion: criterion)
    }

    private static func spread(_ y: [Double]) -> Double {
        guard y.count > 1 else { return 0 }
        let mean = y.reduce(0, +) / Double(y.count)
        let variance = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(y.count - 1)
        return variance.squareRoot()
    }

    // MARK: Prediction

    /// Both rates at an observation, °C per hour.
    func rates(_ o: IndoorObservation) -> (temperature: Double, dewPoint: Double)? {
        guard let pt = Self.passiveTemperatureRow(o, plan, exposure),
              let pd = Self.passiveDewPointRow(o, plan),
              temperature.count == pt.count + Self.equipmentColumns,
              dewPoint.count == pd.count + Self.equipmentColumns else { return nil }
        let passiveT = zip(pt, temperature).reduce(0) { $0 + $1.0 * $1.1 }
        let passiveD = zip(pd, dewPoint).reduce(0) { $0 + $1.0 * $1.1 }
        guard o.hvac != .off, o.hvac != .unknown else { return (passiveT, passiveD) }
        guard let et = Self.equipmentTemperatureRow(o, plan, coil, cooler, thermostat, passiveRate: passiveT),
              let ed = Self.equipmentDewPointRow(o, plan, coil, cooler, thermostat, passiveRate: passiveT)
        else { return nil }
        let addT = zip(et, temperature.suffix(Self.equipmentColumns)).reduce(0) { $0 + $1.0 * $1.1 }
        let addD = zip(ed, dewPoint.suffix(Self.equipmentColumns)).reduce(0) { $0 + $1.0 * $1.1 }
        return (passiveT + addT, passiveD + addD)
    }

    /// Indoor temperature, dew point and lag state one step of `dt` later.
    ///
    /// Integrating this repeatedly is how the forecast scenarios are produced:
    /// override `hvac` to ask "what if the cooler were on". The lags come back
    /// with it because the house's slow parts are state: a forecast that
    /// dropped them would forget what the walls are holding.
    func step(from o: IndoorObservation, dt: Double) -> (temperatureC: Double, dewPointC: Double, lags: ThermalLags)? {
        guard let rate = rates(o) else { return nil }
        let hours = dt / 3600
        let t = o.indoorTempC + rate.temperature * hours
        let d = o.indoorDewPointC + rate.dewPoint * hours
        guard t.isFinite, d.isFinite else { return nil }
        let lags = (o.lags ?? ThermalLags.matching(o))
            .advanced(indoorTempC: o.indoorTempC,
                      outdoorTempC: o.outdoor(plan).temperatureC,
                      indoorDewPointC: o.indoorDewPointC, dt: dt)
        // The dew point cannot exceed the dry bulb; clamp rather than let a
        // long integration drift into a physically impossible state.
        return (t, min(d, t), lags)
    }
}

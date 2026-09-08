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
enum OutdoorVariable: String, CaseIterable, Sendable {
    case temperature
    case humidity
    case windSpeed
    case windGust
    case windDirection
    case rainfall
    case pressure
}

/// Where one outdoor variable's values come from.
enum OutdoorSource: String, Sendable, Equatable {
    /// Apple WeatherKit, interpolated to the observation time.
    case weatherKit
    /// The local station feed.
    case station
}

/// Which source to use for each outdoor variable.
struct OutdoorSourcePlan: Equatable, Sendable {
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

// MARK: - Observations

/// HVAC state over an observation interval. `.unknown` is its own case rather
/// than a synonym for `.off`: treating unlabelled time as "off" would teach the
/// model that cooling sometimes happens for no reason.
enum HVACState: Int, Sendable, Equatable {
    case unknown = -1
    case off = 0
    case evaporativeCooler = 1
    case airConditioning = 2
    case heating = 3
}

/// Outdoor conditions from a single source at one instant. Optional throughout:
/// the station does not report everything, and history for some fields only
/// starts once the station app began publishing them.
struct OutdoorValues: Sendable, Equatable {
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
struct IndoorObservation: Sendable {
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

// MARK: - Infiltration terms

/// The wind-driven infiltration regressors, shared by both equations.
///
/// Direction is encoded as its sine and cosine rather than as degrees. Raw
/// degrees would put 350 and 10 at opposite ends of the range although they are
/// nearly the same wind; sin/cos places them next to each other and removes the
/// seam entirely. Fitting a coefficient on each is the same as fitting one
/// sinusoid with a free amplitude and phase, so the model can learn that wind
/// from one bearing drives more infiltration than from another — and the pair
/// of coefficients says which bearing.
///
/// Direction never acts alone: it multiplies the wind term, because a bearing
/// means nothing without a wind behind it.
struct InfiltrationTerms {
    /// Sustained wind, m/s.
    let wind: Double
    /// How much the gusts exceed the sustained wind. Gust and wind are strongly
    /// correlated, so the excess is used instead of the raw gust: it carries
    /// the part gustiness adds without duplicating a column the model already
    /// has, which would leave the ridge splitting one effect across two terms.
    let gustExcess: Double
    let sinDirection: Double
    let cosDirection: Double
    /// Rain during the interval, mm.
    let rain: Double

    init(_ o: OutdoorValues) {
        let w = o.windSpeedMS ?? 0
        wind = w
        gustExcess = max(0, (o.windGustMS ?? w) - w)
        if let deg = o.windDirectionDeg {
            let r = deg * .pi / 180
            sinDirection = sin(r)
            cosDirection = cos(r)
        } else {
            // No direction known: the modulation terms vanish and the model
            // falls back to undirected wind rather than losing the row.
            sinDirection = 0
            cosDirection = 0
        }
        rain = o.rainfallMM ?? 0
    }

    /// Terms that scale with a driving gradient (indoor-outdoor temperature or
    /// dew point difference), in a fixed order.
    func scaled(by gradient: Double) -> [Double] {
        [wind * gradient,
         gustExcess * gradient,
         wind * gradient * sinDirection,
         wind * gradient * cosDirection]
    }
}

// MARK: - Psychrometric helpers

enum IndoorPsychrometrics {
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
enum LeastSquares {

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
struct IndoorModel: Sendable, Equatable {
    var plan: OutdoorSourcePlan
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
        var combined: Double

        static func < (a: Score, b: Score) -> Bool { a.combined < b.combined }
    }

    // MARK: Feature construction

    /// dT_in/dt design row. Order must match `temperature`.
    static func temperatureFeatures(_ o: IndoorObservation,
                                    _ plan: OutdoorSourcePlan) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC, let rhOut = out.humidity else { return nil }
        let gap = tOut - o.indoorTempC
        let wetBulb = IndoorPsychrometrics.wetBulbC(
            temperatureC: tOut, relativeHumidity: rhOut,
            pressureHPa: out.stationPressureHPa) ?? tOut
        let terms = InfiltrationTerms(out)
        return [1, gap, o.solar]
            + terms.scaled(by: gap)
            + [terms.rain,
               o.hvac == .evaporativeCooler ? (wetBulb - o.indoorTempC) : 0,
               o.hvac == .airConditioning ? 1 : 0,
               o.hvac == .heating ? 1 : 0]
    }

    /// dD_in/dt design row. Order must match `dewPoint`.
    static func dewPointFeatures(_ o: IndoorObservation,
                                 _ plan: OutdoorSourcePlan) -> [Double]? {
        let out = o.outdoor(plan)
        guard let tOut = out.temperatureC, let rhOut = out.humidity,
              let dOut = IndoorPsychrometrics.dewPointC(
                temperatureC: tOut, relativeHumidity: rhOut) else { return nil }
        let wetBulb = IndoorPsychrometrics.wetBulbC(
            temperatureC: tOut, relativeHumidity: rhOut,
            pressureHPa: out.stationPressureHPa) ?? tOut
        // The same air leakage that carries heat carries moisture, so the
        // infiltration terms appear here too, driven by the dew point gradient.
        let terms = InfiltrationTerms(out)
        let gradient = dOut - o.indoorDewPointC
        return [1, gradient]
            + terms.scaled(by: gradient)
            + [terms.rain,
               o.hvac == .evaporativeCooler ? (wetBulb - o.indoorDewPointC) : 0,
               o.hvac == .airConditioning ? 1 : 0,
               o.hvac == .heating ? 1 : 0]
    }

    /// Observed rates, per hour.
    static func temperatureTarget(_ o: IndoorObservation) -> Double {
        (o.nextIndoorTempC - o.indoorTempC) / (o.dt / 3600)
    }
    static func dewPointTarget(_ o: IndoorObservation) -> Double {
        (o.nextIndoorDewPointC - o.indoorDewPointC) / (o.dt / 3600)
    }

    // MARK: Fitting

    /// Fit both equations on `train` and score on `test`.
    ///
    /// Returns nil when either equation cannot be fitted — too few usable rows,
    /// or a singular design.
    static func fit(train: [IndoorObservation],
                    test: [IndoorObservation],
                    plan: OutdoorSourcePlan,
                    now: Date = .now) -> IndoorModel? {

        func assemble(_ rows: [IndoorObservation],
                      _ features: (IndoorObservation, OutdoorSourcePlan) -> [Double]?,
                      _ target: (IndoorObservation) -> Double) -> ([[Double]], [Double]) {
            var x: [[Double]] = [], y: [Double] = []
            for o in rows {
                guard let f = features(o, plan) else { continue }
                let t = target(o)
                guard t.isFinite, f.allSatisfy(\.isFinite) else { continue }
                x.append(f); y.append(t)
            }
            return (x, y)
        }

        let (xT, yT) = assemble(train, temperatureFeatures, temperatureTarget)
        let (xD, yD) = assemble(train, dewPointFeatures, dewPointTarget)
        guard let betaT = LeastSquares.fit(x: xT, y: yT),
              let betaD = LeastSquares.fit(x: xD, y: yD) else { return nil }

        let (txT, tyT) = assemble(test, temperatureFeatures, temperatureTarget)
        let (txD, tyD) = assemble(test, dewPointFeatures, dewPointTarget)
        guard let score = score(txT, tyT, betaT, txD, tyD, betaD) else { return nil }

        return IndoorModel(plan: plan, temperature: betaT, dewPoint: betaD,
                           score: score, fittedAt: now,
                           observationCount: xT.count)
    }

    private static func score(_ xT: [[Double]], _ yT: [Double], _ bT: [Double],
                              _ xD: [[Double]], _ yD: [Double], _ bD: [Double]) -> Score? {
        guard let rmseT = rmse(xT, yT, bT), let rmseD = rmse(xD, yD, bD) else { return nil }
        // Normalise by the spread of each target so neither equation dominates
        // just by being measured on a livelier quantity.
        let combined = (rmseT / max(spread(yT), 0.05) + rmseD / max(spread(yD), 0.05)) / 2
        guard combined.isFinite else { return nil }
        return Score(temperatureRMSE: rmseT, dewPointRMSE: rmseD, combined: combined)
    }

    private static func rmse(_ x: [[Double]], _ y: [Double], _ beta: [Double]) -> Double? {
        guard !x.isEmpty, x.count == y.count else { return nil }
        var total = 0.0
        for (row, actual) in zip(x, y) {
            guard row.count == beta.count else { return nil }
            let predicted = zip(row, beta).reduce(0) { $0 + $1.0 * $1.1 }
            let e = predicted - actual
            total += e * e
        }
        let value = (total / Double(y.count)).squareRoot()
        return value.isFinite ? value : nil
    }

    private static func spread(_ y: [Double]) -> Double {
        guard y.count > 1 else { return 0 }
        let mean = y.reduce(0, +) / Double(y.count)
        let variance = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(y.count - 1)
        return variance.squareRoot()
    }

    // MARK: Prediction

    /// Indoor temperature and dew point one step of `dt` seconds later.
    ///
    /// Integrating this repeatedly is how the forecast scenarios are produced:
    /// override `hvac` to ask "what if the cooler were on".
    func step(from o: IndoorObservation, dt: Double) -> (temperatureC: Double, dewPointC: Double)? {
        guard let fT = Self.temperatureFeatures(o, plan),
              let fD = Self.dewPointFeatures(o, plan),
              fT.count == temperature.count, fD.count == dewPoint.count else { return nil }
        let rateT = zip(fT, temperature).reduce(0) { $0 + $1.0 * $1.1 }
        let rateD = zip(fD, dewPoint).reduce(0) { $0 + $1.0 * $1.1 }
        let hours = dt / 3600
        let t = o.indoorTempC + rateT * hours
        let d = o.indoorDewPointC + rateD * hours
        guard t.isFinite, d.isFinite else { return nil }
        // The dew point cannot exceed the dry bulb; clamp rather than let a
        // long integration drift into a physically impossible state.
        return (t, min(d, t))
    }
}

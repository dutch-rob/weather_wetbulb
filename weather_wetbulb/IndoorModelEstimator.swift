//
//  IndoorModelEstimator.swift
//  weather_wetbulb
//
//  Decides which source supplies each outdoor variable, and when the model is
//  stale enough to be refitted.
//
//  Two sources describe the same outdoors: Apple WeatherKit, interpolated from
//  a grid model, and the station in the yard. Neither is uniformly better —
//  the station measures this actual site but sits in one spot behind one wall,
//  while WeatherKit is smoothed over a wide area but never misreads because a
//  sensor is in afternoon sun. So the choice is made per variable, empirically,
//  by whichever fits held-out data better.
//

import Foundation

nonisolated enum IndoorModelEstimator {

    // MARK: - Train/test split

    /// Fraction of the (time-ordered) observations held back for scoring.
    static let testFraction = 0.25

    /// Split oldest-first observations into a training head and a test tail.
    ///
    /// The split is by time, never random: the model is used to predict forward,
    /// so it must be scored on data later than everything it learned from.
    /// Shuffling would leak the answer, because readings 18 minutes apart are
    /// nearly the same measurement.
    static func split(_ all: [IndoorObservation]) -> (train: [IndoorObservation], test: [IndoorObservation]) {
        guard all.count >= 8 else { return (all, []) }
        let sorted = all.sorted { $0.date < $1.date }
        let cut = Int(Double(sorted.count) * (1 - testFraction))
        return (Array(sorted[..<cut]), Array(sorted[cut...]))
    }

    // MARK: - The structure, remembered between openings

    /// Everything a search settles except the coefficients themselves.
    ///
    /// The coefficients are refitted every time the screen opens, which takes
    /// milliseconds; choosing the structure costs about a second. So the
    /// structure is remembered and refitted at once, giving the screen a
    /// complete model to show, while a fresh search runs behind it. Screens
    /// that are not about the model — the indoor forecast — reuse the
    /// remembered structure and never search.
    nonisolated struct ModelStructure: Codable, Sendable, Equatable {
        var sources: [String: String]
        var exposure: String
        var coilBaseC: Double
        var coilPerOutdoorDegree: Double
        var coolerFraction: Double
        var acCapacityCPerHour: Double
        var coilNote: String = ""
        var coolerNote: String = ""
        var searchedAt: Date
        var observationsAtSearch: Int

        init(model: IndoorModel, observations: Int, coilNote: String = "", coolerNote: String = "",
             now: Date = .now) {
            sources = Dictionary(uniqueKeysWithValues:
                OutdoorVariable.allCases.map { ($0.rawValue, model.plan[$0].rawValue) })
            exposure = model.exposure.rawValue
            coilBaseC = model.coil.baseC
            coilPerOutdoorDegree = model.coil.perOutdoorDegree
            coolerFraction = model.cooler.fraction
            acCapacityCPerHour = model.thermostat.capacityCPerHour
            self.coilNote = coilNote
            self.coolerNote = coolerNote
            searchedAt = now
            observationsAtSearch = observations
        }

        var plan: OutdoorSourcePlan {
            var out = OutdoorSourcePlan(all: .weatherKit)
            for v in OutdoorVariable.allCases {
                if let raw = sources[v.rawValue], let source = OutdoorSource(rawValue: raw) {
                    out[v] = source
                }
            }
            return out
        }
        var solarExposure: SolarExposureEncoding { SolarExposureEncoding(rawValue: exposure) ?? .none }
        var coil: CoilTemperature { CoilTemperature(baseC: coilBaseC, perOutdoorDegree: coilPerOutdoorDegree) }
        var cooler: CoolerEffectiveness { CoolerEffectiveness(fraction: coolerFraction) }
        var thermostat: ACThermostat { ACThermostat(capacityCPerHour: acCapacityCPerHour) }
    }

    static let structureKey = "indoor.modelStructure"

    static func savedStructure(defaults: UserDefaults = .standard) -> ModelStructure? {
        guard let data = defaults.data(forKey: structureKey) else { return nil }
        return try? JSONDecoder().decode(ModelStructure.self, from: data)
    }

    static func save(_ structure: ModelStructure, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(structure) else { return }
        defaults.set(data, forKey: structureKey)
    }

    /// Fit the coefficients of a remembered structure. Milliseconds, and what
    /// the screen shows while a fresh search runs behind it.
    static func fit(structure: ModelStructure,
                    train: [IndoorObservation],
                    test: [IndoorObservation],
                    now: Date = .now) -> IndoorModel? {
        IndoorModel.fit(train: train, test: test, plan: structure.plan,
                        coil: structure.coil, cooler: structure.cooler,
                        exposure: structure.solarExposure, thermostat: structure.thermostat,
                        settleCapacity: false, now: now)
    }

    // MARK: - Forecast scoring

    /// Longest a forecast runs before it is restarted, and the shortest stretch
    /// worth scoring. Twelve hours is what the forecast screen shows and about
    /// as far as this model should be trusted; three hours is long enough for
    /// the slow terms to show.
    ///
    /// Windows start at 08:00 or 20:00 so that every one of them covers a day
    /// or a night rather than some arbitrary slice, and so that the score means
    /// the same thing from one week to the next. A score whose horizon grew
    /// with the record could not be compared with itself.
    static let forecastWindowHours: Double = 12
    static let minimumForecastWindowHours: Double = 3
    /// Whether 08:00 or 20:00 falls between two readings, which is where one
    /// window ends and the next begins.
    static func crossesHalfDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for hour in [8, 20] {
            guard let boundary = calendar.nextDate(after: a, matching: DateComponents(hour: hour, minute: 0),
                                                   matchingPolicy: .nextTime)
            else { continue }
            if boundary <= b { return true }
        }
        return false
    }

    /// Contiguous blocks the record is cut into. Each is forecast by a model
    /// fitted without it, so no window is ever predicted by its own rows.
    static let scoringBlocks = 4

    /// Runs of consecutive observations, cut into windows of at most a day.
    ///
    /// Consecutive means the next observation starts where this one ended: a
    /// gap in the readings, or a stretch whose equipment nobody recorded, ends
    /// the window rather than being forecast across.
    static func forecastWindows(_ rows: [IndoorObservation]) -> [[IndoorObservation]] {
        var out: [[IndoorObservation]] = [], current: [IndoorObservation] = []
        func flush() {
            if let first = current.first, let last = current.last,
               last.date.addingTimeInterval(last.dt).timeIntervalSince(first.date)
                   >= minimumForecastWindowHours * 3600 {
                out.append(current)
            }
            current = []
        }
        for o in rows.sorted(by: { $0.date < $1.date }) {
            guard o.hvac != .unknown else { flush(); continue }
            if let previous = current.last {
                let expected = previous.date.addingTimeInterval(previous.dt)
                let broken = abs(o.date.timeIntervalSince(expected)) > 60
                let full = o.date.timeIntervalSince(current[0].date) >= forecastWindowHours * 3600
                if broken || full || crossesHalfDay(previous.date, o.date) { flush() }
            }
            current.append(o)
        }
        flush()
        return out
    }

    /// How well a structure forecasts, averaged over the whole record.
    ///
    /// This is what selection compares, in place of the one-step criterion.
    /// The two disagree on exactly the terms that matter most: a mass with a
    /// time constant of days barely moves the next twenty minutes.
    static func forecastScore(all: [IndoorObservation],
                              plan: OutdoorSourcePlan,
                              coil: CoilTemperature = CoilTemperature(),
                              cooler: CoolerEffectiveness = CoolerEffectiveness(),
                              exposure: SolarExposureEncoding = .none,
                              thermostat: ACThermostat = ACThermostat(),
                              settleCapacity: Bool = true,
                              blocks: Int = scoringBlocks,
                              now: Date = .now) -> IndoorModel.ForecastScore? {
        let sorted = all.sorted { $0.date < $1.date }
        guard sorted.count >= 40, blocks > 1 else { return nil }
        let size = sorted.count / blocks
        var errorsT: [Double] = [], errorsD: [Double] = [], windows = 0
        for block in 0..<blocks {
            let lower = block * size
            let upper = block == blocks - 1 ? sorted.count : (block + 1) * size
            let held = Array(sorted[lower..<upper])
            let train = Array(sorted[..<lower]) + Array(sorted[upper...])
            guard let model = IndoorModel.fit(train: train, test: held, plan: plan, coil: coil,
                                              cooler: cooler, exposure: exposure,
                                              thermostat: thermostat, settleCapacity: settleCapacity,
                                              now: now) else { continue }
            for window in forecastWindows(held) {
                guard let errors = model.forecastErrors(over: window) else { continue }
                errorsT.append(contentsOf: errors.temperature.map(abs))
                errorsD.append(contentsOf: errors.dewPoint.map(abs))
                windows += 1
            }
        }
        guard windows > 0, !errorsT.isEmpty else { return nil }
        return IndoorModel.ForecastScore(
            temperatureMAE: errorsT.reduce(0, +) / Double(errorsT.count),
            dewPointMAE: errorsD.reduce(0, +) / Double(errorsD.count),
            windows: windows)
    }

    // MARK: - Source selection

    /// Result of the selection search, kept for the debug screen so the choice
    /// is inspectable rather than mysterious.
    struct Selection: Sendable {
        var model: IndoorModel
        /// Score of the all-WeatherKit baseline, for reference.
        var weatherKitOnly: IndoorModel.Score?
        /// Score of the all-station fit, for reference.
        var stationOnly: IndoorModel.Score?
        /// Variables actually flipped away from the starting plan, in order.
        var swapsAccepted: [OutdoorVariable]
        /// Passes used before the search settled.
        var passes: Int
        /// Criterion reached under each solar-exposure encoding, so the choice
        /// is inspectable and the cost of the richer one is visible.
        var criterionByExposure: [SolarExposureEncoding: Double] = [:]
        /// Bearing the house appears most exposed to, when a harmonic exposure
        /// was fitted. Worth checking against the actual building.
        var exposureBearing: Double?
        /// Whether the coil model was estimated from the data or left at its
        /// default, and why.
        var coilNote: String = ""
        /// The same for the swamp cooler's effectiveness.
        var coolerNote: String = ""
        /// How the AC's cooling power was arrived at.
        var powerNote: String = ""
        /// How well the winning structure forecasts, cross-validated over the
        /// whole record. This is what the search compared.
        var forecastScore: IndoorModel.ForecastScore?
        /// What each solar-exposure encoding reached, for the same reason.
        var forecastByExposure: [SolarExposureEncoding: Double] = [:]
    }

    // MARK: - Cooler effectiveness

    /// Cooler observations needed before effectiveness is fitted rather than
    /// taken from the measured default.
    static let coolerSearchMinimumObservations = 15
    /// Plausible saturation effectiveness for a working wet pad.
    static let coolerEffectivenessRange: ClosedRange<Double> = 0.70...0.95

    /// Search the cooler's saturation effectiveness by held-out error.
    ///
    /// The default comes from a direct measurement of the supply air, which is
    /// better evidence than a handful of observations could provide, so the
    /// search only takes over once there is enough data to beat it.
    static func refineCooler(model: IndoorModel,
                             train: [IndoorObservation],
                             test: [IndoorObservation],
                             settleCapacity: Bool = true,
                             now: Date = .now) -> (model: IndoorModel, note: String) {
        let rows = (train + test).filter { $0.hvac == .evaporativeCooler }
        guard rows.count >= coolerSearchMinimumObservations else {
            return (model, String(format: "assumed %.2f (measured) — only %d cooler observations",
                                  model.cooler.fraction, rows.count))
        }
        // Search only the physically plausible band. A direct evaporative
        // cooler with wet pads runs 0.70–0.95; anything much below that is a
        // dry or failed pad, which is the "vent" state, not this one. Left
        // unbounded the search will happily walk down to a broken-cooler value
        // to soak up error that belongs elsewhere — on a day when the outdoor
        // temperature climbs 10 °C while the cooler runs, "the cooler works
        // badly" and "solar gain is under-credited" fit almost equally well.
        var best = model
        var bestScore = forecastScore(all: train + test, plan: model.plan, coil: model.coil,
                                      cooler: model.cooler, exposure: model.exposure,
                                      thermostat: model.thermostat, settleCapacity: settleCapacity,
                                      now: now)
        for fraction in stride(from: coolerEffectivenessRange.lowerBound,
                               through: coolerEffectivenessRange.upperBound, by: 0.02) {
            let cooler = CoolerEffectiveness(fraction: fraction)
            guard let candidate = IndoorModel.fit(train: train, test: test,
                                                  plan: model.plan,
                                                  coil: model.coil, cooler: cooler,
                                                  exposure: model.exposure,
                                                  thermostat: model.thermostat,
                                                  settleCapacity: settleCapacity, now: now)
            else { continue }
            let score = forecastScore(all: train + test, plan: model.plan, coil: model.coil,
                                      cooler: cooler, exposure: model.exposure,
                                      thermostat: model.thermostat, settleCapacity: settleCapacity,
                                      now: now)
            switch (score, bestScore) {
            case let (new?, current?): if new < current { best = candidate; bestScore = new }
            case (nil, nil):           if candidate.score < best.score { best = candidate }
            default:                   break
            }
        }
        var note: String
        if best.cooler == model.cooler {
            note = String(format: "assumed %.2f (measured) — no value scored better", model.cooler.fraction)
        } else {
            note = String(format: "estimated %.2f from %d cooler observations",
                          best.cooler.fraction, rows.count)
        }
        // A result sitting on the edge means the search wanted to leave the
        // plausible band, which says the cooler term is absorbing error from
        // somewhere else rather than that the pads are unusual.
        let edge = 0.005
        if abs(best.cooler.fraction - coolerEffectivenessRange.lowerBound) < edge
            || abs(best.cooler.fraction - coolerEffectivenessRange.upperBound) < edge {
            note += " — at the edge of the plausible range, so treat it with suspicion"
        }
        return (best, note)
    }

    // MARK: - Coil temperature

    /// AC observations needed before the coil temperature is estimated rather
    /// than assumed. Below this the search would be fitting a handful of points.
    static let coilSearchMinimumObservations = 15
    /// Additional observations, and outdoor spread, before the coil is allowed
    /// to vary WITH outdoor temperature. A slope fitted across two similar days
    /// is not a relationship, it is noise with a direction.
    static let coilSlopeMinimumObservations = 30
    static let coilSlopeMinimumOutdoorSpreadC: Double = 5

    /// Cooling at full duty to try, °C per hour.
    ///
    /// The top of the grid is where the duty stops saturating: past about
    /// 3 °C/h the thermostat is proportional control that never reaches full
    /// power, which keeps flattering the temperature while the dew point gets
    /// worse, so a wider grid would buy one equation at the other's expense.
    /// This house currently chooses the top of the band.
    static let acCapacities: [Double] = [0.5, 0.75, 1, 1.5, 2, 3]

    /// Search the AC's power by forecast, holding everything else fixed.
    ///
    /// Capacity cannot be read off a least-squares fit: it appears only
    /// through the duty, and any capacity low enough to saturate the duty
    /// reproduces the same average cooling. What separates them is the shape
    /// of a run — a powerful machine reaches the setpoint and then cycles,
    /// a weak one pulls down all afternoon — and shape is what a forecast
    /// scores.
    static func refineACPower(model: IndoorModel,
                              train: [IndoorObservation],
                              test: [IndoorObservation],
                              now: Date = .now) -> (model: IndoorModel, note: String) {
        let acRows = (train + test).filter { $0.hvac == .airConditioning }
        guard acRows.count >= coilSearchMinimumObservations else {
            return (model, String(format: "%.2f °C/h from the fit — only %d AC observations",
                                  model.thermostat.capacityCPerHour, acRows.count))
        }
        var best = model
        var bestScore: IndoorModel.ForecastScore?
        for capacity in acCapacities {
            let thermostat = ACThermostat(capacityCPerHour: capacity)
            guard let candidate = IndoorModel.fit(train: train, test: test, plan: model.plan,
                                                  coil: model.coil, cooler: model.cooler,
                                                  exposure: model.exposure, thermostat: thermostat,
                                                  settleCapacity: false, now: now)
            else { continue }
            let score = forecastScore(all: train + test, plan: model.plan, coil: model.coil,
                                      cooler: model.cooler, exposure: model.exposure,
                                      thermostat: thermostat, settleCapacity: false, now: now)
            switch (score, bestScore) {
            case let (new?, current?): if new < current { best = candidate; bestScore = new }
            case (_?, nil):            best = candidate; bestScore = score
            default:                   break
            }
        }
        guard bestScore != nil else {
            return (model, String(format: "%.2f °C/h from the fit — no forecast to judge by",
                                  model.thermostat.capacityCPerHour))
        }
        return (best, String(format: "%.2f °C/h, chosen by forecast", best.thermostat.capacityCPerHour))
    }

    /// Search coil parameters by held-out error, holding the sources fixed.
    ///
    /// The coil affects only rows where the AC was running, while the sources
    /// are driven by the whole record, so refining it afterwards costs far less
    /// than nesting it inside the source search and changes little.
    static func refineCoil(model: IndoorModel,
                           train: [IndoorObservation],
                           test: [IndoorObservation],
                           now: Date = .now) -> (model: IndoorModel, note: String) {
        let acRows = (train + test).filter { $0.hvac == .airConditioning }
        guard acRows.count >= coilSearchMinimumObservations else {
            return (model, "assumed \(Int(model.coil.baseC)) °C — only \(acRows.count) AC observations")
        }

        let outdoorTemps = acRows.compactMap { $0.outdoor(model.plan).temperatureC }
        let spread = (outdoorTemps.max() ?? 0) - (outdoorTemps.min() ?? 0)
        let slopeAllowed = acRows.count >= coilSlopeMinimumObservations
            && spread >= coilSlopeMinimumOutdoorSpreadC
        // Range chosen wide enough that a result landing on the edge is
        // meaningful rather than an artefact of where the grid stopped.
        // Coarser than it was: every candidate now costs a cross-validated
        // forecast rather than one fit, and a coil temperature to the nearest
        // two degrees is as fine as a fortnight of AC hours can justify.
        // A coil rises about 0.5-1 °F per 5 °F outdoors, so 0.10-0.20 °C per
        // °C is the physical band; 0.30 is offered as a wider option and 0 as
        // the null. Anything steeper is the fit chasing something else.
        let slopes: [Double] = slopeAllowed ? [0, 0.10, 0.15, 0.20, 0.30] : [0]

        var best = model
        var bestScore = forecastScore(all: train + test, plan: model.plan, coil: model.coil,
                                      cooler: model.cooler, exposure: model.exposure,
                                      thermostat: model.thermostat, now: now)
        for base in stride(from: 2.0, through: 16.0, by: 2.0) {
            for slope in slopes {
                let coil = CoilTemperature(baseC: base, perOutdoorDegree: slope)
                guard let candidate = IndoorModel.fit(train: train, test: test,
                                                      plan: model.plan,
                                                      coil: coil, cooler: model.cooler,
                                                      exposure: model.exposure,
                                                      thermostat: model.thermostat, now: now)
                else { continue }
                let score = forecastScore(all: train + test, plan: model.plan, coil: coil,
                                          cooler: model.cooler, exposure: model.exposure,
                                          thermostat: model.thermostat, now: now)
                switch (score, bestScore) {
                case let (new?, current?): if new < current { best = candidate; bestScore = new }
                case (nil, nil):           if candidate.score < best.score { best = candidate }
                default:                   break
                }
            }
        }
        var note: String
        if best.coil == model.coil {
            note = "assumed \(Int(model.coil.baseC)) °C — no setting scored better"
        } else if slopeAllowed {
            note = String(format: "estimated %.0f °C at 25 °C outdoor, %+.2f °C per outdoor degree",
                          best.coil.baseC, best.coil.perOutdoorDegree)
            // A coil rises 0.10–0.20 °C per outdoor degree. Landing above that
            // means the term is carrying something else — a hot-afternoon
            // effect the passive half is missing, most likely.
            if best.coil.perOutdoorDegree > 0.25 {
                note += " — steeper than a coil should be, so treat it with suspicion"
            }
        } else {
            note = String(format: "estimated %.0f °C; outdoor range only %.1f °C, too narrow to tell whether it varies",
                          best.coil.baseC, spread)
        }
        return (best, note)
    }

    /// Run the source search under each solar-exposure encoding and keep the
    /// best overall.
    ///
    /// Which encoding suits a house cannot be known in advance — it depends on
    /// which walls and windows the sun reaches — so it is chosen the way the
    /// sources are: by held-out error. The harmonic pair will tend to win while
    /// history is short, since it spends two coefficients where the tent basis
    /// spends eight; the tent basis should overtake it once there is enough
    /// data to support the extra freedom, and only if the house actually has a
    /// pattern a single sinusoid cannot express.

    static func selectModel(train: [IndoorObservation],
                            test: [IndoorObservation],
                            maxPasses: Int = 7,
                            now: Date = .now) -> Selection? {
        var best: Selection?
        var byExposure: [SolarExposureEncoding: Double] = [:]
        var forecastByExposure: [SolarExposureEncoding: Double] = [:]
        let all = train + test

        // How the sun's bearing enters is the one structural choice left to the
        // search, and it is decided by forecasting: each encoding is scored by
        // cross-validated day-ahead error, not by how well it predicts the next
        // twenty minutes. The richer encoding has to forecast better, not
        // merely fit better, which is a far harder thing to buy by chance.
        for exposure in SolarExposureEncoding.allCases {
            guard let candidate = selectSources(train: train, test: test, exposure: exposure,
                                                maxPasses: maxPasses, now: now)
            else { continue }
            byExposure[exposure] = candidate.model.score.criterion
            guard let forecast = candidate.forecastScore else { continue }
            forecastByExposure[exposure] = forecast.combined
            if best == nil || forecast < best!.forecastScore! { best = candidate }
        }
        // Nothing could be forecast — too little history, or every window
        // broken by gaps. Fall back on the one-step criterion rather than
        // refusing to produce a model at all.
        if best == nil {
            for exposure in SolarExposureEncoding.allCases {
                guard let candidate = selectSources(train: train, test: test, exposure: exposure,
                                                    maxPasses: maxPasses, now: now) else { continue }
                if best == nil || candidate.model.score < best!.model.score { best = candidate }
            }
        }
        best?.criterionByExposure = byExposure
        best?.forecastByExposure = forecastByExposure
        if let winner = best, winner.model.exposure == .harmonic,
           winner.model.temperature.count > 4 {
            // Exposure columns follow conduction, daylight and the indoor mass.
            best?.exposureBearing = SolarExposureEncoding.exposureBearing(
                sinCoefficient: winner.model.temperature[3],
                cosCoefficient: winner.model.temperature[4])
        }
        if var winner = best {
            let coil = refineCoil(model: winner.model, train: train, test: test, now: now)
            winner.model = coil.model
            winner.coilNote = coil.note
            let power = refineACPower(model: winner.model, train: train, test: test, now: now)
            winner.model = power.model
            winner.powerNote = power.note
            let cooler = refineCooler(model: winner.model, train: train, test: test,
                                      settleCapacity: false, now: now)
            winner.model = cooler.model
            winner.coolerNote = cooler.note
            // The refinements moved the model, so the headline forecast score
            // has to be the one the final model actually reaches.
            winner.forecastScore = forecastScore(all: all, plan: winner.model.plan,
                                                 coil: winner.model.coil, cooler: winner.model.cooler,
                                                 exposure: winner.model.exposure,
                                                 thermostat: winner.model.thermostat,
                                                 settleCapacity: false, now: now)
                ?? winner.forecastScore
            best = winner
        }
        return best
    }

    /// Which variables the source search may flip, and which move together.
    ///
    /// Only variables the model actually uses are worth a swap — rain and wind
    /// direction no longer enter either equation, and flipping them would cost
    /// fits and change nothing. Wind and gust move as one because gustiness is
    /// the difference between them: taken from different sources it measures
    /// how the two disagree, not how the air gusts.
    static let swappableGroups: [[OutdoorVariable]] = [
        [.temperature], [.humidity], [.windSpeed, .windGust], [.pressure],
    ]

    /// Fit both whole-source models, keep the better, then try swapping one
    /// variable at a time for as long as swaps keep helping.
    ///
    /// Each pass walks all seven variables and keeps any swap that improves the
    /// held-out score. The search stops as soon as a pass accepts nothing, and
    /// in any case after `maxPasses`, which bounds the work: with seven
    /// variables a pathological cycle could otherwise run a long time.
    static func selectSources(train: [IndoorObservation],
                              test: [IndoorObservation],
                              exposure: SolarExposureEncoding = .none,
                              maxPasses: Int = 7,
                              now: Date = .now) -> Selection? {
        guard !train.isEmpty, !test.isEmpty else { return nil }

        let wkPlan = OutdoorSourcePlan(all: .weatherKit)
        let stationPlan = OutdoorSourcePlan(all: .station)
        let all = train + test
        /// A plan is judged by how well it forecasts, falling back to the
        /// one-step criterion only where no window can be forecast at all.
        func rank(_ model: IndoorModel) -> (forecast: IndoorModel.ForecastScore?, model: IndoorModel) {
            (forecastScore(all: all, plan: model.plan, coil: model.coil, cooler: model.cooler,
                           exposure: model.exposure, thermostat: model.thermostat, now: now), model)
        }
        func better(_ a: (forecast: IndoorModel.ForecastScore?, model: IndoorModel),
                    _ b: (forecast: IndoorModel.ForecastScore?, model: IndoorModel)) -> Bool {
            if let x = a.forecast, let y = b.forecast { return x < y }
            return a.model.score < b.model.score
        }

        let wkModel = IndoorModel.fit(train: train, test: test, plan: wkPlan,
                                      exposure: exposure, now: now)
        let stationModel = IndoorModel.fit(train: train, test: test, plan: stationPlan,
                                           exposure: exposure, now: now)

        // Start from whichever whole-source fit forecasts better.
        var current: (forecast: IndoorModel.ForecastScore?, model: IndoorModel)
        switch (wkModel, stationModel) {
        case let (w?, s?): current = better(rank(w), rank(s)) ? rank(w) : rank(s)
        case let (w?, nil): current = rank(w)
        case let (nil, s?): current = rank(s)
        case (nil, nil):    return nil
        }
        var best = current.model

        var accepted: [OutdoorVariable] = []
        var passes = 0
        for pass in 1...max(1, maxPasses) {
            passes = pass
            var changedThisPass = false
            for group in swappableGroups {
                var candidatePlan = best.plan
                for v in group { candidatePlan = candidatePlan.swapping(v) }
                guard let fitted = IndoorModel.fit(
                    train: train, test: test, plan: candidatePlan,
                    exposure: exposure, now: now) else { continue }
                let candidate = rank(fitted)
                // Strictly better only: an equal score means the swap bought
                // nothing, and flipping anyway would let the search oscillate.
                if better(candidate, current), candidate.forecast != current.forecast {
                    current = candidate
                    best = fitted
                    accepted.append(contentsOf: group)
                    changedThisPass = true
                }
            }
            if !changedThisPass { break }
        }

        return Selection(model: best,
                         weatherKitOnly: wkModel?.score,
                         stationOnly: stationModel?.score,
                         swapsAccepted: accepted,
                         passes: passes,
                         forecastScore: current.forecast)
    }

    // MARK: - When to refit

    /// How old a fit may be before it is refitted, given how much history
    /// exists.
    ///
    /// While the station has under a week of data every extra hour changes the
    /// picture materially, so refit hourly. Past that the coefficients settle
    /// and an hourly refit is just battery, so drop to daily.
    static let youngHistoryInterval: TimeInterval = 3600          // 1 hour
    static let matureHistoryInterval: TimeInterval = 24 * 3600    // 24 hours
    static let historyMaturityAge: TimeInterval = 7 * 24 * 3600   // 1 week

    /// Whether the model should be refitted now.
    ///
    /// - Parameters:
    ///   - lastFittedAt: when the current model was fitted; nil if never.
    ///   - firstReadingDate: earliest stored station reading; nil if none.
    static func shouldReestimate(lastFittedAt: Date?,
                                 firstReadingDate: Date?,
                                 now: Date = .now) -> Bool {
        guard firstReadingDate != nil else { return false }   // nothing to fit
        guard let lastFittedAt else { return true }           // never fitted
        let age = now.timeIntervalSince(lastFittedAt)
        guard age > 0 else { return false }
        // "History" is measured up to the last fit, per the rule: how much data
        // existed when we last looked, not how much exists now.
        let historySpan = lastFittedAt.timeIntervalSince(firstReadingDate!)
        let required = historySpan < historyMaturityAge ? youngHistoryInterval
                                                        : matureHistoryInterval
        return age > required
    }
}

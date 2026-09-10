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

enum IndoorModelEstimator {

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
        /// Best held-out score reached under each direction encoding, so the
        /// debug screen can show what the alternative would have cost.
        var scoreByEncoding: [WindDirectionEncoding: IndoorModel.Score] = [:]
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
        for fraction in stride(from: coolerEffectivenessRange.lowerBound,
                               through: coolerEffectivenessRange.upperBound, by: 0.01) {
            let cooler = CoolerEffectiveness(fraction: fraction)
            guard let candidate = IndoorModel.fit(train: train, test: test,
                                                  plan: model.plan, encoding: model.encoding,
                                                  coil: model.coil, cooler: cooler,
                                                  exposure: model.exposure, now: now)
            else { continue }
            if candidate.score < best.score { best = candidate }
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

    /// Search coil parameters by held-out error, holding sources and encoding
    /// fixed.
    ///
    /// The coil affects only rows where the AC was running, while sources and
    /// encoding are driven by the whole record, so refining it afterwards costs
    /// far less than nesting it inside the source search and changes little.
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
        let slopes: [Double] = slopeAllowed
            ? stride(from: 0.0, through: 0.60, by: 0.05).map { $0 } : [0]

        var best = model
        for base in stride(from: 2.0, through: 16.0, by: 1.0) {
            for slope in slopes {
                let coil = CoilTemperature(baseC: base, perOutdoorDegree: slope)
                guard let candidate = IndoorModel.fit(train: train, test: test,
                                                      plan: model.plan,
                                                      encoding: model.encoding,
                                                      coil: coil, cooler: model.cooler,
                                                  exposure: model.exposure, now: now)
                else { continue }
                if candidate.score < best.score { best = candidate }
            }
        }
        let note: String
        if best.coil == model.coil {
            note = "assumed \(Int(model.coil.baseC)) °C — no setting scored better"
        } else if slopeAllowed {
            note = String(format: "estimated %.0f °C at 25 °C outdoor, %+.2f °C per outdoor degree",
                          best.coil.baseC, best.coil.perOutdoorDegree)
        } else {
            note = String(format: "estimated %.0f °C; outdoor range only %.1f °C, too narrow to tell whether it varies",
                          best.coil.baseC, spread)
        }
        return (best, note)
    }

    /// Run the source search under every wind-direction encoding and keep the
    /// best overall.
    ///
    /// Which encoding suits a house cannot be known in advance — it depends on
    /// how the building sits in its wind — so it is chosen the same way the
    /// sources are: by held-out error. The harmonic will tend to win while
    /// history is short, since it spends two coefficients where the tent basis
    /// spends eight; the tent basis should overtake it once there is enough
    /// data to support the extra freedom, and only if the house actually has a
    /// directional pattern a single sinusoid cannot express.
    /// Relative gain a more complex encoding must show before it is preferred.
    /// One percent of the combined score: below that the difference is noise.
    static let meaningfulImprovement = 0.01

    static func selectModel(train: [IndoorObservation],
                            test: [IndoorObservation],
                            maxPasses: Int = 7,
                            now: Date = .now) -> Selection? {
        var best: Selection?
        var scores: [WindDirectionEncoding: IndoorModel.Score] = [:]

        var byExposure: [SolarExposureEncoding: Double] = [:]

        // Every combination of the two circular encodings. The information
        // criterion decides: a richer encoding must pay for its coefficients,
        // so no ad-hoc margin is needed to stop the search buying complexity
        // that changes nothing.
        for encoding in WindDirectionEncoding.allCases {
            for exposure in SolarExposureEncoding.allCases {
                guard let candidate = selectSources(train: train, test: test,
                                                    encoding: encoding, exposure: exposure,
                                                    maxPasses: maxPasses, now: now)
                else { continue }
                let criterion = candidate.model.score.criterion
                if scores[encoding] == nil || candidate.model.score < scores[encoding]! {
                    scores[encoding] = candidate.model.score
                }
                if byExposure[exposure] == nil || criterion < byExposure[exposure]! {
                    byExposure[exposure] = criterion
                }
                if best == nil || candidate.model.score < best!.model.score {
                    best = candidate
                }
            }
        }
        best?.scoreByEncoding = scores
        best?.criterionByExposure = byExposure
        if let winner = best, winner.model.exposure == .harmonic,
           winner.model.temperature.count > 4 {
            // Exposure columns sit at indices 3 and 4: sin then cos.
            best?.exposureBearing = SolarExposureEncoding.exposureBearing(
                sinCoefficient: winner.model.temperature[3],
                cosCoefficient: winner.model.temperature[4])
        }
        if var winner = best {
            let coil = refineCoil(model: winner.model, train: train, test: test, now: now)
            winner.model = coil.model
            winner.coilNote = coil.note
            let cooler = refineCooler(model: winner.model, train: train, test: test, now: now)
            winner.model = cooler.model
            winner.coolerNote = cooler.note
            best = winner
        }
        return best
    }

    /// Fit both whole-source models, keep the better, then try swapping one
    /// variable at a time for as long as swaps keep helping.
    ///
    /// Each pass walks all seven variables and keeps any swap that improves the
    /// held-out score. The search stops as soon as a pass accepts nothing, and
    /// in any case after `maxPasses`, which bounds the work: with seven
    /// variables a pathological cycle could otherwise run a long time.
    static func selectSources(train: [IndoorObservation],
                              test: [IndoorObservation],
                              encoding: WindDirectionEncoding = .harmonic,
                              exposure: SolarExposureEncoding = .none,
                              maxPasses: Int = 7,
                              now: Date = .now) -> Selection? {
        guard !train.isEmpty, !test.isEmpty else { return nil }

        let wkPlan = OutdoorSourcePlan(all: .weatherKit)
        let stationPlan = OutdoorSourcePlan(all: .station)
        let wkModel = IndoorModel.fit(train: train, test: test, plan: wkPlan,
                                      encoding: encoding, exposure: exposure, now: now)
        let stationModel = IndoorModel.fit(train: train, test: test, plan: stationPlan,
                                           encoding: encoding, exposure: exposure, now: now)

        // Start from whichever whole-source fit is better.
        var best: IndoorModel
        switch (wkModel, stationModel) {
        case let (w?, s?): best = w.score <= s.score ? w : s
        case let (w?, nil): best = w
        case let (nil, s?): best = s
        case (nil, nil):    return nil
        }

        var accepted: [OutdoorVariable] = []
        var passes = 0
        for pass in 1...max(1, maxPasses) {
            passes = pass
            var changedThisPass = false
            for v in OutdoorVariable.allCases {
                let candidatePlan = best.plan.swapping(v)
                guard let candidate = IndoorModel.fit(
                    train: train, test: test, plan: candidatePlan,
                    encoding: encoding, exposure: exposure, now: now) else { continue }
                // Strictly better only: an equal score means the swap bought
                // nothing, and flipping anyway would let the search oscillate.
                if candidate.score < best.score {
                    best = candidate
                    accepted.append(v)
                    changedThisPass = true
                }
            }
            if !changedThisPass { break }
        }

        return Selection(model: best,
                         weatherKitOnly: wkModel?.score,
                         stationOnly: stationModel?.score,
                         swapsAccepted: accepted,
                         passes: passes)
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

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
    static func selectModel(train: [IndoorObservation],
                            test: [IndoorObservation],
                            maxPasses: Int = 7,
                            now: Date = .now) -> Selection? {
        var best: Selection?
        var scores: [WindDirectionEncoding: IndoorModel.Score] = [:]

        for encoding in WindDirectionEncoding.allCases {
            guard let candidate = selectSources(train: train, test: test,
                                                encoding: encoding,
                                                maxPasses: maxPasses, now: now)
            else { continue }
            scores[encoding] = candidate.model.score
            if best == nil || candidate.model.score < best!.model.score {
                best = candidate
            }
        }
        best?.scoreByEncoding = scores
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
                              maxPasses: Int = 7,
                              now: Date = .now) -> Selection? {
        guard !train.isEmpty, !test.isEmpty else { return nil }

        let wkPlan = OutdoorSourcePlan(all: .weatherKit)
        let stationPlan = OutdoorSourcePlan(all: .station)
        let wkModel = IndoorModel.fit(train: train, test: test, plan: wkPlan,
                                      encoding: encoding, now: now)
        let stationModel = IndoorModel.fit(train: train, test: test, plan: stationPlan,
                                           encoding: encoding, now: now)

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
                    encoding: encoding, now: now) else { continue }
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

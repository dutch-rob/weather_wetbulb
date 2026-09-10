//
//  IndoorEventDetector.swift
//  weather_wetbulb
//
//  Guesses when the heating or cooling equipment changed, and to what.
//
//  The method is to ask the model rather than to hand-code a rule per
//  transition: run the fitted model forward from each moment under every
//  possible state, and see which one reproduces what the house actually did.
//  The state that explains the next couple of hours best is the guess.
//
//  That reproduces the transition table on its own, because the model already
//  knows where each state drives the air:
//
//    off / vent / heating  ->  indoor dew point heads for the OUTDOOR dew point
//    air conditioning      ->  ... for the COIL temperature, and only while the
//                              dew point is above it
//    evaporative cooler    ->  ... for the cooler's SUPPLY dew point, which
//                              falls short of the outdoor wet bulb
//
//  Dew point is what identifies the state, and it is also the fastest signal:
//  air changes carry moisture immediately while the building's mass drags
//  temperature behind. Temperature then separates the states that share a dew
//  point target — heating warms with no moisture change, venting behaves like
//  nothing running but with far more infiltration, and off is neither.
//
//  A guess is only ever a proposal. Everything here is offered to the user for
//  confirmation, never written as fact: a wrong label is worse than no label,
//  because it teaches the model that equipment does something it does not.
//

import Foundation

/// A proposed change of equipment state, awaiting confirmation.
struct DetectedEvent: Identifiable, Sendable, Equatable {
    let id = UUID()

    /// Best single estimate of when the change happened.
    var date: Date
    /// The change happened somewhere in this window. It is as wide as the gap
    /// between the last reading that still looked like the old state and the
    /// first that looked like the new one — which, across an outage, can be
    /// hours. Reporting the window honestly beats inventing a precise time.
    var earliest: Date
    var latest: Date

    var state: HVACState
    var previousState: HVACState

    /// Thermostat setpoint, when the trace shows the temperature levelling off
    /// while heating or cooling. Nil when nothing plateaued.
    var setpointC: Double?

    /// How much better the proposed state explains the following hours than
    /// the state currently on record, as a fraction of the old error. 0.4 means
    /// it removed 40% of it.
    var improvement: Double

    /// True when the change falls inside a gap in the readings, so the time is
    /// a window rather than a moment.
    var isInsideGap: Bool { latest.timeIntervalSince(earliest) > 45 * 60 }
}

enum IndoorEventDetector {

    /// How far forward to test a hypothesis. Two hours is long enough for the
    /// slow temperature response to show, short enough that the next change is
    /// unlikely to land inside the window.
    static let horizonSteps = 6

    /// How much better a rival state must explain the data before it is worth
    /// bothering the user. Set high deliberately: a false proposal costs the
    /// user's attention and risks a wrong label.
    static let minimumImprovement = 0.30

    /// Temperature change per hour below which the house counts as settled,
    /// used to spot a thermostat holding its setpoint.
    static let plateauRateC = 0.15

    /// States worth proposing.
    static let candidates: [HVACState] = [.off, .evaporativeCooler, .vent,
                                          .airConditioning, .heating]

    /// Worst held-out score a model may have and still be allowed to guess.
    ///
    /// Detection compares hypotheses against the model's own predictions, so a
    /// model that barely beats predicting the average will confidently prefer
    /// whichever state happens to absorb its errors — including contradicting
    /// labels the user entered from direct knowledge. Acting on that would
    /// corrupt the very labels the model is trained on, so below this quality
    /// the detector declines to guess at all rather than guessing badly.
    static let maximumModelScore = 0.85

    // MARK: - Detection

    /// Propose changes across `observations`, newest first.
    ///
    /// - Parameter after: only consider changes later than this, so already
    ///   confirmed history is not re-proposed.
    static func detect(observations: [IndoorObservation],
                       model: IndoorModel,
                       after: Date? = nil) -> [DetectedEvent] {
        guard model.score.combined <= maximumModelScore else { return [] }
        let obs = observations.sorted { $0.date < $1.date }
        guard obs.count > horizonSteps else { return [] }

        var proposals: [(index: Int, state: HVACState, improvement: Double)] = []

        for i in 1..<(obs.count - 2) {
            if let after, obs[i].date <= after { continue }
            let current = obs[i].hvac

            // Only test windows whose recorded state does not change. Where the
            // records already show a change, the horizon straddles it: the
            // "current" state is wrong for part of the window whatever the
            // truth, so some rival always fits better and the detector proposes
            // a change that is already on file.
            let horizonEnd = min(i + horizonSteps, obs.count)
            guard obs[i..<horizonEnd].allSatisfy({ $0.hvac == current }) else { continue }
            guard let baseline = simulationError(obs, from: i, state: current, model: model),
                  baseline > 0 else { continue }

            var best: (HVACState, Double)?
            for candidate in candidates where candidate != current {
                guard let error = simulationError(obs, from: i, state: candidate, model: model)
                else { continue }
                let improvement = (baseline - error) / baseline
                if improvement > minimumImprovement,
                   best == nil || improvement > best!.1 {
                    best = (candidate, improvement)
                }
            }
            if let best { proposals.append((i, best.0, best.1)) }
        }

        return merge(proposals, in: obs, model: model)
    }

    /// Collapse runs of consecutive indices proposing the same state into one
    /// event.
    ///
    /// A real change makes several following observations look wrong, so it
    /// shows up as a run rather than a single index. The change itself belongs
    /// at the START of that run — later indices are only still mismatched
    /// because of the same change.
    private static func merge(_ proposals: [(index: Int, state: HVACState, improvement: Double)],
                              in obs: [IndoorObservation],
                              model: IndoorModel) -> [DetectedEvent] {
        var events: [DetectedEvent] = []
        var i = 0
        while i < proposals.count {
            var j = i
            var strongest = proposals[i]
            while j + 1 < proposals.count,
                  proposals[j + 1].index == proposals[j].index + 1,
                  proposals[j + 1].state == proposals[i].state {
                j += 1
                if proposals[j].improvement > strongest.improvement { strongest = proposals[j] }
            }

            let start = proposals[i].index
            let previous = obs[start - 1]
            let event = DetectedEvent(
                date: obs[start].date,
                // The change happened after the last observation that still fitted
                // the old state, and by the first that did not.
                earliest: previous.date.addingTimeInterval(previous.dt),
                latest: obs[start].date,
                state: proposals[i].state,
                previousState: obs[start].hvac,
                setpointC: setpoint(obs, from: start, state: proposals[i].state),
                improvement: strongest.improvement)
            events.append(event)
            i = j + 1
        }
        return events.sorted { $0.date > $1.date }
    }

    // MARK: - Hypothesis scoring

    /// Error from running the model forward under an assumed state.
    ///
    /// The simulation feeds its own output back in rather than re-reading the
    /// house each step, which is what makes a wrong assumption diverge visibly
    /// instead of being corrected every 20 minutes.
    static func simulationError(_ obs: [IndoorObservation],
                                from index: Int,
                                state: HVACState,
                                model: IndoorModel) -> Double? {
        guard index < obs.count else { return nil }
        var temperature = obs[index].indoorTempC
        var dewPoint = obs[index].indoorDewPointC
        var squared = 0.0
        var steps = 0

        for k in index..<min(index + horizonSteps, obs.count) {
            let actual = obs[k]
            let probe = IndoorObservation(
                date: actual.date, dt: actual.dt,
                indoorTempC: temperature, indoorDewPointC: dewPoint,
                nextIndoorTempC: actual.nextIndoorTempC,
                nextIndoorDewPointC: actual.nextIndoorDewPointC,
                weatherKit: actual.weatherKit, station: actual.station,
                solar: actual.solar, hvac: state)
            guard let next = model.step(from: probe, dt: actual.dt) else { return nil }

            let dT = next.temperatureC - actual.nextIndoorTempC
            let dD = next.dewPointC - actual.nextIndoorDewPointC
            squared += dT * dT + dD * dD
            temperature = next.temperatureC
            dewPoint = next.dewPointC
            steps += 1

            // Stop at a gap: beyond it the simulation is comparing against
            // readings whose history it never saw.
            if k + 1 < obs.count,
               obs[k + 1].date.timeIntervalSince(actual.date) > actual.dt * 2 { break }
        }
        guard steps >= 2 else { return nil }
        return (squared / Double(steps)).squareRoot()
    }

    // MARK: - Setpoint

    /// Estimate the thermostat setting from where the temperature levels off.
    ///
    /// A thermostat cycles once it reaches its target, so the temperature stops
    /// moving while the equipment is still on. That plateau IS the setpoint.
    /// Only meaningful for the thermostat-driven states — the swamp cooler is
    /// usually set low enough that it simply runs until switched off.
    static func setpoint(_ obs: [IndoorObservation],
                         from index: Int,
                         state: HVACState) -> Double? {
        guard state == .airConditioning || state == .heating else { return nil }
        var settled: [Double] = []
        for k in index..<min(index + horizonSteps * 2, obs.count) {
            let o = obs[k]
            let ratePerHour = (o.nextIndoorTempC - o.indoorTempC) / (o.dt / 3600)
            if abs(ratePerHour) <= plateauRateC {
                settled.append(o.nextIndoorTempC)
            } else if !settled.isEmpty {
                break                       // moved again: the plateau is over
            }
        }
        // One quiet step is not a plateau; a thermostat holding steady shows
        // several in a row.
        guard settled.count >= 3 else { return nil }
        return settled.reduce(0, +) / Double(settled.count)
    }
}

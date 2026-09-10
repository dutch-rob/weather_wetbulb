//
//  IndoorEventDetectorTests.swift
//  weather_wetbulbTests
//
//  A synthetic house is run with a KNOWN equipment schedule, mislabelled, and
//  the detector asked to find the change. Testing against a known truth is the
//  only way to tell a working detector from one that merely produces plausible
//  output.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct IndoorEventDetectorTests {

    /// A house obeying the model's own equations, run under a schedule.
    ///
    /// `truth` says what was really running at each step; `labelled` says what
    /// the records claim. Where they differ, the detector should notice.
    static func house(count: Int,
                      truth: (Int) -> HVACState,
                      labelled: (Int) -> HVACState,
                      coil: CoilTemperature = CoilTemperature(),
                      cooler: CoolerEffectiveness = CoolerEffectiveness())
    -> (rows: [IndoorObservation], model: IndoorModel) {

        // Coefficients chosen to look like a real house: slow conduction, fast
        // moisture exchange, strong AC, gentle cooler.
        let conduction = 0.30, moisture = 0.9
        let acRate = -1.2, acLatent = -0.35, acLatentOnTemp = 0.05
        let coolerRate = 0.35, ventRate = 0.5, heatRate = 1.5

        var rows: [IndoorObservation] = []
        var indoorT = 24.0
        var indoorD = 12.0
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let step = 1200.0
        let hours = step / 3600

        for i in 0..<count {
            let phase = Double(i) * step / 86400 * 2 * .pi
            let outT = 28 + 6 * sin(phase)
            let outRH = 30 + 10 * cos(phase)
            let outD = IndoorPsychrometrics.dewPointC(temperatureC: outT, relativeHumidity: outRH) ?? 10
            let wb = IndoorPsychrometrics.wetBulbC(temperatureC: outT, relativeHumidity: outRH,
                                                   pressureHPa: 895) ?? outT
            let state = truth(i)

            var rateT = conduction * (outT - indoorT)
            var rateD = moisture * (outD - indoorD)
            switch state {
            case .airConditioning:
                let drive = coil.latentDrive(indoorDewPointC: indoorD, outdoorC: outT)
                rateT += acRate + acLatentOnTemp * drive
                rateD += acLatent * drive
            case .evaporativeCooler:
                rateT += coolerRate * (cooler.supplyTemperatureC(outdoorC: outT, wetBulbC: wb) - indoorT)
                rateD += coolerRate * (cooler.supplyDewPointC(outdoorDewPointC: outD, wetBulbC: wb) - indoorD)
            case .vent:
                rateT += ventRate * (outT - indoorT)
                rateD += ventRate * (outD - indoorD)
            case .heating:
                rateT += heatRate
            default:
                break
            }
            let nextT = indoorT + rateT * hours
            let nextD = min(indoorD + rateD * hours, nextT)

            let values = OutdoorValues(temperatureC: outT, humidity: outRH,
                                       windSpeedMS: 2, windGustMS: 3,
                                       windDirectionDeg: Double(i % 16) * 22.5,
                                       rainfallMM: 0, stationPressureHPa: 895)
            rows.append(IndoorObservation(
                date: start.addingTimeInterval(Double(i) * step), dt: step,
                indoorTempC: indoorT, indoorDewPointC: indoorD,
                nextIndoorTempC: nextT, nextIndoorDewPointC: nextD,
                weatherKit: values, station: values,
                solar: max(0, sin(phase)), hvac: labelled(i)))
            indoorT = nextT
            indoorD = nextD
        }

        // Fit on the TRUTHFULLY laballed version so the detector has a sound
        // model to reason with; detection is then tested on the mislabelled rows.
        let truthful = rows.enumerated().map { i, o in
            IndoorObservation(date: o.date, dt: o.dt,
                              indoorTempC: o.indoorTempC, indoorDewPointC: o.indoorDewPointC,
                              nextIndoorTempC: o.nextIndoorTempC,
                              nextIndoorDewPointC: o.nextIndoorDewPointC,
                              weatherKit: o.weatherKit, station: o.station,
                              solar: o.solar, hvac: truth(i))
        }
        let (train, test) = IndoorModelEstimator.split(truthful)
        let model = IndoorModel.fit(train: train, test: test,
                                    plan: OutdoorSourcePlan(all: .station),
                                    encoding: .harmonic, coil: coil, cooler: cooler)!
        return (rows, model)
    }

    // MARK: - Finding a change

    @Test func findsAnUnrecordedAirConditioningStart() {
        // AC really starts at step 120; the records still say nothing running.
        let at = 120
        let built = Self.house(count: 200,
                               truth: { $0 >= at ? .airConditioning : .off },
                               labelled: { _ in .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(!events.isEmpty)
        guard let found = events.last else { return }   // oldest = the real one
        #expect(found.state == .airConditioning)
        // Within a step or two of the truth.
        let truthDate = built.rows[at].date
        #expect(abs(found.date.timeIntervalSince(truthDate)) <= 2 * 1200)
    }

    @Test func findsAnUnrecordedSwampCoolerStart() {
        // The cooler is the clearest case: it is the only state that RAISES the
        // dew point, so nothing else can explain the trace.
        let at = 110
        let built = Self.house(count: 200,
                               truth: { $0 >= at ? .evaporativeCooler : .off },
                               labelled: { _ in .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(events.contains { $0.state == .evaporativeCooler })
    }

    @Test func findsHeatingWhichMovesTemperatureButNotMoisture() {
        let at = 100
        let built = Self.house(count: 180,
                               truth: { $0 >= at ? .heating : .off },
                               labelled: { _ in .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(events.contains { $0.state == .heating })
    }

    @Test func proposesNothingWhenTheRecordsAreAlreadyRight() {
        // The costly failure is crying wolf: a false proposal risks a wrong
        // label, which is worse than no label at all.
        let at = 120
        let built = Self.house(count: 200,
                               truth: { $0 >= at ? .airConditioning : .off },
                               labelled: { $0 >= at ? .airConditioning : .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(events.isEmpty)
    }

    @Test func proposesNothingWhenNothingEverHappens() {
        let built = Self.house(count: 200, truth: { _ in .off }, labelled: { _ in .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(events.isEmpty)
    }

    // MARK: - Reporting

    @Test func eventsComeBackNewestFirst() {
        // Two changes the records missed: AC at 80, then the swamp cooler at
        // 140. Note a return to .off would NOT appear here — the records
        // already say .off, so there is no discrepancy to find. The user works
        // backwards through proposals, so the newest must lead.
        let built = Self.house(count: 220,
                               truth: { i in
                                   if i >= 140 { return .evaporativeCooler }
                                   if i >= 80 { return .airConditioning }
                                   return .off
                               },
                               labelled: { _ in .off })
        let events = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(events.count >= 2)
        for (a, b) in zip(events, events.dropFirst()) {
            #expect(a.date >= b.date)
        }
    }

    @Test func theChangeIsReportedAsAWindowNotAMoment() {
        let at = 120
        let built = Self.house(count: 200,
                               truth: { $0 >= at ? .airConditioning : .off },
                               labelled: { _ in .off })
        guard let found = IndoorEventDetector.detect(observations: built.rows,
                                                     model: built.model).last else {
            #expect(Bool(false)); return
        }
        // The window brackets the estimate rather than pretending to a moment.
        #expect(found.earliest <= found.date)
        #expect(found.latest >= found.earliest)
        // Regular readings, no outage, so the window is tight.
        #expect(!found.isInsideGap)
    }

    @Test func alreadyConfirmedHistoryIsNotReproposed() {
        let at = 120
        let built = Self.house(count: 200,
                               truth: { $0 >= at ? .airConditioning : .off },
                               labelled: { _ in .off })
        let all = IndoorEventDetector.detect(observations: built.rows, model: built.model)
        #expect(!all.isEmpty)
        // Asking only for changes after the last row leaves nothing to propose.
        let cutoff = built.rows.last!.date
        let none = IndoorEventDetector.detect(observations: built.rows,
                                              model: built.model, after: cutoff)
        #expect(none.isEmpty)
    }

    @Test func aPoorModelDeclinesToGuess() {
        // A model that barely beats the average will happily prefer whichever
        // state soaks up its own errors — including contradicting labels the
        // user entered from direct knowledge. Acting on that corrupts the
        // labels the model is trained on, so it must stay silent.
        let at = 120
        var built = Self.house(count: 200,
                               truth: { $0 >= at ? .airConditioning : .off },
                               labelled: { _ in .off })
        #expect(!IndoorEventDetector.detect(observations: built.rows, model: built.model).isEmpty)

        var poor = built.model
        poor.score = IndoorModel.Score(temperatureRMSE: 1, dewPointRMSE: 1,
                                       combined: IndoorEventDetector.maximumModelScore + 0.01)
        #expect(IndoorEventDetector.detect(observations: built.rows, model: poor).isEmpty)
    }

    // MARK: - Setpoint

    @Test func setpointIsReadFromWhereTheTemperatureLevelsOff() {
        // A house whose temperature flattens: a thermostat holding its target.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var rows: [IndoorObservation] = []
        let values = OutdoorValues(temperatureC: 30, humidity: 30, windSpeedMS: 2,
                                   windGustMS: 3, windDirectionDeg: 180,
                                   rainfallMM: 0, stationPressureHPa: 895)
        for i in 0..<12 {
            // Falls to 21.0, then holds there.
            let t = max(21.0, 24.0 - Double(i) * 0.5)
            let next = max(21.0, 24.0 - Double(i + 1) * 0.5)
            rows.append(IndoorObservation(
                date: start.addingTimeInterval(Double(i) * 1200), dt: 1200,
                indoorTempC: t, indoorDewPointC: 12,
                nextIndoorTempC: next, nextIndoorDewPointC: 12,
                weatherKit: values, station: values, solar: 0, hvac: .airConditioning))
        }
        let estimate = IndoorEventDetector.setpoint(rows, from: 0, state: .airConditioning)
        #expect(estimate != nil)
        #expect(abs(estimate! - 21.0) < 0.1)
    }

    @Test func noSetpointWithoutAPlateau() {
        let built = Self.house(count: 60,
                               truth: { _ in .airConditioning },
                               labelled: { _ in .airConditioning })
        // Temperature is still moving throughout, so nothing has settled.
        #expect(IndoorEventDetector.setpoint(built.rows, from: 0, state: .airConditioning) == nil)
    }

    @Test func setpointIsOnlyMeaningfulForThermostatStates() {
        let built = Self.house(count: 60, truth: { _ in .off }, labelled: { _ in .off })
        #expect(IndoorEventDetector.setpoint(built.rows, from: 0, state: .evaporativeCooler) == nil)
        #expect(IndoorEventDetector.setpoint(built.rows, from: 0, state: .off) == nil)
    }
}

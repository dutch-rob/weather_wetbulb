//
//  IndoorModelTests.swift
//  weather_wetbulbTests
//
//  The estimator is fitted against a synthetic house whose true coefficients we
//  choose, so the tests can assert that fitting recovers them rather than just
//  that it produces some numbers.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct IndoorModelTests {

    // MARK: - Psychrometrics

    @Test func dewPointIsTheTemperatureAtSaturation() {
        // At 100% humidity the dew point IS the dry bulb.
        let saturated = IndoorPsychrometrics.dewPointC(temperatureC: 21, relativeHumidity: 100)
        #expect(saturated != nil)
        #expect(abs(saturated! - 21) < 0.2)

        // Drier air must give a dew point below the dry bulb.
        let dry = IndoorPsychrometrics.dewPointC(temperatureC: 25, relativeHumidity: 30)
        #expect(dry != nil)
        #expect(dry! < 25)
        // 25 °C at 30% is about 6 °C.
        #expect(abs(dry! - 6.2) < 1.5)
    }

    @Test func dewPointAcceptsEitherHumidityScale() {
        let asPercent = IndoorPsychrometrics.dewPointC(temperatureC: 20, relativeHumidity: 55)
        let asFraction = IndoorPsychrometrics.dewPointC(temperatureC: 20, relativeHumidity: 0.55)
        #expect(asPercent != nil && asFraction != nil)
        #expect(abs(asPercent! - asFraction!) < 0.001)
    }

    @Test func dewPointRejectsImpossibleHumidity() {
        #expect(IndoorPsychrometrics.dewPointC(temperatureC: 20, relativeHumidity: 0) == nil)
    }

    // MARK: - Least squares

    @Test func leastSquaresRecoversKnownCoefficients() {
        // y = 2 + 3*x1 - 1.5*x2, exactly.
        let truth = [2.0, 3.0, -1.5]
        var x: [[Double]] = [], y: [Double] = []
        for i in 0..<40 {
            let x1 = Double(i % 7) * 0.5
            let x2 = Double(i % 5) - 2
            x.append([1, x1, x2])
            y.append(truth[0] + truth[1] * x1 + truth[2] * x2)
        }
        let beta = LeastSquares.fit(x: x, y: y)
        #expect(beta != nil)
        for (got, want) in zip(beta!, truth) { #expect(abs(got - want) < 1e-6) }
    }

    @Test func leastSquaresRefusesUnderdeterminedSystems() {
        // Two rows cannot determine three unknowns.
        let x = [[1.0, 2.0, 3.0], [1.0, 4.0, 9.0]]
        #expect(LeastSquares.fit(x: x, y: [1, 2]) == nil)
    }

    // MARK: - Information criterion

    @Test func theCriterionChargesForExtraCoefficients() {
        // Same fit quality, more parameters: the richer model must score worse,
        // which is what stops an eight-knot encoding being adopted for nothing.
        let lean = IndoorModel.informationCriterion(
            residualSumOfSquares: 10, observations: 40, parameters: 5)
        let rich = IndoorModel.informationCriterion(
            residualSumOfSquares: 10, observations: 40, parameters: 13)
        #expect(rich > lean)
    }

    @Test func theCriterionStillPrefersAGenuinelyBetterFit() {
        // Extra coefficients are worth paying for when they actually explain
        // something.
        let lean = IndoorModel.informationCriterion(
            residualSumOfSquares: 40, observations: 40, parameters: 5)
        let rich = IndoorModel.informationCriterion(
            residualSumOfSquares: 8, observations: 40, parameters: 13)
        #expect(rich < lean)
    }

    @Test func theCriterionRefusesModelsTooLargeForTheValidationSet() {
        // With more parameters than validation rows the correction blows up and
        // the number would flatter rather than inform, so it is rejected.
        #expect(IndoorModel.informationCriterion(
            residualSumOfSquares: 10, observations: 12, parameters: 12) == .infinity)
    }

    @Test func exposureBearingRecoversTheDirectionFromTheHarmonicPair() {
        // A pure sine component means the house faces east (90 degrees).
        #expect(abs(SolarExposureEncoding.exposureBearing(
            sinCoefficient: 1, cosCoefficient: 0)! - 90) < 1e-6)
        // Pure negative sine means west, the case that matters here.
        #expect(abs(SolarExposureEncoding.exposureBearing(
            sinCoefficient: -1, cosCoefficient: 0)! - 270) < 1e-6)
        // Nothing fitted, no bearing to claim.
        #expect(SolarExposureEncoding.exposureBearing(
            sinCoefficient: 0, cosCoefficient: 0) == nil)
    }

    // MARK: - Sign constraints

    @Test func constrainedFitRefusesAPhysicallyImpossibleSign() {
        // y is driven DOWN by x1, but x1 is constrained non-negative. The fit
        // must zero it rather than return the negative value that scores best.
        var x: [[Double]] = [], y: [Double] = []
        for i in 0..<40 {
            let x1 = Double(i % 7) * 0.5
            x.append([1, x1])
            y.append(2 - 3 * x1)
        }
        let free = LeastSquares.fit(x: x, y: y)
        #expect(free != nil)
        #expect(free![1] < 0)                      // unconstrained wants negative

        let bound = LeastSquares.fit(x: x, y: y, constraints: [.free, .nonNegative])
        #expect(bound != nil)
        #expect(bound![1] == 0)                    // clamped away
    }

    @Test func constrainedFitLeavesLegitimateSignsAlone() {
        var x: [[Double]] = [], y: [Double] = []
        for i in 0..<40 {
            let x1 = Double(i % 7) * 0.5
            x.append([1, x1])
            y.append(2 + 3 * x1)
        }
        let bound = LeastSquares.fit(x: x, y: y, constraints: [.free, .nonNegative])
        #expect(bound != nil)
        #expect(abs(bound![1] - 3) < 1e-6)
    }

    @Test func coolerCanNeverBeFittedAsAHeater() {
        // The constraint that matters most: whatever the residuals look like,
        // running a swamp cooler must never come out as warming the house.
        let constraints = IndoorModel.temperatureConstraints(.harmonic)
        let count = 13                              // harmonic temperature width
        #expect(constraints.count == count)
        let coolerIndex = IndoorModel.equipmentIndex(.evaporativeCooler, in: count)!
        let heatIndex = IndoorModel.equipmentIndex(.heating, in: count)!
        let acIndex = IndoorModel.equipmentIndex(.airConditioning, in: count)!
        #expect(constraints[coolerIndex].violated(by: -0.1))
        #expect(!constraints[coolerIndex].violated(by: 0.1))
        #expect(constraints[heatIndex].violated(by: -0.1))
        #expect(constraints[acIndex].violated(by: 0.1))     // AC cannot warm
    }

    // MARK: - Synthetic house

    /// A house obeying exactly the model's own equations, so a correct fit must
    /// recover these numbers.
    struct SyntheticHouse {
        var conduction = 0.35        // per hour, toward outdoor temperature
        var solarGain = 1.8
        var moistureExchange = 0.5   // per hour, toward outdoor dew point
        /// Undirected wind-driven infiltration, per (m/s . K . hour).
        var windInfiltration = 0.0
        /// How much infiltration depends on the wind's bearing. Non-zero means
        /// wind from one direction leaks more than from the opposite one.
        var windSinInfiltration = 0.0

        /// Generate `count` observations at `stepSeconds` apart.
        ///
        /// `stationBias` shifts the station's reported outdoor temperature away
        /// from truth, which is how the tests make one source genuinely worse.
        func observations(count: Int,
                          stepSeconds: Double = 1200,
                          stationBias: Double = 0,
                          weatherKitBias: Double = 0,
                          hvac: HVACState = .off) -> [IndoorObservation] {
            var out: [IndoorObservation] = []
            var indoorT = 22.0
            var indoorD = 8.0
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let hours = stepSeconds / 3600

            for i in 0..<count {
                // A daily cycle plus a slow drift, so the regressors actually vary.
                let phase = Double(i) * stepSeconds / 86400 * 2 * .pi
                let trueOutT = 18 + 9 * sin(phase)
                let trueOutRH = 45 + 15 * cos(phase)
                let solar = max(0, sin(phase)) // 0…1
                // Wind must VARY: with constant wind the `wind * gap` column is
                // an exact multiple of the `gap` column, the design is singular
                // and the ridge splits conduction arbitrarily between them.
                let wind = 1.5 + 1.2 * sin(phase * 1.7)
                // Direction must vary too, or the sin/cos columns are constant
                // multiples of the wind column and the design goes singular.
                let direction = (Double(i) * 37).truncatingRemainder(dividingBy: 360)
                // Gust must not be a fixed multiple of wind: gustExcess would
                // then be an exact copy of the wind column and the pair would be
                // unidentifiable.
                let gust = wind + 0.8 + 0.6 * cos(phase * 2.3)
                let trueOutD = IndoorPsychrometrics.dewPointC(
                    temperatureC: trueOutT, relativeHumidity: trueOutRH) ?? 8

                let dirRad = direction * .pi / 180
                let infiltration = (windInfiltration + windSinInfiltration * sin(dirRad))
                    * wind * (trueOutT - indoorT)
                let rateT = conduction * (trueOutT - indoorT) + solarGain * solar + infiltration
                let rateD = moistureExchange * (trueOutD - indoorD)
                let nextT = indoorT + rateT * hours
                let nextD = indoorD + rateD * hours

                out.append(IndoorObservation(
                    date: start.addingTimeInterval(Double(i) * stepSeconds),
                    dt: stepSeconds,
                    indoorTempC: indoorT,
                    indoorDewPointC: indoorD,
                    nextIndoorTempC: nextT,
                    nextIndoorDewPointC: nextD,
                    weatherKit: OutdoorValues(
                        temperatureC: trueOutT + weatherKitBias,
                        humidity: trueOutRH,
                        windSpeedMS: wind,
                        windGustMS: gust,
                        windDirectionDeg: direction,
                        rainfallMM: 0,
                        stationPressureHPa: 890),
                    station: OutdoorValues(
                        temperatureC: trueOutT + stationBias,
                        humidity: trueOutRH,
                        windSpeedMS: wind,
                        windGustMS: gust,
                        windDirectionDeg: direction,
                        rainfallMM: 0,
                        stationPressureHPa: 890),
                    solar: solar,
                    hvac: hvac))
                indoorT = nextT
                indoorD = nextD
            }
            return out
        }
    }

    @Test func fitRecoversTheHousesConductionAndSolarGain() {
        let house = SyntheticHouse()
        let all = house.observations(count: 300)
        let (train, test) = IndoorModelEstimator.split(all)
        let model = IndoorModel.fit(train: train, test: test,
                                    plan: OutdoorSourcePlan(all: .weatherKit))
        #expect(model != nil)
        guard let model else { return }

        // Index 1 is the (T_out - T_in) conduction coefficient, 2 the solar one;
        // 3…6 are the infiltration terms and 7 rain, none of which drive the
        // synthetic house, so they should come out near zero.
        #expect(abs(model.temperature[1] - house.conduction) < 0.02)
        #expect(abs(model.temperature[2] - house.solarGain) < 0.05)
        #expect(abs(model.temperature[7]) < 0.05)          // no rain in fixture
        // dewPoint[1] is the (D_out - D_in) coefficient.
        #expect(abs(model.dewPoint[1] - house.moistureExchange) < 0.02)
        // A house generated by the model's own equations should fit almost
        // exactly on held-out data.
        #expect(model.score.temperatureRMSE < 0.05)
    }

    @Test func fitRecoversDirectionDependentInfiltration() {
        // A house that leaks more when the wind comes from one side. Raw
        // degrees could not express this: 350 and 10 would sit at opposite ends
        // of the range despite being nearly the same wind. The sin/cos pair can.
        var house = SyntheticHouse()
        house.windInfiltration = 0.10
        house.windSinInfiltration = 0.08
        let all = house.observations(count: 400)
        let (train, test) = IndoorModelEstimator.split(all)
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit))
        else { #expect(Bool(false)); return }

        // Index 3 is wind x gap, 5 is wind x gap x sin(direction), 6 the cosine
        // partner — which this house does not use, so it should stay near zero.
        #expect(abs(model.temperature[3] - house.windInfiltration) < 0.02)
        #expect(abs(model.temperature[5] - house.windSinInfiltration) < 0.02)
        #expect(abs(model.temperature[6]) < 0.02)
        #expect(model.score.temperatureRMSE < 0.05)
    }

    @Test func steppingForwardReproducesTheHouse() {
        let house = SyntheticHouse()
        let all = house.observations(count: 300)
        let (train, test) = IndoorModelEstimator.split(all)
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit)),
              let probe = test.first else { #expect(Bool(false)); return }

        let next = model.step(from: probe, dt: probe.dt)
        #expect(next != nil)
        #expect(abs(next!.temperatureC - probe.nextIndoorTempC) < 0.05)
        #expect(abs(next!.dewPointC - probe.nextIndoorDewPointC) < 0.05)
    }

    @Test func dewPointNeverExceedsDryBulbWhenStepping() {
        let house = SyntheticHouse()
        let all = house.observations(count: 120)
        let (train, test) = IndoorModelEstimator.split(all)
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit)),
              var probe = test.first else { #expect(Bool(false)); return }
        // Force a physically impossible start: dew point above dry bulb.
        probe = IndoorObservation(
            date: probe.date, dt: probe.dt,
            indoorTempC: 15, indoorDewPointC: 25,
            nextIndoorTempC: probe.nextIndoorTempC,
            nextIndoorDewPointC: probe.nextIndoorDewPointC,
            weatherKit: probe.weatherKit, station: probe.station,
            solar: probe.solar, hvac: probe.hvac)
        let next = model.step(from: probe, dt: 3600)
        #expect(next != nil)
        #expect(next!.dewPointC <= next!.temperatureC + 1e-9)
    }

    // MARK: - Source selection

    @Test func selectionPrefersTheAccurateSource() {
        // The station reports outdoor temperature 4 °C too high; WeatherKit is
        // truthful. Selection must end up on WeatherKit for temperature.
        let house = SyntheticHouse()
        let all = house.observations(count: 300, stationBias: 4.0)
        let (train, test) = IndoorModelEstimator.split(all)

        let selection = IndoorModelEstimator.selectSources(train: train, test: test)
        #expect(selection != nil)
        guard let selection else { return }
        #expect(selection.model.plan[.temperature] == .weatherKit)
    }

    @Test func selectionPrefersTheStationWhenWeatherKitIsWrong() {
        // Same test with the bias on the other foot, so the result cannot be an
        // artefact of WeatherKit being the starting plan.
        let house = SyntheticHouse()
        let all = house.observations(count: 300, weatherKitBias: 4.0)
        let (train, test) = IndoorModelEstimator.split(all)

        let selection = IndoorModelEstimator.selectSources(train: train, test: test)
        #expect(selection != nil)
        #expect(selection?.model.plan[.temperature] == .station)
    }

    @Test func selectionStopsWhenNoSwapHelps() {
        // Both sources identical: no swap can improve anything, so the search
        // must settle on the first pass rather than spinning to maxPasses.
        let house = SyntheticHouse()
        let all = house.observations(count: 200)
        let (train, test) = IndoorModelEstimator.split(all)

        let selection = IndoorModelEstimator.selectSources(train: train, test: test)
        #expect(selection != nil)
        #expect(selection!.passes == 1)
        #expect(selection!.swapsAccepted.isEmpty)
    }

    @Test func selectionNeedsBothTrainAndTestRows() {
        #expect(IndoorModelEstimator.selectSources(train: [], test: []) == nil)
    }

    // MARK: - Split

    @Test func splitHoldsOutTheLatestObservations() {
        let all = SyntheticHouse().observations(count: 100)
        let (train, test) = IndoorModelEstimator.split(all)
        #expect(train.count == 75)
        #expect(test.count == 25)
        // Every test row must be later than every training row.
        #expect(train.last!.date < test.first!.date)
    }

    // MARK: - Refit cadence

    @Test func refitsHourlyWhileHistoryIsYoung() {
        let now = Date()
        let firstReading = now.addingTimeInterval(-2 * 86400)      // 2 days of data
        let fitted = now.addingTimeInterval(-90 * 60)              // 90 minutes ago
        #expect(IndoorModelEstimator.shouldReestimate(
            lastFittedAt: fitted, firstReadingDate: firstReading, now: now))

        let recent = now.addingTimeInterval(-30 * 60)              // 30 minutes ago
        #expect(!IndoorModelEstimator.shouldReestimate(
            lastFittedAt: recent, firstReadingDate: firstReading, now: now))
    }

    @Test func refitsDailyOnceHistoryIsMature() {
        let now = Date()
        let firstReading = now.addingTimeInterval(-30 * 86400)     // a month of data
        let fitted = now.addingTimeInterval(-3 * 3600)             // 3 hours ago

        // Three hours is plenty when young, but not once history is mature.
        #expect(!IndoorModelEstimator.shouldReestimate(
            lastFittedAt: fitted, firstReadingDate: firstReading, now: now))

        let stale = now.addingTimeInterval(-26 * 3600)             // 26 hours ago
        #expect(IndoorModelEstimator.shouldReestimate(
            lastFittedAt: stale, firstReadingDate: firstReading, now: now))
    }

    @Test func refitsImmediatelyWhenNeverFittedAndNotAtAllWithoutData() {
        let now = Date()
        #expect(IndoorModelEstimator.shouldReestimate(
            lastFittedAt: nil, firstReadingDate: now.addingTimeInterval(-3600), now: now))
        // No station data at all: nothing to fit, so never.
        #expect(!IndoorModelEstimator.shouldReestimate(
            lastFittedAt: nil, firstReadingDate: nil, now: now))
    }
}

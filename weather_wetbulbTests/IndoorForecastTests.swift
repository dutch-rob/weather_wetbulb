//
//  IndoorForecastTests.swift
//  weather_wetbulbTests
//
//  Running the model forward under a scenario. The arithmetic is the model's,
//  already tested; what is new here is the scenario — when equipment starts and
//  stops — and the state a forecast has to carry with it.
//

import Testing
import Foundation
import CoreLocation
@testable import weather_wetbulb

struct IndoorForecastTests {

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Thirteen hours of unchanging weather: hot, dry, calm. Enough for a
    /// twelve-hour forecast to run to its end.
    private static func weather(temperatureC: Double = 33, humidity: Double = 0.15,
                                from: Date = start) -> [ForecastPoint] {
        (0...13).map { hour in
            let date = from.addingTimeInterval(Double(hour) * 3600 - 1800)
            let dewPoint = IndoorPsychrometrics.dewPointC(temperatureC: temperatureC,
                                                          relativeHumidity: humidity * 100) ?? 0
            return ForecastPoint(
                kind: .forecast, date: date, symbolName: "sun.max", isDaylight: true, uvIndex: 5,
                temperatureF: temperatureC * 9 / 5 + 32, temperatureC: temperatureC,
                apparentTemperatureF: temperatureC * 9 / 5 + 32, apparentTemperatureC: temperatureC,
                wetBulbF: 0, wetBulbC: 0,
                dewPointF: dewPoint * 9 / 5 + 32, dewPointC: dewPoint,
                precipProbability: 0, precipitationMM: 0,
                windSpeedMPH: 4, windSpeedKPH: 6, windGustMPH: 6, windGustKPH: 10,
                windDirectionDegrees: 200, cloudCover: 0.1, cloudCoverLow: 0, cloudCoverMedium: 0,
                cloudCoverHigh: 0.1, humidity: humidity, stationPressurePa: 89_000)
        }
    }

    /// A model with round numbers: the house leaks slowly, the cooler pulls
    /// hard toward its supply air, the AC cools a degree an hour at full duty.
    private static func model() -> IndoorModel {
        // Passive temperature: conduction, daytime, indoor mass, envelope. Then
        // equipment: AC drying penalty, cooler and vent offsets, cooler, vent,
        // AC duty, heating.
        let temperature = [0.05, 0, 0, 0,
                           0, 0, 0, 0.6, 0.2, -1.0, 0]
        // Passive dew point: exchange, slow buffer, constant, wind, gust. Then
        // the same seven equipment slots.
        let dewPoint = [0.05, 0, 0, 0, 0,
                        0, 0, 0, 1.0, 0.2, 0, 0]
        return IndoorModel(plan: OutdoorSourcePlan(all: .weatherKit),
                           coil: CoilTemperature(baseC: 8, perOutdoorDegree: 0.15),
                           cooler: CoolerEffectiveness(fraction: 0.83),
                           exposure: .none,
                           thermostat: ACThermostat(capacityCPerHour: 1),
                           temperature: temperature, dewPoint: dewPoint,
                           score: IndoorModel.Score(temperatureRMSE: 0, dewPointRMSE: 0,
                                                    combined: 0, criterion: 0),
                           fittedAt: start, observationCount: 100)
    }

    private static func beginning(temperatureC: Double = 28, dewPointC: Double = 10) -> IndoorForecast.Start {
        IndoorForecast.Start(date: start, temperatureC: temperatureC, dewPointC: dewPointC,
                             lags: ThermalLags(indoorMassC: temperatureC, envelopeC: temperatureC,
                                               slowDewPointC: dewPointC),
                             pressureHPa: 890)
    }

    // MARK: - Scenarios

    @Test func aScenarioWithNoChangesRunsNothing() {
        let scenario = IndoorForecast.Scenario(id: 0, name: "nothing running")
        #expect(scenario.state(at: Self.start).state == .off)
        #expect(scenario.state(at: Self.start.addingTimeInterval(10 * 3600)).state == .off)
    }

    @Test func equipmentStartsWhenItsPointerSays() {
        let scenario = IndoorForecast.Scenario(
            id: 1, name: "cooler",
            first: IndoorForecast.Change(date: Self.start.addingTimeInterval(2 * 3600),
                                         state: .evaporativeCooler, setpointC: nil),
            second: IndoorForecast.Change(date: Self.start.addingTimeInterval(6 * 3600),
                                          state: .off, setpointC: nil))
        #expect(scenario.state(at: Self.start).state == .off)
        #expect(scenario.state(at: Self.start.addingTimeInterval(3 * 3600)).state == .evaporativeCooler)
        #expect(scenario.state(at: Self.start.addingTimeInterval(7 * 3600)).state == .off)
    }

    @Test func changesAreReadInTimeOrderHoweverTheyWereEntered() {
        // Dragging the second pointer left of the first must not reverse the
        // order the scenario is read in.
        let scenario = IndoorForecast.Scenario(
            id: 1, name: "cooler",
            first: IndoorForecast.Change(date: Self.start.addingTimeInterval(6 * 3600),
                                         state: .evaporativeCooler, setpointC: nil),
            second: IndoorForecast.Change(date: Self.start.addingTimeInterval(2 * 3600),
                                          state: .airConditioning, setpointC: 24))
        #expect(scenario.changes.first?.state == .airConditioning)
        #expect(scenario.state(at: Self.start.addingTimeInterval(7 * 3600)).state == .evaporativeCooler)
    }

    // MARK: - Running forward

    @Test func theForecastRunsTheWholeHorizon() {
        guard let points = IndoorForecast.run(model: Self.model(), from: Self.beginning(),
                                              scenario: IndoorForecast.Scenario(id: 0, name: "none"),
                                              weather: Self.weather(), location: nil)
        else { #expect(Bool(false)); return }
        let span = points.last!.date.timeIntervalSince(points.first!.date)
        #expect(abs(span - IndoorForecast.horizon) < IndoorForecast.step)
        #expect(points.count > 40)
        // Physically possible at every step.
        #expect(points.allSatisfy { $0.dewPointC <= $0.temperatureC + 1e-9 })
        #expect(points.allSatisfy { $0.wetBulbC <= $0.temperatureC + 1e-6 })
        #expect(points.allSatisfy { $0.wetBulbC >= $0.dewPointC - 1e-6 })
    }

    @Test func runningTheCoolerEndsCoolerAndDamperThanDoingNothing() {
        let model = Self.model(), begin = Self.beginning(), forecast = Self.weather()
        let nothing = IndoorForecast.run(model: model, from: begin,
                                         scenario: IndoorForecast.Scenario(id: 0, name: "none"),
                                         weather: forecast, location: nil)
        let cooling = IndoorForecast.run(
            model: model, from: begin,
            scenario: IndoorForecast.Scenario(id: 1, name: "cooler",
                                              first: IndoorForecast.Change(date: begin.date,
                                                                           state: .evaporativeCooler,
                                                                           setpointC: nil)),
            weather: forecast, location: nil)
        guard let idle = nothing?.last, let cooled = cooling?.last else { #expect(Bool(false)); return }
        #expect(cooled.temperatureC < idle.temperatureC)
        #expect(cooled.dewPointC > idle.dewPointC)          // a swamp cooler adds moisture
    }

    @Test func theAirConditionerStopsAtItsSetpointRatherThanRunningAway() {
        let setpoint = 24.0
        guard let points = IndoorForecast.run(
            model: Self.model(), from: Self.beginning(temperatureC: 28),
            scenario: IndoorForecast.Scenario(id: 2, name: "ac",
                                              first: IndoorForecast.Change(date: Self.start,
                                                                           state: .airConditioning,
                                                                           setpointC: setpoint)),
            weather: Self.weather(), location: nil)
        else { #expect(Bool(false)); return }
        let coldest = points.map(\.temperatureC).min() ?? 0
        #expect(points.last!.temperatureC < 26)             // it did pull the room down
        #expect(coldest > setpoint - 1)                     // and then held, rather than freezing it
    }

    @Test func startingLaterLeavesTheHouseWarmerAtFirst() {
        let model = Self.model(), begin = Self.beginning(), forecast = Self.weather()
        func lastTemperature(startingAfter hours: Double) -> Double? {
            IndoorForecast.run(
                model: model, from: begin,
                scenario: IndoorForecast.Scenario(id: 1, name: "cooler",
                                                  first: IndoorForecast.Change(
                                                    date: begin.date.addingTimeInterval(hours * 3600),
                                                    state: .evaporativeCooler, setpointC: nil)),
                weather: forecast, location: nil)?.last?.temperatureC
        }
        guard let early = lastTemperature(startingAfter: 0), let late = lastTemperature(startingAfter: 6)
        else { #expect(Bool(false)); return }
        #expect(early < late)
    }

    // MARK: - Psychrometry

    @Test func humidityAndDewPointAgreeWithEachOther() {
        for temperature in [18.0, 24.0, 33.0] {
            for dewPoint in [2.0, 10.0, 17.0] where dewPoint < temperature {
                let humidity = IndoorForecast.relativeHumidity(temperatureC: temperature, dewPointC: dewPoint)
                let back = IndoorPsychrometrics.dewPointC(temperatureC: temperature,
                                                          relativeHumidity: humidity) ?? .nan
                #expect(abs(back - dewPoint) < 0.05)
            }
        }
    }

    @Test func theWetBulbSitsBetweenDewPointAndDryBulb() {
        let wet = IndoorForecast.wetBulb(30, 12, 890)
        #expect(wet > 12 && wet < 30)
    }

    // MARK: - Gridlines

    @Test @MainActor func aTypicalDayIsLabelledEveryTenFahrenheitOrFiveCelsius() {
        #expect(IndoorForecastView.labelStep(for: 35...93) == 10)
        #expect(IndoorForecastView.labelStep(for: 2...34) == 5)
        // A flat night still gets several labels, not one.
        #expect(IndoorForecastView.labelStep(for: 70...78) == 2)
    }

    @Test @MainActor func halfwayLinesFallBetweenTheLabelledOnes() {
        let domain = 35.0...93.0
        let step = IndoorForecastView.labelStep(for: domain)
        let labelled = IndoorForecastView.multiples(of: step, in: domain)
        let halfway = IndoorForecastView.multiples(of: step / 2, in: domain)
            .filter { abs(($0 / step).rounded() * step - $0) > 1e-9 }
        #expect(labelled == [40, 50, 60, 70, 80, 90])
        #expect(halfway == [35, 45, 55, 65, 75, 85])
    }
}

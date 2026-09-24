//
//  ForecastSelectionTests.swift
//  weather_wetbulbTests
//
//  Choosing a structure by how well it forecasts, and remembering the choice.
//
//  Both are easy to get subtly wrong in ways that still produce numbers: a
//  window that runs across a gap scores a forecast against readings whose
//  history it never saw, and a structure that fails to survive a save turns
//  every opening back into a full search.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct ForecastSelectionTests {

    /// Eight in the morning, local time — where a window begins, so a test can
    /// say what the cuts should be without depending on the epoch.
    private static let morning: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(bySettingHour: 8, minute: 0, second: 0,
                             of: Date(timeIntervalSince1970: 1_700_000_000))!
    }()

    /// Consecutive observations, each starting where the last one ended.
    private static func run(count: Int, from start: Date, stepSeconds: Double = 1200,
                            hvac: HVACState = .off) -> [IndoorObservation] {
        let values = OutdoorValues(temperatureC: 30, humidity: 20, windSpeedMS: 2, windGustMS: 3,
                                   windDirectionDeg: 180, rainfallMM: 0, stationPressureHPa: 890)
        return (0..<count).map { i in
            IndoorObservation(
                date: start.addingTimeInterval(Double(i) * stepSeconds), dt: stepSeconds,
                indoorTempC: 24, indoorDewPointC: 10, nextIndoorTempC: 24, nextIndoorDewPointC: 10,
                weatherKit: values, station: values, solar: 0, hvac: hvac)
        }
    }

    // MARK: - Windows

    @Test func aGapEndsTheWindowRatherThanBeingForecastAcross() {
        let start = Self.morning
        // Two hours of readings, a three-hour hole, then two more hours.
        let before = Self.run(count: 6, from: start)
        let after = Self.run(count: 12, from: start.addingTimeInterval(6 * 1200 + 3 * 3600))
        let windows = IndoorModelEstimator.forecastWindows(before + after)
        // The first run is only two hours, under the three-hour minimum, so
        // just the second survives — and no window spans the hole.
        #expect(windows.count == 1)
        #expect(windows[0].count == 12)
    }

    @Test func unknownEquipmentEndsTheWindowToo() {
        let start = Self.morning
        var rows = Self.run(count: 12, from: start)
        rows += Self.run(count: 1, from: start.addingTimeInterval(12 * 1200), hvac: .unknown)
        rows += Self.run(count: 12, from: start.addingTimeInterval(13 * 1200))
        let windows = IndoorModelEstimator.forecastWindows(rows)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { window in window.allSatisfy { $0.hvac != .unknown } })
    }

    @Test func aLongStretchIsCutIntoHalfDays() {
        // Three days without a break, from 08:00: forecasts restart at each
        // 08:00 and 20:00 rather than running for three days, which is not what
        // the app is ever asked for. Six windows, not three days.
        let windows = IndoorModelEstimator.forecastWindows(Self.run(count: 3 * 72, from: Self.morning))
        #expect(windows.count == 6)
        for window in windows {
            let span = window.last!.date.timeIntervalSince(window.first!.date)
            #expect(span <= IndoorModelEstimator.forecastWindowHours * 3600)
        }
    }

    @Test func aWindowBreaksAtEightAndAtTwenty() {
        // Whatever time the readings start, the cuts land on the half-day
        // boundaries, so one window is a day and the next is a night.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let from = calendar.date(byAdding: .hour, value: 3, to: Self.morning)!   // 11:00
        // Twenty-four hours from 11:00 crosses 20:00 and then 08:00.
        let windows = IndoorModelEstimator.forecastWindows(Self.run(count: 72, from: from))
        #expect(windows.count == 3)
        #expect(windows.map { calendar.component(.hour, from: $0[0].date) } == [11, 20, 8])
        #expect(windows.allSatisfy { calendar.component(.minute, from: $0[0].date) == 0 })
    }

    // MARK: - Forecasting

    @Test func aForecastCarriesItsOwnStateNotTheHouses() {
        // Feed the model a house it fits exactly; running it forward from the
        // first reading must reproduce the rest, which only works if the lags
        // follow the forecast.
        let house = IndoorModelTests.SyntheticHouse()
        let all = house.observations(count: 300)
        let (train, test) = IndoorModelEstimator.split(all)
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit)),
              let window = IndoorModelEstimator.forecastWindows(test).first,
              let errors = model.forecastErrors(over: window)
        else { #expect(Bool(false)); return }
        let worst = errors.temperature.map(abs).max() ?? .infinity
        #expect(worst < 0.5)                    // a whole window, not one step
        #expect(errors.temperature.count == window.count)
    }

    @Test func aBrokenMassCoefficientForecastsWorse() {
        let house = IndoorModelTests.SyntheticHouse()
        let all = house.observations(count: 300)
        let (train, test) = IndoorModelEstimator.split(all)
        guard var model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit)),
              let window = IndoorModelEstimator.forecastWindows(test).first,
              let fitted = model.forecastErrors(over: window)
        else { #expect(Bool(false)); return }
        model.temperature[2] = 0                // the slow mass, removed
        guard let crippled = model.forecastErrors(over: window) else { #expect(Bool(false)); return }
        func mean(_ e: [Double]) -> Double { e.map(abs).reduce(0, +) / Double(e.count) }
        #expect(mean(crippled.temperature) > mean(fitted.temperature))
    }

    // MARK: - Remembering the structure

    @Test func aStructureSurvivesBeingSaved() {
        let defaults = UserDefaults(suiteName: "structure-test-\(UUID().uuidString)")!
        let house = IndoorModelTests.SyntheticHouse()
        let (train, test) = IndoorModelEstimator.split(house.observations(count: 200))
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .station),
                                          coil: CoilTemperature(baseC: 11, perOutdoorDegree: 0.15),
                                          cooler: CoolerEffectiveness(fraction: 0.82),
                                          exposure: .harmonic)
        else { #expect(Bool(false)); return }

        let structure = IndoorModelEstimator.ModelStructure(model: model, observations: 200)
        IndoorModelEstimator.save(structure, defaults: defaults)
        guard let loaded = IndoorModelEstimator.savedStructure(defaults: defaults)
        else { #expect(Bool(false)); return }
        #expect(loaded == structure)

        // And refitting the remembered structure reproduces the same model,
        // which is what makes the quick path on opening trustworthy.
        guard let again = IndoorModelEstimator.fit(structure: loaded, train: train, test: test,
                                                   now: model.fittedAt)
        else { #expect(Bool(false)); return }
        #expect(again.plan == model.plan)
        #expect(again.exposure == model.exposure)
        #expect(again.coil == model.coil)
        #expect(again.temperature == model.temperature)
    }
}

//
//  weather_wetbulbTests.swift
//  weather_wetbulbTests
//
//  Created by Rob Boer on 3/23/26.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct weather_wetbulbTests {

    @Test func stationPressureFallsWithAltitude() {
        let seaLevelPa = 101_325.0

        // At sea level the correction must be a no-op.
        let atSeaLevel = WeatherMapping.stationPressure(
            seaLevelPa: seaLevelPa, altitudeM: 0, tempC: 20)
        #expect(atSeaLevel == seaLevelPa)

        // At 1600 m (e.g. Denver) station pressure must be BELOW sea-level
        // pressure — the standard atmosphere gives roughly 83–84 kPa there.
        let at1600m = WeatherMapping.stationPressure(
            seaLevelPa: seaLevelPa, altitudeM: 1600, tempC: 20)
        #expect(at1600m < seaLevelPa)
        #expect(at1600m > 80_000 && at1600m < 90_000)

        // Higher altitude means lower pressure, monotonically.
        let at3000m = WeatherMapping.stationPressure(
            seaLevelPa: seaLevelPa, altitudeM: 3000, tempC: 20)
        #expect(at3000m < at1600m)
    }

    // MARK: - Chart-style seeding

    /// A scratch UserDefaults suite that starts empty and is wiped after use.
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func brandNewInstallDefaultsToFilled() {
        let name = "test.filled.\(UUID().uuidString)"
        let d = scratchDefaults(name)
        defer { d.removePersistentDomain(forName: name) }

        SettingsSeeding.seedChartStyleIfNeeded(d)
        #expect(d.string(forKey: SettingsKey.chartStyle) == ChartStyle.filled.rawValue)
    }

    @Test func existingUserWithUnitsKeepsClassic() {
        let name = "test.units.\(UUID().uuidString)"
        let d = scratchDefaults(name)
        defer { d.removePersistentDomain(forName: name) }

        // Simulate an existing install that has already written useFahrenheit.
        d.set(true, forKey: SettingsKey.useFahrenheit)
        SettingsSeeding.seedChartStyleIfNeeded(d)
        #expect(d.string(forKey: SettingsKey.chartStyle) == ChartStyle.classic.rawValue)
    }

    @Test func existingUserWithSavedPlacesKeepsClassic() {
        let name = "test.places.\(UUID().uuidString)"
        let d = scratchDefaults(name)
        defer { d.removePersistentDomain(forName: name) }

        d.set(Data([0x01]), forKey: "SavedPlaces_v1")
        SettingsSeeding.seedChartStyleIfNeeded(d)
        #expect(d.string(forKey: SettingsKey.chartStyle) == ChartStyle.classic.rawValue)
    }

    @Test func seedingNeverOverwritesAnExistingChoice() {
        let name = "test.nooverwrite.\(UUID().uuidString)"
        let d = scratchDefaults(name)
        defer { d.removePersistentDomain(forName: name) }

        // User already chose classic on a filled-default install.
        d.set(ChartStyle.classic.rawValue, forKey: SettingsKey.chartStyle)
        SettingsSeeding.seedChartStyleIfNeeded(d)
        #expect(d.string(forKey: SettingsKey.chartStyle) == ChartStyle.classic.rawValue)
    }

}

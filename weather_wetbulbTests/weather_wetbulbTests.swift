//
//  weather_wetbulbTests.swift
//  weather_wetbulbTests
//
//  Created by Rob Boer on 3/23/26.
//

import Testing
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

}

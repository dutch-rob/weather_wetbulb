//
//  IndoorObservationBuilderTests.swift
//  weather_wetbulbTests
//
//  The gap rules are the point of these tests. Rows that straddle an outage or
//  an HVAC transition look ordinary but carry a meaningless rate, and letting a
//  few through visibly drags the fit.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct IndoorObservationBuilderTests {

    // MARK: - Fixtures

    static let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    /// A station row with a usable indoor pair.
    static func reading(minutesFromStart m: Double,
                        indoorC: Double = 22,
                        indoorRH: Double = 40,
                        outdoorC: Double? = 18,
                        outdoorRH: Double? = 50,
                        lightKLux: Double? = nil) -> IndoorReading {
        let r = IndoorReading(date: t0.addingTimeInterval(m * 60),
                              sourceID: IndoorFeedSource.vevorStation.rawValue)
        r.indoorTempC = indoorC
        r.indoorHumidity = indoorRH
        r.outdoorTempC = outdoorC
        r.outdoorHumidity = outdoorRH
        r.windSpeedMS = 2
        r.lightKLux = lightKLux
        return r
    }

    static func forecast(minutesFromStart m: Double,
                         tempC: Double,
                         humidity: Double = 0.5,
                         cloud: Double = 0.2,
                         daylight: Bool = true,
                         windKPH: Double = 7.2,
                         gustKPH: Double = 14.4,
                         precipMM: Double = 0,
                         pressurePa: Double = 89_000) -> ForecastPoint {
        ForecastPoint(kind: .historic,
                      date: t0.addingTimeInterval(m * 60),
                      symbolName: "sun.max",
                      isDaylight: daylight,
                      uvIndex: 3,
                      temperatureF: tempC * 9 / 5 + 32,
                      temperatureC: tempC,
                      apparentTemperatureF: tempC * 9 / 5 + 32,
                      apparentTemperatureC: tempC,
                      wetBulbF: 50, wetBulbC: 10,
                      dewPointF: 45, dewPointC: 7,
                      precipProbability: 0,
                      precipitationMM: precipMM,
                      windSpeedMPH: windKPH / 1.609,
                      windSpeedKPH: windKPH,
                      windGustMPH: gustKPH / 1.609,
                      windGustKPH: gustKPH,
                      cloudCover: cloud,
                      cloudCoverLow: cloud, cloudCoverMedium: 0, cloudCoverHigh: 0,
                      humidity: humidity,
                      stationPressurePa: pressurePa)
    }

    // MARK: - Gap handling

    @Test func pairsAcrossAnOutageAreDropped() {
        // Three readings: 0, 18 and 138 minutes. The first pair is normal; the
        // second spans a two-hour outage like the one when the Mac mini moved.
        let readings = [Self.reading(minutesFromStart: 0),
                        Self.reading(minutesFromStart: 18, indoorC: 22.4),
                        Self.reading(minutesFromStart: 138, indoorC: 26)]
        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18),
                       Self.forecast(minutesFromStart: 180, tempC: 24)]

        let built = IndoorObservationBuilder.build(readings: readings, weather: weather)
        #expect(built.count == 1)
        // The surviving row must be the short one.
        #expect(built.first!.dt == 18 * 60)
    }

    @Test func pairsTooCloseTogetherAreDropped() {
        // Two minutes apart: almost no real change, but full quantisation noise,
        // which the small divisor would amplify into a huge implied rate.
        let readings = [Self.reading(minutesFromStart: 0),
                        Self.reading(minutesFromStart: 2, indoorC: 22.1)]
        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18)]
        #expect(IndoorObservationBuilder.build(readings: readings, weather: weather).isEmpty)
    }

    @Test func readingsWithoutAnIndoorPairAreIgnored() {
        let good = Self.reading(minutesFromStart: 0)
        let missing = Self.reading(minutesFromStart: 18)
        missing.indoorHumidity = nil            // no dew point derivable
        let later = Self.reading(minutesFromStart: 36, indoorC: 22.5)

        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18)]
        let built = IndoorObservationBuilder.build(readings: [good, missing, later],
                                                   weather: weather)
        // good→later is 36 minutes apart, still inside the cap, so exactly one
        // row survives once the unusable middle reading is discarded.
        #expect(built.count == 1)
        #expect(built.first!.dt == 36 * 60)
    }

    @Test func readingsAreSortedBeforePairing() {
        let readings = [Self.reading(minutesFromStart: 18, indoorC: 22.4),
                        Self.reading(minutesFromStart: 0)]
        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18)]
        let built = IndoorObservationBuilder.build(readings: readings, weather: weather)
        #expect(built.count == 1)
        #expect(built.first!.dt == 18 * 60)
    }

    // MARK: - HVAC labelling

    @Test func intervalsContainingATransitionAreDropped() {
        let readings = [Self.reading(minutesFromStart: 0),
                        Self.reading(minutesFromStart: 18, indoorC: 21),
                        Self.reading(minutesFromStart: 36, indoorC: 20)]
        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18)]
        // AC switched on 9 minutes in: inside the first interval, before the
        // second. Half of that first interval had cooling and half did not.
        let events = [HVACEvent(date: Self.t0.addingTimeInterval(9 * 60), mode: 2)]

        let built = IndoorObservationBuilder.build(readings: readings, weather: weather,
                                                   hvacEvents: events)
        #expect(built.count == 1)
        #expect(built.first!.date == Self.t0.addingTimeInterval(18 * 60))
        #expect(built.first!.hvac == .airConditioning)
    }

    @Test func stateCarriesForwardFromTheLatestEvent() {
        let timeline = HVACTimeline(
            coolerEvents: [CoolerEvent(date: Self.t0, isOn: true)],
            hvacEvents: [HVACEvent(date: Self.t0.addingTimeInterval(3600), mode: 2)])

        // Before anything is logged, off.
        #expect(timeline.state(at: Self.t0.addingTimeInterval(-60)) == .off)
        // After the cooler event, cooler.
        #expect(timeline.state(at: Self.t0.addingTimeInterval(600)) == .evaporativeCooler)
        // After the AC event, AC — a later event of either kind supersedes.
        #expect(timeline.state(at: Self.t0.addingTimeInterval(7200)) == .airConditioning)
    }

    @Test func unlabelledHistoryIsTreatedAsOff() {
        let readings = [Self.reading(minutesFromStart: 0),
                        Self.reading(minutesFromStart: 18, indoorC: 22.4)]
        let weather = [Self.forecast(minutesFromStart: 0, tempC: 18)]
        let built = IndoorObservationBuilder.build(readings: readings, weather: weather)
        #expect(built.first?.hvac == .off)
    }

    // MARK: - WeatherKit alignment

    @Test func weatherKitValuesAreInterpolatedBetweenHours() {
        let series = [Self.forecast(minutesFromStart: 0, tempC: 10),
                      Self.forecast(minutesFromStart: 60, tempC: 20)]
        let mid = Self.t0.addingTimeInterval(30 * 60)
        let (values, _) = IndoorObservationBuilder.weatherKitValues(at: mid, in: series)
        #expect(values.temperatureC != nil)
        #expect(abs(values.temperatureC! - 15) < 0.001)
    }

    @Test func weatherKitUnitsMatchTheStations() {
        let series = [Self.forecast(minutesFromStart: 0, tempC: 10,
                                    humidity: 0.42, windKPH: 36, gustKPH: 72,
                                    pressurePa: 89_000)]
        let (v, _) = IndoorObservationBuilder.weatherKitValues(at: Self.t0, in: series)
        // Humidity as percent, to match the station rather than 0…1.
        #expect(abs(v.humidity! - 42) < 0.001)
        // 36 kph is 10 m/s; 72 kph is 20 m/s.
        #expect(abs(v.windSpeedMS! - 10) < 0.001)
        #expect(abs(v.windGustMS! - 20) < 0.001)
        // Pascals to hectopascals.
        #expect(abs(v.stationPressureHPa! - 890) < 0.001)
        // WeatherKit has no wind direction at all.
        #expect(v.windDirectionDeg == nil)
    }

    @Test func timesOutsideTheSeriesClampToTheNearestPoint() {
        let series = [Self.forecast(minutesFromStart: 60, tempC: 10),
                      Self.forecast(minutesFromStart: 120, tempC: 20)]
        let before = IndoorObservationBuilder.weatherKitValues(
            at: Self.t0, in: series).values
        let after = IndoorObservationBuilder.weatherKitValues(
            at: Self.t0.addingTimeInterval(300 * 60), in: series).values
        #expect(abs(before.temperatureC! - 10) < 0.001)
        #expect(abs(after.temperatureC! - 20) < 0.001)
    }

    @Test func emptyWeatherSeriesStillProducesRows() {
        // The station data is what carries the indoor target; missing WeatherKit
        // must not throw the row away, since the station can supply outdoor too.
        let readings = [Self.reading(minutesFromStart: 0),
                        Self.reading(minutesFromStart: 18, indoorC: 22.4)]
        let built = IndoorObservationBuilder.build(readings: readings, weather: [])
        #expect(built.count == 1)
        #expect(built.first!.weatherKit.temperatureC == nil)
        #expect(built.first!.station.temperatureC != nil)
    }

    // MARK: - Solar

    @Test func solarPrefersTheStationLightSensor() {
        let r = Self.reading(minutesFromStart: 0, lightKLux: 50)
        // Overcast per WeatherKit, but the sensor on this roof says half sun.
        let p = Self.forecast(minutesFromStart: 0, tempC: 18, cloud: 1.0)
        #expect(abs(IndoorObservationBuilder.solar(station: r, weatherKit: p) - 0.5) < 0.001)
    }

    @Test func solarFallsBackToCloudCoverAndIsZeroAtNight() {
        let r = Self.reading(minutesFromStart: 0)          // no light sensor value
        let day = Self.forecast(minutesFromStart: 0, tempC: 18, cloud: 0.25, daylight: true)
        #expect(abs(IndoorObservationBuilder.solar(station: r, weatherKit: day) - 0.75) < 0.001)

        let night = Self.forecast(minutesFromStart: 0, tempC: 18, cloud: 0, daylight: false)
        #expect(IndoorObservationBuilder.solar(station: r, weatherKit: night) == 0)
    }

    @Test func solarIsClampedToTheUnitRange() {
        // Brighter than the assumed full sun must not exceed 1, or it would act
        // as an outsized gain term on a single freak reading.
        let bright = Self.reading(minutesFromStart: 0, lightKLux: 250)
        #expect(IndoorObservationBuilder.solar(station: bright, weatherKit: nil) == 1)
    }
}

//
//  WeatherMapping.swift
//  weather_wetbulb
//
//  Pure mapping from WeatherKit's HourWeather / CurrentWeather to our
//  ForecastPoint value type (station-pressure correction + wet-bulb derived
//  via PsychrometryCalculator). No UI / ObservableObject dependency, so both
//  the iOS WeatherService and the watch app's fetcher reuse it.
//

import Foundation
import CoreLocation
import WeatherKit

enum WeatherMapping {

    /// Corrects sea-level pressure to station pressure at the given altitude
    /// (barometric formula; pressure falls as altitude increases).
    static func stationPressure(seaLevelPa: Double, altitudeM: Double, tempC: Double) -> Double {
        seaLevelPa * pow(
            1 - 0.0065 * altitudeM / (tempC + 0.0065 * altitudeM + 273.15), 5.257)
    }

    /// Station pressure (Pa) and wet-bulb temperatures (°F/°C) derived from
    /// sea-level pressure, dry-bulb temperature and humidity at this location's
    /// altitude. Shared by the hourly and current-conditions mappers.
    static func derived(
        seaLevelPa: Double, tempF: Double, tempC: Double, rh: Double,
        location: CLLocation
    ) -> (stationPa: Double, wetF: Double, wetC: Double) {
        let stationPa = stationPressure(seaLevelPa: seaLevelPa,
                                        altitudeM: location.altitude,
                                        tempC: tempC)
        let wetF = PsychrometryCalculator.psychF(pressurePa: stationPa,
                                                 dryBulbFahrenheit: tempF,
                                                 relativeHumidity: rh)
        let wetC = PsychrometryCalculator.psychC(pressurePa: stationPa,
                                                 dryBulbCelsius: tempC,
                                                 relativeHumidity: rh)
        return (stationPa, wetF, wetC)
    }

    static func mapPoints(
        from hours: [HourWeather],
        start: Date, end: Date,
        location: CLLocation,
        kind: ForecastPoint.Kind = .forecast
    ) -> [ForecastPoint] {
        hours.filter { $0.date >= start && $0.date <= end }.map { h in
            let tempF      = h.temperature.converted(to: .fahrenheit).value
            let tempC      = h.temperature.converted(to: .celsius).value
            let apparentF  = h.apparentTemperature.converted(to: .fahrenheit).value
            let apparentC  = h.apparentTemperature.converted(to: .celsius).value
            let dewF       = h.dewPoint.converted(to: .fahrenheit).value
            let dewC       = h.dewPoint.converted(to: .celsius).value
            let rh         = h.humidity
            let seaLevelPa = h.pressure.converted(to: .newtonsPerMetersSquared).value
            let d          = derived(seaLevelPa: seaLevelPa, tempF: tempF, tempC: tempC,
                                     rh: rh, location: location)
            let windMPH    = h.wind.speed.converted(to: .milesPerHour).value
            let windKPH    = h.wind.speed.converted(to: .kilometersPerHour).value
            // WeatherKit gust is optional — fall back to sustained wind when absent.
            let gustMPH    = h.wind.gust?.converted(to: .milesPerHour).value ?? windMPH
            let gustKPH    = h.wind.gust?.converted(to: .kilometersPerHour).value ?? windKPH
            let precipMM   = h.precipitationAmount.converted(to: .millimeters).value

            // cloudCoverByAltitude: available in WeatherKit on iOS 18+.
            // Each property is in the 0-1 range. If this line does not compile,
            // replace the three lines below with 0.0 and file a radar.
            let cloudByAlt  = h.cloudCoverByAltitude
            let cloudLow    = cloudByAlt.low
            let cloudMid    = cloudByAlt.medium
            let cloudHigh   = cloudByAlt.high

            return ForecastPoint(
                kind:                 kind,
                date:                 h.date,
                symbolName:           h.symbolName,
                isDaylight:           h.isDaylight,
                uvIndex:              Double(h.uvIndex.value),
                temperatureF:         tempF,
                temperatureC:         tempC,
                apparentTemperatureF: apparentF,
                apparentTemperatureC: apparentC,
                wetBulbF:             d.wetF,
                wetBulbC:             d.wetC,
                dewPointF:            dewF,
                dewPointC:            dewC,
                precipProbability:    Double(h.precipitationChance),
                precipitationMM:      precipMM,
                windSpeedMPH:         windMPH,
                windSpeedKPH:         windKPH,
                windGustMPH:          gustMPH,
                windGustKPH:          gustKPH,
                cloudCover:           h.cloudCover,
                cloudCoverLow:        cloudLow,
                cloudCoverMedium:     cloudMid,
                cloudCoverHigh:       cloudHigh,
                humidity:             rh,
                stationPressurePa:    d.stationPa
            )
        }
    }

    /// Map Apple's current-conditions nowcast to a ForecastPoint(kind: .current).
    /// CurrentWeather has no precipitation or cloud-cover-by-altitude, so those
    /// fields are filled with 0.
    static func mapCurrent(_ c: CurrentWeather, location: CLLocation) -> ForecastPoint {
        let tempF      = c.temperature.converted(to: .fahrenheit).value
        let tempC      = c.temperature.converted(to: .celsius).value
        let apparentF  = c.apparentTemperature.converted(to: .fahrenheit).value
        let apparentC  = c.apparentTemperature.converted(to: .celsius).value
        let dewF       = c.dewPoint.converted(to: .fahrenheit).value
        let dewC       = c.dewPoint.converted(to: .celsius).value
        let rh         = c.humidity
        let seaLevelPa = c.pressure.converted(to: .newtonsPerMetersSquared).value
        let d          = derived(seaLevelPa: seaLevelPa, tempF: tempF, tempC: tempC,
                                 rh: rh, location: location)
        let windMPH    = c.wind.speed.converted(to: .milesPerHour).value
        let windKPH    = c.wind.speed.converted(to: .kilometersPerHour).value
        let gustMPH    = c.wind.gust?.converted(to: .milesPerHour).value ?? windMPH
        let gustKPH    = c.wind.gust?.converted(to: .kilometersPerHour).value ?? windKPH

        return ForecastPoint(
            kind:                 .current,
            date:                 c.date,
            symbolName:           c.symbolName,
            isDaylight:           c.isDaylight,
            uvIndex:              Double(c.uvIndex.value),
            temperatureF:         tempF,
            temperatureC:         tempC,
            apparentTemperatureF: apparentF,
            apparentTemperatureC: apparentC,
            wetBulbF:             d.wetF,
            wetBulbC:             d.wetC,
            dewPointF:            dewF,
            dewPointC:            dewC,
            precipProbability:    0,      // not provided by CurrentWeather
            precipitationMM:      0,      // not provided by CurrentWeather
            windSpeedMPH:         windMPH,
            windSpeedKPH:         windKPH,
            windGustMPH:          gustMPH,
            windGustKPH:          gustKPH,
            cloudCover:           c.cloudCover,
            cloudCoverLow:        0,      // not provided by CurrentWeather
            cloudCoverMedium:     0,      // not provided by CurrentWeather
            cloudCoverHigh:       0,      // not provided by CurrentWeather
            humidity:             rh,
            stationPressurePa:    d.stationPa
        )
    }
}

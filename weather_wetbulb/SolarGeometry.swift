//
//  SolarGeometry.swift
//  weather_wetbulb
//
//  How high the sun is, which is most of what determines solar gain.
//
//  Cloud cover alone is a poor proxy: it says how much of the sky is blocked
//  but nothing about how much sun there is to block. Noon in June and an hour
//  before sunset in December are both "clear", and they heat a house entirely
//  differently. In a desert, where clear skies are the norm and solar gain is
//  the dominant daytime driver, that difference is most of the signal.
//
//  The station's own light sensor would settle it, but this one reports a
//  constant zero, so the geometry has to be computed instead. It needs nothing
//  the app does not already know: a location and a clock.
//

import Foundation

enum SolarGeometry {

    /// Sine of the sun's elevation — 0 at the horizon, 1 overhead, clamped at 0
    /// once the sun is down.
    ///
    /// This is proportional to the power a horizontal surface receives from a
    /// clear sky, which is what a roof is.
    static func clearSkyFactor(date: Date, latitude: Double, longitude: Double) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 172
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let utcHours = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60

        // Declination: where the sun sits between the tropics on this date.
        let declination = 23.45 * .pi / 180
            * sin(2 * .pi * (284 + Double(day)) / 365)

        // Solar time from UTC, corrected by longitude — 15 degrees per hour.
        let solarHours = utcHours + longitude / 15
        let hourAngle = (solarHours - 12) * 15 * .pi / 180

        let latitudeRadians = latitude * .pi / 180
        let sinElevation = sin(latitudeRadians) * sin(declination)
            + cos(latitudeRadians) * cos(declination) * cos(hourAngle)
        return max(0, min(1, sinElevation))
    }
}

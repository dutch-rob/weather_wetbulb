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

    /// Where the sun is: how high, and in which direction.
    ///
    /// Elevation alone describes the flux on a HORIZONTAL surface — the roof.
    /// Walls are vertical, and what they receive depends on the angle between
    /// the sun and the wall they face, so the direction matters as much as the
    /// height. A west-exposed house takes its heaviest gain in late afternoon,
    /// at LOW elevation, exactly when an elevation-only term says the sun is
    /// fading.
    struct Position {
        /// sin(elevation): flux on a horizontal surface, 0 once the sun is down.
        var horizontal: Double
        /// cos(elevation): the magnitude available to a vertical surface facing
        /// the sun square on.
        var vertical: Double
        /// Compass bearing of the sun, degrees clockwise from north. Nil when
        /// the sun is below the horizon and the bearing means nothing.
        var azimuthDegrees: Double?
    }

    static func position(date: Date, latitude: Double, longitude: Double) -> Position {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 172
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let utcHours = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60

        let declination = 23.45 * .pi / 180 * sin(2 * .pi * (284 + Double(day)) / 365)
        let solarHours = utcHours + longitude / 15
        let hourAngle = (solarHours - 12) * 15 * .pi / 180
        let lat = latitude * .pi / 180

        let sinElevation = sin(lat) * sin(declination)
            + cos(lat) * cos(declination) * cos(hourAngle)
        let horizontal = max(0, min(1, sinElevation))
        guard horizontal > 0 else {
            return Position(horizontal: 0, vertical: 0, azimuthDegrees: nil)
        }
        let elevation = asin(max(-1, min(1, sinElevation)))

        // Azimuth measured from due south, positive toward the west, then
        // shifted to a compass bearing. The hour angle is positive after solar
        // noon, so an afternoon sun comes out west of south, as it should.
        let fromSouth = atan2(sin(hourAngle),
                              cos(hourAngle) * sin(lat) - tan(declination) * cos(lat))
        var bearing = fromSouth * 180 / .pi + 180
        if bearing < 0 { bearing += 360 }
        if bearing >= 360 { bearing -= 360 }

        return Position(horizontal: horizontal,
                        vertical: max(0, cos(elevation)),
                        azimuthDegrees: bearing)
    }

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

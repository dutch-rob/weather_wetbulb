//
//  ComplicationSnapshot.swift
//  weather_wetbulb  (shared: watch app + complication widget)
//
//  The watch app writes this to the App Group after each fetch. It holds an
//  hourly series of frames covering the next ~48 h, so the complication's
//  timeline can advance every hour from already-downloaded forecast data
//  (no new fetch needed between updates).
//

import Foundation

/// One hour's worth of complication state.
struct ComplicationFrame: Codable {
    var date: Date
    /// This hour's wet-bulb and dry-bulb temperatures (°C).
    var wetBulbC: Double
    var tempC: Double
    /// This hour's day wet-bulb range (°C), used for the gauge.
    var dayWetBulbMinC: Double
    var dayWetBulbMaxC: Double
}

struct ComplicationSnapshot: Codable {
    var updated: Date
    var useFahrenheit: Bool
    /// Hourly frames, oldest → newest (first ≈ now).
    var frames: [ComplicationFrame]

    static let appGroup = "group.robotex.weather-wetbulb"
    static let key = "complicationSnapshot"

    func save() {
        guard let store = UserDefaults(suiteName: Self.appGroup),
              let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: Self.key)
    }

    static func load() -> ComplicationSnapshot? {
        guard let store = UserDefaults(suiteName: appGroup),
              let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }
}

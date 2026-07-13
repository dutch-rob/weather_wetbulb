//
//  SettingsKeys.swift
//  weather_wetbulb
//
//  Centralized @AppStorage / UserDefaults keys and the seeding logic that
//  decides a new install's defaults.
//

import Foundation

enum SettingsKey {
    static let useFahrenheit = "useFahrenheit"
    static let chartStyle    = "chartStyle"

    // Indoor-comfort (HomeKit) feature
    static let indoorTrackingEnabled = "indoorTrackingEnabled"
    static let indoorSensorIDs        = "indoorSensorIDs_v1"   // JSON [String] of selected characteristic UUIDs
    static let homeLat                = "homeLat_v1"
    static let homeLon                = "homeLon_v1"
    static let homeAlt                = "homeAlt_v1"
}

/// Background-task identifier for periodic indoor sampling. Must match the
/// value in BGTaskSchedulerPermittedIdentifiers (Info.plist).
enum BGTask {
    static let indoorSample = "robotex.weather-wetbulb.indoorSample"
}

/// How the forecast graphs are drawn.
///   .classic — the original line charts (temp/wet-bulb/dew as lines)
///   .filled  — filled area bands with "now" markers (MyFeelsLike style)
enum ChartStyle: String, CaseIterable, Identifiable {
    case classic
    case filled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic lines"
        case .filled:  return "Filled areas"
        }
    }
}

enum SettingsSeeding {
    /// Seed the default chart style for this install, once, if not already set.
    ///
    /// New installs default to `.filled`; existing users — detected by the
    /// presence of a previously written `useFahrenheit` preference or saved
    /// places — keep the `.classic` line charts they're used to, and can opt
    /// into `.filled` in Settings.
    ///
    /// Must run *before* `useFahrenheit` is seeded on first launch, since that
    /// write is one of the existing-user markers this reads.
    static func seedChartStyleIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.chartStyle) == nil else { return }
        let isExistingUser =
            defaults.object(forKey: SettingsKey.useFahrenheit) != nil ||
            defaults.object(forKey: "SavedPlaces_v1") != nil
        let seeded: ChartStyle = isExistingUser ? .classic : .filled
        defaults.set(seeded.rawValue, forKey: SettingsKey.chartStyle)
    }
}

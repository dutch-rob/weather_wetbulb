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
    static let use12HourClock = "use12HourClock"
    static let chartStyle    = "chartStyle"
    static let graphPalette   = "graphPalette"   // GraphPalette raw value
    static let showTable      = "showTable"
    static let useFoldTimeline = "useFoldTimeline"
    static let tableBeforeFold = "tableBeforeFold"
    /// App version whose what's-new sheet has been shown ("" = never shown).
    static let lastSeenVersion = "lastSeenVersion"
    /// Build stamp of the copy whose what's-new sheet has been shown. Only
    /// consulted in development builds, where the version number rarely changes
    /// between installs.
    static let lastSeenBuild   = "lastSeenBuild"
    /// True when this install already had an earlier version of the app, so the
    /// what's-new sheet greets an upgrader rather than a first-time user.
    /// Decided once, on the first launch after updating/installing.
    static let isUpgradeUser   = "isUpgradeUser"

    // NOTE: the indoor-comfort (HomeKit) feature is not active in this release,
    // so its keys (indoor tracking, selected sensors, home location) and the
    // iCloud sync key are intentionally absent here. See the main branch.
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
    /// Whether this install has been used before this version — detected by the
    /// presence of a previously written `useFahrenheit` preference or saved
    /// places. Must be read *before* `useFahrenheit` is seeded on first launch,
    /// since that write is one of the markers.
    static func looksLikeExistingUser(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKey.useFahrenheit) != nil ||
        defaults.object(forKey: "SavedPlaces_v1") != nil
    }

    /// Seed the default chart style for this install, once, if not already set.
    ///
    /// New installs default to `.filled`; existing users keep the `.classic`
    /// line charts they're used to, and can opt into `.filled` in Settings.
    static func seedChartStyleIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.chartStyle) == nil else { return }
        let seeded: ChartStyle = looksLikeExistingUser(defaults) ? .classic : .filled
        defaults.set(seeded.rawValue, forKey: SettingsKey.chartStyle)
    }

    /// Record once whether this install is an upgrade from an earlier version,
    /// so the what's-new sheet can greet upgraders and newcomers differently.
    /// Like the chart-style seeding, this must run before `useFahrenheit` is
    /// seeded on first launch.
    static func seedUpgradeFlagIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.isUpgradeUser) == nil else { return }
        defaults.set(looksLikeExistingUser(defaults), forKey: SettingsKey.isUpgradeUser)
    }
}

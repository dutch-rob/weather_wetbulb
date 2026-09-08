//
//  weather_wetbulbApp.swift
//  weather_wetbulb
//
//  Created by Rob Boer on 3/23/26.
//

import SwiftUI
import SwiftData

@main
struct weather_wetbulbApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // These two read whether `useFahrenheit` has ever been written as one of
        // their "existing user" markers, so they must run BEFORE the seeding
        // below writes that key.
        SettingsSeeding.seedChartStyleIfNeeded()
        SettingsSeeding.seedUpgradeFlagIfNeeded()

        // On first launch only: choose °F or °C based on the device region.
        // The following countries / territories conventionally use Fahrenheit:
        let fahrenheitRegions: Set<String> = [
            "US", "PR", "GU", "VI",   // United States & territories
            "BS",                      // Bahamas
            "BZ",                      // Belize
            "KY",                      // Cayman Islands
            "PW",                      // Palau
            "FM",                      // Federated States of Micronesia
            "MH"                       // Marshall Islands
        ]
        if UserDefaults.standard.object(forKey: "useFahrenheit") == nil {
            let region = Locale.current.region?.identifier ?? ""
            UserDefaults.standard.set(fahrenheitRegions.contains(region), forKey: "useFahrenheit")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(IndoorStore.container)
        // Best-effort background ingest of the station feed. iOS grants these
        // opportunistically, but that no longer biases the data: the station
        // records on its own cadence regardless, so a missed refresh only
        // delays when rows are filed, never loses them.
        .backgroundTask(.appRefresh(BGTask.indoorSample)) {
            await IndoorSamplingCoordinator.shared.runBackgroundSample()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                IndoorSamplingCoordinator.shared.scheduleBackgroundSample()
            }
        }
    }
}

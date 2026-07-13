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
        // Seed the default chart style FIRST — it reads whether `useFahrenheit`
        // has ever been written as one of its "existing user" markers, so it
        // must run before the seeding below writes that key.
        SettingsSeeding.seedChartStyleIfNeeded()

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
        // Best-effort periodic indoor sampling in the background. iOS grants
        // these opportunistically (and HomeKit reads are only reliable in the
        // foreground), so the dataset is foreground-biased — see the sampler.
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

//
//  weather_wetbulbApp.swift
//  weather_wetbulb
//
//  Created by Rob Boer on 3/23/26.
//

import SwiftUI

@main
struct weather_wetbulbApp: App {

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
    }
}

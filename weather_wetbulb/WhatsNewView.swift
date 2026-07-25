//
//  WhatsNewView.swift
//  weather_wetbulb
//
//  Shown once per app version, the first time the app is opened after
//  installing or updating. Upgraders get a "what's new" note; first-time users
//  get a short welcome that points out the parts of the UI that aren't obvious.
//

import SwiftUI

/// The app's marketing version, e.g. "1.1".
var appVersionString: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
}

struct WhatsNewView: View {
    /// True = greet someone who had an earlier version; false = first install.
    let isUpgrade: Bool
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isUpgrade ? "What's new" : "Welcome to WetBulbCast")
                        .font(.title2.weight(.semibold))

                    if isUpgrade {
                        Text("You just got version \(appVersionString) of WetBulbCast.")
                        bullet("gearshape", "Please take a moment to check out the new Settings (the cog wheel at the bottom right), which gives you several options to make the app appear better for you — including which series to show, filled or line graphs, and muted or vivid colors.")
                        bullet("applewatch", "There is now a WetBulbCast app for Apple Watch, with a complication that shows the current wet-bulb temperature on your watch face.")
                        bullet("hand.tap", "A long press on a graph gives you a “scrubber” that shows more detail at the time in the graph where you pressed.")
                        bullet("icloud", "Your saved places sync automatically across your iOS devices signed in to the same iCloud account.")
                    } else {
                        Text("WetBulbCast works right away.")
                        bullet("gearshape", "Please take a moment to check out the Settings screen (click the cog wheel at the right bottom of the screen), which gives you several options to make the app work better for you.")
                        bullet("mappin.and.ellipse", "The “Places” button (mid bottom of the screen) lets you see the forecast for other places than where you are now, and lets you change the list of places to choose from.")
                        bullet("hand.tap", "A long press on a graph gives you a “scrubber” that shows more detail at the time in the graph where you pressed.")
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { onDismiss() }
                }
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 2)
            Text(text)
        }
        .font(.callout)
    }
}

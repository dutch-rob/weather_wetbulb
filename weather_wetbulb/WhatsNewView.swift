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
                        bullet("clock.arrow.trianglehead.counterclockwise.rotate.90",
                               "WetBulbCast now keeps the past 10 days of weather as well as the forecast, so you can look back at what it actually did. To make room for that, swiping left and right no longer changes screens: it scrolls the graph through time, from 10 days back to the end of the forecast.")
                        bullet("arrow.up.and.down",
                               "Swiping up and down now switches between the 24 hour and 10 day graphs. Every screen also has a button on each side of its title, which is the quickest way to the table and back. The graph and the table stay on the same moment in time when you switch between them.")
                        bullet("arrow.clockwise",
                               "Because a downward swipe now changes screens, pull-to-refresh is gone: use the refresh button next to the place name at the top.")
                        bullet("circle.dashed",
                               "Rings mark the current time on every graph, so “now” is easy to find however far you have scrolled. A tap on a graph now also puts the scrubber away.")
                        bullet("arrow.up.left.and.arrow.down.right",
                               "“Fold timeline” in Settings is now called “Zoom graph”, and you pinch to zoom it — anywhere between a single day and ten days.")
                        bullet("info.circle",
                               "The “i” button next to the cog wheel opens this app's info screen, which now also shows which version and build you are running.")
                    } else {
                        Text("WetBulbCast works right away.")
                        bullet("arrow.left.and.right",
                               "The app holds the past 10 days of weather as well as the forecast. Swipe a graph left or right to scroll through time, and up or down to switch between the 24 hour and 10 day graphs. Each screen also has a button on either side of its title.")
                        bullet("hand.tap",
                               "A long press on a graph gives you a “scrubber” that shows more detail at the time in the graph where you pressed. Tap the graph to put it away.")
                        bullet("mappin.and.ellipse",
                               "The “Places” button (mid bottom of the screen) lets you see the forecast for other places than where you are now, and lets you change the list of places to choose from.")
                        bullet("gearshape",
                               "Please take a moment to check out the Settings screen (the cog wheel at the right bottom), which gives you several options to make the app work better for you.")
                        bullet("info.circle",
                               "The “i” button next to the cog wheel explains the app in more detail.")
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

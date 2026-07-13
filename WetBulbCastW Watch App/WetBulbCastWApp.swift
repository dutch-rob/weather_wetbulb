//
//  WetBulbCastWApp.swift
//  WetBulbCastW Watch App
//

import SwiftUI
import WatchKit

@main
struct WetBulbCastW_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Handles periodic background refresh so the complication's forecast data
/// updates without opening the app.
final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        BackgroundWeatherRefresh.schedule()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task {
                    await BackgroundWeatherRefresh.run()
                    BackgroundWeatherRefresh.schedule()      // chain the next one
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

//
//  PhoneWatchSync.swift
//  weather_wetbulb  (iOS app only)
//
//  Pushes display settings + saved places to the watch via WatchConnectivity.
//  Uses updateApplicationContext (latest-wins, delivered even when the watch
//  app isn't running), and re-sends the last payload on activation /
//  reachability changes.
//

import Foundation
import WatchConnectivity
import OSLog

private let log = Logger(subsystem: "robotex.weather-wetbulb", category: "WatchSync")

final class PhoneWatchSync: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSync()

    private var lastPayload: WatchSyncPayload?

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Call whenever settings or saved places change.
    func update(useFahrenheit: Bool, chartStyle: String, places: [PlaceDTO]) {
        let payload = WatchSyncPayload(
            useFahrenheit: useFahrenheit, chartStyle: chartStyle, places: places)
        lastPayload = payload
        send(payload)
    }

    private func send(_ payload: WatchSyncPayload) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let context = payload.asApplicationContext()
        // Channel 1: application context (latest-wins, delivered in background).
        do {
            try session.updateApplicationContext(context)
        } catch {
            log.error("Watch sync (context) failed: \(error.localizedDescription, privacy: .public)")
        }
        // Channel 2: a queued user-info transfer as a reliability backup.
        session.transferUserInfo(context)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let p = lastPayload { send(p) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if let p = lastPayload { send(p) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for the newly-paired watch.
        WCSession.default.activate()
    }
}

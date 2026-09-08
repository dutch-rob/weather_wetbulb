//
//  IndoorSamplingCoordinator.swift
//  weather_wetbulb
//
//  Pulls the local weather station's feed out of the shared iCloud key-value
//  store and files the new rows into the local history.
//
//  This used to read HomeKit sensors and pair them with a WeatherKit snapshot.
//  It no longer does: indoor data comes only from the station, which reports on
//  its own ~18-minute cadence whether or not the phone is awake. That removes
//  the old foreground bias, where samples only existed when the app happened to
//  be open. See "Drop HomeKit" in the branch history for the removed code.
//
//  Gaps are expected and are not errors. The Mac mini that talks to the station
//  is not always on, so the series has holes — an afternoon of it, when the
//  machine moves house. Ingest simply files whatever rows arrive; deciding
//  which consecutive pairs are close enough in time to be modelled is the
//  aligner's job, not this one's.
//

import Foundation
import CoreLocation
import SwiftData
import BackgroundTasks
import OSLog

private let log = Logger(subsystem: "robotex.weather-wetbulb", category: "IndoorSampling")

@MainActor
final class IndoorSamplingCoordinator {
    static let shared = IndoorSamplingCoordinator()
    private init() {}

    private let reader = IndoorFeedReader()
    private var lastIngestAt: Date?
    /// The station publishes roughly every 18 minutes; checking much more often
    /// than that only spends battery re-reading the same payload.
    private let minInterval: TimeInterval = 10 * 60

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.indoorTrackingEnabled) }

    // MARK: Home location

    /// Remember the device's location, used to decide whether the current
    /// location is close enough to a station to show its indoor screen.
    func updateHomeLocation(_ loc: CLLocation) {
        guard enabled else { return }
        UserDefaults.standard.set(loc.coordinate.latitude, forKey: SettingsKey.indoorHomeLatitude)
        UserDefaults.standard.set(loc.coordinate.longitude, forKey: SettingsKey.indoorHomeLongitude)
        UserDefaults.standard.set(loc.altitude, forKey: SettingsKey.indoorHomeAltitude)
    }

    /// The remembered home location, if one has been recorded.
    func homeLocation() -> CLLocation? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKey.indoorHomeLatitude) != nil else { return nil }
        let lat = defaults.double(forKey: SettingsKey.indoorHomeLatitude)
        let lon = defaults.double(forKey: SettingsKey.indoorHomeLongitude)
        let alt = defaults.double(forKey: SettingsKey.indoorHomeAltitude)
        guard CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon)) else { return nil }
        return CLLocation(coordinate: .init(latitude: lat, longitude: lon),
                          altitude: alt, horizontalAccuracy: -1,
                          verticalAccuracy: alt == 0 ? -1 : 1, timestamp: Date())
    }

    // MARK: Ingest

    /// Ingest if enabled and the throttle has elapsed.
    func sampleIfDue(force: Bool = false) async {
        guard enabled else { return }
        if !force, let last = lastIngestAt, Date().timeIntervalSince(last) < minInterval { return }
        ingestNow(context: IndoorStore.container.mainContext)
    }

    /// Read every known station feed and file any rows not already stored.
    @discardableResult
    func ingestNow(context: ModelContext) -> Int {
        guard enabled else { return 0 }
        reader.synchronize()

        var total = 0
        for source in IndoorFeedSource.allCases {
            guard let feed = reader.feed(for: source) else { continue }
            do {
                let added = try IndoorFeedStore.ingest(feed, source: source, context: context)
                total += added
                if added > 0 {
                    log.info("Ingested \(added, privacy: .public) rows from \(source.rawValue, privacy: .public).")
                }
            } catch {
                log.error("Ingest failed for \(source.rawValue, privacy: .public): \(error, privacy: .public)")
            }
        }
        lastIngestAt = Date()
        return total
    }

    // MARK: Manual event logging

    /// Record a manual evaporative-cooler on/off event.
    func logCooler(on: Bool, context: ModelContext) {
        context.insert(CoolerEvent(date: Date(), isOn: on, source: 0))
        try? context.save()
    }

    /// Record a manual thermostat state (0 off, 1 heat, 2 cool), optionally with
    /// the setpoint it was set to.
    func logHVAC(mode: Int, targetTempC: Double? = nil, context: ModelContext) {
        context.insert(HVACEvent(date: Date(), mode: mode, targetTempC: targetTempC, source: 0))
        try? context.save()
    }

    // MARK: Background refresh

    func scheduleBackgroundSample() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: BGTask.indoorSample)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func runBackgroundSample() async {
        guard enabled else { return }
        ingestNow(context: IndoorStore.container.mainContext)
        scheduleBackgroundSample()
    }
}

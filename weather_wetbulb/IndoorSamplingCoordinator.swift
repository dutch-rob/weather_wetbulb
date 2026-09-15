//
//  IndoorSamplingCoordinator.swift
//  weather_wetbulb
//
//  Reads the weather station's archive from CloudKit and files the days that
//  changed into the local history.
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

    private let archive = StationCloudArchive()
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
        await ingestNow(context: IndoorStore.container.mainContext)
    }

    /// Read the days that changed in the station's archive and file them,
    /// returning how many report rounds were filed.
    @discardableResult
    func ingestNow(context: ModelContext) async -> Int {
        guard enabled else { return 0 }
        lastIngestAt = Date()

        let changes: StationCloudArchive.Changes
        do {
            changes = try await archive.fetchChanges()
        } catch {
            // Offline, signed out of iCloud, or the service is busy. The archive
            // keeps everything, so the next attempt catches up.
            log.error("Reading the station archive failed: \(error, privacy: .public)")
            return 0
        }
        guard !changes.days.isEmpty else { return 0 }

        let defaults = UserDefaults.standard
        let stations = StationReadingStore.stationNames(
            changes.days.map(\.station),
            remembered: defaults.string(forKey: SettingsKey.stationArchiveName))
        var filed = 0
        var unnamed = 0
        do {
            for (day, station) in zip(changes.days, stations) {
                guard let station else { unnamed += 1; continue }
                let rounds = StationDay.rounds(StationDay.samples(fromPayload: day.payload))
                filed += try StationReadingStore.applyDay(day.day, station: station,
                                                          rounds: rounds, context: context)
            }
            // Read from the start, the archive holds everything the key-value
            // feed ever carried, so the rows that came that way can go.
            if changes.fromStart && unnamed == 0 {
                let retired = try StationReadingStore.retireFeedRows(context: context)
                if retired > 0 {
                    log.info("Retired \(retired, privacy: .public) rows from the old key-value feed.")
                }
            }
            try context.save()
        } catch {
            context.rollback()
            log.error("Filing station readings failed: \(error, privacy: .public)")
            return 0
        }

        if let name = stations.compactMap({ $0 }).last {
            defaults.set(name, forKey: SettingsKey.stationArchiveName)
        }
        if unnamed == 0 {
            await archive.commit()
        } else {
            // Leave the token where it was, so those days are read again once
            // their station can be told rather than being skipped for good.
            log.error("\(unnamed, privacy: .public) day records name no station and were not filed.")
        }
        // Station names can identify a household, so they stay out of the public log.
        log.info("Filed \(filed, privacy: .public) report rounds from \(changes.days.count, privacy: .public) days.")
        return filed
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
        await ingestNow(context: IndoorStore.container.mainContext)
        scheduleBackgroundSample()
    }
}

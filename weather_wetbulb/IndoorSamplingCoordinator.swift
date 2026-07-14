//
//  IndoorSamplingCoordinator.swift
//  weather_wetbulb
//
//  Takes a paired indoor (HomeKit) + outdoor (WeatherKit) sample and stores it
//  as a ComfortSample. Runs in the foreground (on activation + a 15-min timer)
//  and best-effort in the background.
//
//  Limitation: iOS grants background app-refresh opportunistically (often only
//  a few times a day) and HomeKit reads are only reliable in the foreground, so
//  the collected series is foreground-biased. That's acceptable for Phase 2,
//  which will fit only on rows that actually carry an indoor reading.
//

import Foundation
import CoreLocation
import WeatherKit
import SwiftData
import BackgroundTasks
import OSLog

private let log = Logger(subsystem: "robotex.weather-wetbulb", category: "IndoorSampling")

@MainActor
final class IndoorSamplingCoordinator {
    static let shared = IndoorSamplingCoordinator()
    private init() {}

    private let weatherService = WeatherKit.WeatherService()
    private var lastSampleAt: Date?
    private let minInterval: TimeInterval = 15 * 60

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.indoorTrackingEnabled) }

    private var selectedSensorIDs: [String] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.indoorSensorIDs),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    // MARK: Home location (where the sensors are)

    /// Remember the device's location as the "home" location for outdoor
    /// weather pairing, while indoor tracking is on.
    func updateHomeLocation(_ loc: CLLocation) {
        let d = UserDefaults.standard
        d.set(loc.coordinate.latitude, forKey: SettingsKey.homeLat)
        d.set(loc.coordinate.longitude, forKey: SettingsKey.homeLon)
        d.set(loc.altitude, forKey: SettingsKey.homeAlt)
    }

    private func homeLocation() -> CLLocation? {
        let d = UserDefaults.standard
        guard d.object(forKey: SettingsKey.homeLat) != nil,
              d.object(forKey: SettingsKey.homeLon) != nil else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: d.double(forKey: SettingsKey.homeLat),
                                               longitude: d.double(forKey: SettingsKey.homeLon)),
            altitude: d.double(forKey: SettingsKey.homeAlt),
            horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: Date())
    }

    // MARK: Sampling

    /// Take a sample if tracking is on and at least `minInterval` has elapsed.
    func sampleIfDue(force: Bool = false) async {
        guard enabled else { return }
        if !force, let last = lastSampleAt, Date().timeIntervalSince(last) < minInterval { return }
        await sampleNow(context: IndoorStore.container.mainContext)
    }

    /// Read HomeKit + WeatherKit once and persist a ComfortSample.
    func sampleNow(context: ModelContext) async {
        guard enabled else { return }
        let ids = selectedSensorIDs
        let indoor = ids.isEmpty
            ? IndoorAggregate()
            : await HomeKitService.shared.readSelectedSensors(ids: ids)

        // Skip empty samples entirely (no indoor reading and no way to pair).
        guard indoor.tempC != nil || indoor.humidity != nil else {
            log.info("Indoor sample skipped: no readings from selected sensors.")
            return
        }

        let sample = ComfortSample()
        sample.indoorTempC = indoor.tempC
        sample.indoorHumidity = indoor.humidity
        sample.indoorSensorCount = indoor.sensorCount
        sample.indoorReadingsJSON = indoor.perSensorJSON
        // Prefer a live HomeKit climate reading; otherwise use the latest
        // manually-logged thermostat state (e.g. a Nest not in HomeKit).
        sample.hvacMode = indoor.hvacMode ?? latestHVACMode(context: context)
        sample.hvacTargetTempC = indoor.hvacTargetTempC

        if let loc = homeLocation(),
           let cur = try? await outdoor(for: loc) {
            sample.outdoorTempC = cur.temperatureC
            sample.outdoorHumidity = cur.humidity
            sample.outdoorDewPointC = cur.dewPointC
            sample.outdoorWetBulbC = cur.wetBulbC
            sample.outdoorWindKPH = cur.windSpeedKPH
            sample.outdoorCloudCover = cur.cloudCover
            sample.outdoorUVIndex = cur.uvIndex
            sample.outdoorIsDaylight = cur.isDaylight
            sample.outdoorPressurePa = cur.stationPressurePa
            sample.latitude = loc.coordinate.latitude
            sample.longitude = loc.coordinate.longitude
            sample.altitude = loc.altitude
        }

        if let cooler = latestCoolerState(context: context) {
            sample.coolerOn = cooler
            sample.coolerSource = 0
        }

        context.insert(sample)
        try? context.save()
        lastSampleAt = Date()
        log.info("Stored ComfortSample (indoorT=\(indoor.tempC ?? .nan, privacy: .public)).")
    }

    private func outdoor(for loc: CLLocation) async throws -> ForecastPoint {
        let current = try await weatherService.weather(for: loc, including: .current)
        return WeatherMapping.mapCurrent(current, location: loc)
    }

    private func latestCoolerState(context: ModelContext) -> Bool? {
        var d = FetchDescriptor<CoolerEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.isOn
    }

    private func latestHVACMode(context: ModelContext) -> Int? {
        var d = FetchDescriptor<HVACEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.mode
    }

    // MARK: Manual logs

    /// Record a manual evaporative-cooler on/off event.
    func logCooler(on: Bool, context: ModelContext) {
        context.insert(CoolerEvent(isOn: on, source: 0))
        try? context.save()
    }

    /// Record a manual thermostat state (0 off, 1 heat, 2 cool).
    func logHVAC(mode: Int, context: ModelContext) {
        context.insert(HVACEvent(mode: mode, source: 0))
        try? context.save()
    }

    // MARK: Background task

    func scheduleBackgroundSample() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: BGTask.indoorSample)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { log.error("BG submit failed: \(error.localizedDescription, privacy: .public)") }
    }

    func runBackgroundSample() async {
        await sampleNow(context: IndoorStore.container.mainContext)
        scheduleBackgroundSample()   // chain the next one
    }
}

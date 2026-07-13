//
//  IndoorModels.swift
//  weather_wetbulb
//
//  SwiftData schema for the indoor-comfort / evaporative-cooler feature
//  (Phase 1: data collection). Each ComfortSample pairs an indoor HomeKit
//  reading with the concurrent outdoor WeatherKit conditions, so later phases
//  can fit a regression of indoor temperature/humidity on recent outdoor
//  weather — no schema migration needed (lag features are computed at fit time
//  from the stored series).
//
//  Stored locally only (no CloudKit backing): the series is append-only, high
//  volume (~15-min cadence), and queried by date range.
//

import Foundation
import SwiftData

/// Shared local (non-CloudKit) SwiftData store for the indoor-comfort feature.
/// Exposed so background tasks can open a context outside the view hierarchy.
enum IndoorStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: ComfortSample.self, CoolerEvent.self)
        } catch {
            fatalError("Failed to create ComfortSample ModelContainer: \(error)")
        }
    }()
}

@Model
final class ComfortSample {
    var date: Date = Date()

    // MARK: Indoor (HomeKit, aggregated over the user's selected sensors)
    var indoorTempC: Double?
    var indoorHumidity: Double?          // 0…1
    var indoorSensorCount: Int = 0
    /// Per-sensor detail (JSON of [{uuid,name,tempC?,rh?}]) for future
    /// room-level modeling. Opaque here.
    var indoorReadingsJSON: Data?
    /// Climate-control state from a selected thermostat / heater-cooler, if any.
    /// 0 = off/idle, 1 = heating, 2 = cooling, 3 = fan. nil = none selected.
    var hvacMode: Int?
    var hvacTargetTempC: Double?

    // MARK: Outdoor (WeatherKit current conditions at sample time)
    var outdoorTempC: Double?
    var outdoorHumidity: Double?         // 0…1
    var outdoorDewPointC: Double?
    var outdoorWetBulbC: Double?
    var outdoorWindKPH: Double?
    var outdoorCloudCover: Double?       // 0…1
    var outdoorUVIndex: Double?
    var outdoorIsDaylight: Bool?
    var outdoorPressurePa: Double?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?

    // MARK: Evaporative cooler
    /// Cooler state at sample time (nil = unknown). Phase 2 detection may fill
    /// this in; Phase 1 copies the latest logged CoolerEvent.
    var coolerOn: Bool?
    /// 0 = user-logged, 1 = inferred (Phase 2).
    var coolerSource: Int = 0

    var schemaVersion: Int = 1

    init(date: Date = Date()) {
        self.date = date
    }
}

@Model
final class CoolerEvent {
    var date: Date = Date()
    var isOn: Bool = false
    /// 0 = manual (user tapped the toggle), 1 = inferred (Phase 2).
    var source: Int = 0

    init(date: Date = Date(), isOn: Bool, source: Int = 0) {
        self.date = date
        self.isOn = isOn
        self.source = source
    }
}

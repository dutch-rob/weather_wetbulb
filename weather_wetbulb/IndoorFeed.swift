//
//  IndoorFeed.swift
//  weather_wetbulb
//
//  Reads the reading feed published by a local weather station app into the
//  shared iCloud key-value store, and keeps a local copy of the history.
//
//  Transport note: the publisher writes to
//  NSUbiquitousKeyValueStore, not CloudKit, relying on both apps declaring the
//  same `com.apple.developer.ubiquity-kvstore-identifier`. Nothing for this
//  feature appears in the CloudKit dashboard.
//
//  The published feed is a rolling 30-day window capped at 1 MB, so it is not a
//  durable archive. `IndoorFeedStore` copies every new row into SwiftData so the
//  model can eventually train on more history than the feed itself carries.
//

import Foundation
import CoreLocation
import SwiftData

// MARK: - Wire format

/// One station's feed, decoded from the key-value store.
///
/// Field names are the publisher's short keys; see `WetBulbCastFeed` in the
/// station app. Everything is canonical SI-ish: °C, %, m/s, hPa, mm, degrees.
struct IndoorFeed: Codable, Equatable, Sendable {

    struct Latest: Codable, Equatable, Sendable {
        var t: Int
        var indoorTemperatureC: Double?
        var indoorHumidity: Double?
        var indoorDewPointC: Double?
        var outdoorTemperatureC: Double?
        var outdoorHumidity: Double?
        var outdoorDewPointC: Double?
        var windSpeedMS: Double?
        var windGustMS: Double?
        var windDirectionDeg: Double?
        /// Absolute pressure at the station's altitude — NOT reduced to sea
        /// level. WeatherKit reports the sea-level figure, so the two are not
        /// interchangeable: see `IndoorReading.stationPressureHPa`.
        var stationPressureHPa: Double?
        var rainfallMM: Double?

        enum CodingKeys: String, CodingKey {
            case t
            case indoorTemperatureC = "it", indoorHumidity = "ih", indoorDewPointC = "id"
            case outdoorTemperatureC = "ot", outdoorHumidity = "oh", outdoorDewPointC = "od"
            case windSpeedMS = "ws", windGustMS = "wg", windDirectionDeg = "wd"
            case stationPressureHPa = "psta", rainfallMM = "r"
        }
    }

    /// One reporting round, at the station's native ~18–20 minute cadence.
    struct Reading: Codable, Equatable, Sendable {
        var t: Int
        var indoorTemperatureC: Double?
        var indoorHumidity: Double?
        var outdoorTemperatureC: Double?
        var outdoorHumidity: Double?
        var windSpeedMS: Double?
        var lightKLux: Double?
        var windGustMS: Double?
        var windDirectionDeg: Double?
        var stationPressureHPa: Double?
        var rainfallMM: Double?

        enum CodingKeys: String, CodingKey {
            case t
            case indoorTemperatureC = "it", indoorHumidity = "ih"
            case outdoorTemperatureC = "ot", outdoorHumidity = "oh"
            case windSpeedMS = "ws", lightKLux = "li"
            case windGustMS = "wg", windDirectionDeg = "wd"
            case stationPressureHPa = "psta", rainfallMM = "r"
        }

        var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
    }

    var version: Int
    var source: String
    var generated: Int
    var station: String?
    var latest: Latest?
    var readings: [Reading]

    enum CodingKeys: String, CodingKey {
        case version = "v", source = "src", generated = "g", station = "s"
        case latest = "l", readings = "r"
    }

    var generatedDate: Date { Date(timeIntervalSince1970: TimeInterval(generated)) }
}

// MARK: - Sources

/// A station feed this app knows how to read. One case per publisher; the
/// key-value key and the station's location live here so adding a second
/// station is a new case rather than new plumbing.
enum IndoorFeedSource: String, CaseIterable, Sendable {
    case vevorStation

    /// Key the publisher writes in the shared key-value store.
    var storeKey: String {
        switch self {
        case .vevorStation: return "weather_station_feed_v1"
        }
    }

    /// `source` string the publisher stamps into the payload.
    var sourceID: String {
        switch self {
        case .vevorStation: return "weather-station"
        }
    }

    /// How close a place must be to count as this station's location.
    static let matchRadius: CLLocationDistance = 2_000   // metres
}

// MARK: - Reader

/// Decodes station feeds out of the shared key-value store.
///
/// Reading is cheap and synchronous — the key-value store is a local plist that
/// iCloud syncs behind the scenes — so this has no caching of its own.
struct IndoorFeedReader: Sendable {
    var store: NSUbiquitousKeyValueStore = .default

    /// The feed for `source`, or nil when nothing has been published yet or the
    /// payload does not decode.
    func feed(for source: IndoorFeedSource) -> IndoorFeed? {
        guard let data = store.data(forKey: source.storeKey) else { return nil }
        guard let feed = try? JSONDecoder().decode(IndoorFeed.self, from: data) else { return nil }
        // Guard against a key collision writing something else here.
        guard feed.source == source.sourceID else { return nil }
        return feed
    }

    /// Ask iCloud to pull down anything newer. Cheap; safe to call on refresh.
    func synchronize() {
        store.synchronize()
    }
}

// MARK: - Stored history

/// One station reading, kept locally so history outlives the publisher's
/// 30-day rolling window.
///
/// Indoor values come only from the station. The Dyson screenshot readings that
/// seeded the earlier model are deliberately not represented here.
@Model
final class IndoorReading {
    /// Reading time, rounded to the minute by the publisher.
    var date: Date = Date()
    /// Raw value of `IndoorFeedSource`, so a second station stays separable.
    var sourceID: String = IndoorFeedSource.vevorStation.rawValue

    var indoorTempC: Double?
    var indoorHumidity: Double?          // percent, 0…100 as published

    var outdoorTempC: Double?
    var outdoorHumidity: Double?         // percent
    var windSpeedMS: Double?
    var windGustMS: Double?
    var windDirectionDeg: Double?
    var lightKLux: Double?
    var rainfallMM: Double?
    /// Absolute (station-altitude) pressure. Unlike the WeatherKit figure this
    /// needs no reduction before psychrometry.
    var stationPressureHPa: Double?

    var schemaVersion: Int = 1

    init(date: Date, sourceID: String) {
        self.date = date
        self.sourceID = sourceID
    }

    /// Fill from a decoded feed row.
    convenience init(_ r: IndoorFeed.Reading, sourceID: String) {
        self.init(date: r.date, sourceID: sourceID)
        indoorTempC = r.indoorTemperatureC
        indoorHumidity = r.indoorHumidity
        outdoorTempC = r.outdoorTemperatureC
        outdoorHumidity = r.outdoorHumidity
        windSpeedMS = r.windSpeedMS
        windGustMS = r.windGustMS
        windDirectionDeg = r.windDirectionDeg
        lightKLux = r.lightKLux
        rainfallMM = r.rainfallMM
        stationPressureHPa = r.stationPressureHPa
    }

    /// True when the row carries the indoor pair the model needs as its target.
    var hasIndoorTarget: Bool { indoorTempC != nil && indoorHumidity != nil }
}

// MARK: - Ingest

/// Copies newly published rows into the local store.
///
/// The publisher republishes its whole window each time, so ingest is
/// idempotent: rows already stored (same source and timestamp) are skipped
/// rather than duplicated.
struct IndoorFeedStore {

    /// Merge `feed` into `context`, returning how many new rows were stored.
    @discardableResult
    static func ingest(_ feed: IndoorFeed,
                       source: IndoorFeedSource,
                       context: ModelContext) throws -> Int {
        guard !feed.readings.isEmpty else { return 0 }

        let sourceID = source.rawValue
        // One fetch of the existing window, rather than a query per row.
        let oldest = feed.readings.map(\.date).min() ?? .distantPast
        var descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID && $0.date >= oldest })
        descriptor.propertiesToFetch = [\.date]
        let existing = Set((try? context.fetch(descriptor))?.map(\.date) ?? [])

        var inserted = 0
        for row in feed.readings where !existing.contains(row.date) {
            context.insert(IndoorReading(row, sourceID: sourceID))
            inserted += 1
        }
        if inserted > 0 { try context.save() }
        return inserted
    }

    /// Stored rows for a source, oldest first.
    static func history(source: IndoorFeedSource,
                        since: Date = .distantPast,
                        context: ModelContext) -> [IndoorReading] {
        let sourceID = source.rawValue
        let descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID && $0.date >= since },
            sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Timestamp of the earliest stored row, used to decide how often the model
    /// should be re-estimated while history is still short.
    static func firstReadingDate(source: IndoorFeedSource,
                                 context: ModelContext) -> Date? {
        let sourceID = source.rawValue
        var descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID },
            sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.date
    }
}

// MARK: - Place matching

extension Place {
    /// The station feed this place should use: the explicit opt-in first, and
    /// otherwise a current-location place that sits within the match radius of
    /// a known station.
    func indoorFeedSource(stationLocation: (IndoorFeedSource) -> CLLocation?) -> IndoorFeedSource? {
        for source in IndoorFeedSource.allCases {
            guard let stationLoc = stationLocation(source) else { continue }
            if clLocation.distance(from: stationLoc) <= IndoorFeedSource.matchRadius {
                return source
            }
        }
        return indoorMonitoring ? IndoorFeedSource.allCases.first : nil
    }
}

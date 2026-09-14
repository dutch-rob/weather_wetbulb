//
//  IndoorFeed.swift
//  weather_wetbulb
//
//  Reads the reading feed published by a local weather station app into the
//  shared iCloud key-value store, and keeps a local copy of the history.
//
//  Transport note: the publisher writes to NSUbiquitousKeyValueStore, not
//  CloudKit, relying on both apps declaring the same
//  `com.apple.developer.ubiquity-kvstore-identifier`. Nothing for this feature
//  appears in the CloudKit dashboard.
//
//  Nothing about any particular station is compiled in. A feed is recognised
//  by its content rather than its key, and names itself in its payload; that
//  name is what its readings are filed under. The app learns which stations
//  exist from the data, so a new station needs no change here.
//
//  The published feed is a rolling 30-day window capped at 1 MB, so it is not a
//  durable archive. `IndoorFeedStore` copies every new row into SwiftData so the
//  model can eventually train on more history than the feed itself carries.
//

import Foundation
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

/// Which station's readings belong to the monitored home.
///
/// Decided from what is stored rather than from a list of known stations: one
/// station is taken to be the home's, and more than one is refused.
enum IndoorSourceResolution: Equatable, Sendable {
    /// No station readings stored yet.
    case noStation
    /// Exactly one station, whose readings are taken to be the home's.
    case single(String)
    /// Readings from more than one station, sorted by name.
    ///
    /// TODO: Before the app is made available to other users, let the user
    /// choose which station belongs to the monitored home instead of refusing.
    /// One station is all this app has ever seen, so an error is enough for
    /// now — and far better than guessing, which would fit the model to another
    /// house's readings without any sign that it had.
    case several([String])

    init(sourceIDs: some Sequence<String>) {
        let names = Set(sourceIDs).sorted()
        switch names.count {
        case 0:  self = .noStation
        case 1:  self = .single(names[0])
        default: self = .several(names)
        }
    }
}

// MARK: - Reader

/// Decodes station feeds out of the shared key-value store.
///
/// Reading is cheap and synchronous — the key-value store is a local plist that
/// iCloud syncs behind the scenes — so this has no caching of its own.
struct IndoorFeedReader: Sendable {
    var store: NSUbiquitousKeyValueStore = .default

    /// Every station feed in the key-value store.
    func feeds() -> [IndoorFeed] {
        Self.feeds(in: store.dictionaryRepresentation)
    }

    /// Station feeds among arbitrary stored values, in key order.
    ///
    /// Recognised by content, not by key: anything that decodes as a feed and
    /// names its station is one. The key is the publisher's choice, and looking
    /// it up by name would compile that publisher's naming into this app. Other
    /// values sharing the store — synced places, settings — fail to decode and
    /// are skipped.
    static func feeds(in values: [String: Any]) -> [IndoorFeed] {
        let decoder = JSONDecoder()
        return values.keys.sorted().compactMap { key -> IndoorFeed? in
            guard let data = values[key] as? Data,
                  let feed = try? decoder.decode(IndoorFeed.self, from: data),
                  !feed.source.isEmpty
            else { return nil }
            return feed
        }
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
    /// The station's own name for itself — the feed's `src` — so readings from
    /// a second station stay separable.
    var sourceID: String = ""

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

    /// 2 for rows filed under the station's own name. Rows at 1 predate that
    /// and carry a name the app used to supply itself; see
    /// `IndoorFeedStore.adoptLegacyRows`.
    var schemaVersion: Int = 1

    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    init(date: Date, sourceID: String) {
        self.date = date
        self.sourceID = sourceID
        // Set here rather than as the property's default, so the stored schema
        // is untouched and rows already on disk keep reading as 1.
        self.schemaVersion = Self.currentSchemaVersion
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
/// idempotent: rows already stored (same station and timestamp) are skipped
/// rather than duplicated.
struct IndoorFeedStore {

    /// Merge `feed` into `context` under the name the feed gives itself,
    /// returning how many new rows were stored.
    @discardableResult
    static func ingest(_ feed: IndoorFeed, context: ModelContext) throws -> Int {
        guard !feed.readings.isEmpty else { return 0 }

        let sourceID = feed.source
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

    /// Refile rows stored before stations named themselves.
    ///
    /// Those rows carry a name the app used to supply, not the one their
    /// publisher uses, so left alone every reading would appear to come from
    /// two stations and stop the model. They can only have come from the one
    /// station the app then read, so once exactly one station is publishing
    /// they are relabelled as its readings. A legacy row whose timestamp is
    /// already stored under the new name is the same reading twice, and is
    /// dropped instead.
    ///
    /// Returns how many rows were relabelled or dropped.
    @discardableResult
    static func adoptLegacyRows(as sourceID: String, context: ModelContext) throws -> Int {
        let legacy = IndoorReading.legacySchemaVersion
        let rows = try context.fetch(FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.schemaVersion == legacy }))
        guard !rows.isEmpty else { return 0 }

        var current = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID && $0.schemaVersion != legacy })
        current.propertiesToFetch = [\.date]
        let stored = Set(try context.fetch(current).map(\.date))

        for row in rows {
            if stored.contains(row.date) {
                context.delete(row)
            } else {
                row.sourceID = sourceID
                row.schemaVersion = IndoorReading.currentSchemaVersion
            }
        }
        try context.save()
        return rows.count
    }

    /// Every station name with readings stored, sorted.
    static func sourceIDs(context: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<IndoorReading>()
        descriptor.propertiesToFetch = [\.sourceID]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.sourceID)).sorted()
    }

    /// Which station's readings belong to the monitored home.
    static func resolveSource(context: ModelContext) -> IndoorSourceResolution {
        IndoorSourceResolution(sourceIDs: sourceIDs(context: context))
    }

    /// Stored rows for a station, oldest first.
    static func history(sourceID: String,
                        since: Date = .distantPast,
                        context: ModelContext) -> [IndoorReading] {
        let descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID && $0.date >= since },
            sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Timestamp of the earliest stored row, used to decide how often the model
    /// should be re-estimated while history is still short.
    static func firstReadingDate(sourceID: String,
                                 context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID },
            sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.date
    }
}

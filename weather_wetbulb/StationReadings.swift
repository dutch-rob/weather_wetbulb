//
//  StationReadings.swift
//  weather_wetbulb
//
//  The weather station's readings: how its archived samples become the rows the
//  indoor model uses, and the local copy those rows are kept in.
//
//  The station app archives every sample it receives in CloudKit, one record
//  per UTC day (see StationCloudArchive). A record holds raw samples — a
//  data-point code, a time and a value — at the station's own cadence. The
//  console reports its data points a second apart in a burst about every 20
//  minutes, so here those bursts are gathered back into one row per report
//  round.
//
//  Nothing about any particular station is compiled in. Each day record names
//  its station, and that name is what its rows are filed under, so the app
//  learns which stations exist from the data.
//

import Foundation
import SwiftData

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

// MARK: - Day records

/// One sample as the station archives it: a data-point code, a time in whole
/// epoch seconds, and a value in canonical units (°C, %, m/s, hPa, mm, degrees).
nonisolated struct StationSample: Codable, Equatable, Sendable {
    let c: String
    let t: Int
    let v: Double
}

nonisolated enum StationDay {

    /// Code carrying the wind direction. The station decodes it far more often
    /// than it reports anything else, and re-times it onto each report round
    /// before uploading.
    static let windDirectionCode = "derived_wind_direction"

    /// Samples closer together than this belong to the same report round. A
    /// burst spans about ten seconds and rounds are about twenty minutes apart,
    /// so the threshold only needs to sit comfortably between the two.
    static let roundGap: TimeInterval = 120

    struct Round: Equatable, Sendable {
        /// Time of the round's first sample.
        var date: Date
        /// Value per code; the later one if a code appears twice in a round.
        var values: [String: Double]
    }

    /// Samples from a day record's `readings` field.
    ///
    /// The payload is zlib-deflated JSON. Decompression falls back to the bytes
    /// as they came, so an uncompressed payload still reads; anything that is
    /// not a sample array reads as no samples.
    static func samples(fromPayload data: Data) -> [StationSample] {
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        return (try? JSONDecoder().decode([StationSample].self, from: json)) ?? []
    }

    /// Gather samples into report rounds.
    ///
    /// Grouped by the gap between samples rather than by clock minute, so a
    /// burst that straddles a minute boundary is still one round. A round with
    /// nothing but a wind direction describes no conditions and is dropped.
    static func rounds(_ samples: [StationSample]) -> [Round] {
        var rounds: [Round] = []
        var previous: Int?
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            if let previous, TimeInterval(sample.t - previous) <= roundGap, !rounds.isEmpty {
                rounds[rounds.count - 1].values[sample.c] = sample.v
            } else {
                rounds.append(Round(date: Date(timeIntervalSince1970: TimeInterval(sample.t)),
                                    values: [sample.c: sample.v]))
            }
            previous = sample.t
        }
        return rounds.filter { $0.values.keys.contains { $0 != windDirectionCode } }
    }

    /// Start of the UTC day a record is named for, such as "2026-09-14".
    static func start(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Stored history

/// One report round from the station, kept locally so the model does not need
/// to reach iCloud each time it fits.
///
/// Indoor values come only from the station. The Dyson screenshot readings that
/// seeded the earlier model are deliberately not represented here.
@Model
final class IndoorReading {
    /// Time of the round's first sample.
    var date: Date = Date()
    /// The station's own name, from its day records, so readings from a second
    /// station stay separable.
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

    /// How the row arrived: 3 for rows built from the station's CloudKit
    /// archive, 1 and 2 for rows from the key-value feed it replaced. The older
    /// ones are retired once the archive has been read from the start.
    var schemaVersion: Int = 1

    static let archiveSchemaVersion = 3

    init(date: Date, sourceID: String) {
        self.date = date
        self.sourceID = sourceID
        // Set here rather than as the property's default, so the stored schema
        // is untouched and rows already on disk keep their version.
        self.schemaVersion = Self.archiveSchemaVersion
    }

    /// Set every station field from a report round. A field the round did not
    /// report becomes nil rather than keeping an older value.
    func fill(from values: [String: Double]) {
        indoorTempC = values["indoor_temperature"]
        indoorHumidity = values["indoor_humidity"]
        outdoorTempC = values["outdoor_temperature"]
        outdoorHumidity = values["outdoor_humidity"]
        windSpeedMS = values["wind_speed"]
        windGustMS = values["wind_gust"]
        windDirectionDeg = values[StationDay.windDirectionCode]
        lightKLux = values["light_intensity"]
        rainfallMM = values["rainfall"]
        // The console measures absolute pressure and files it under an indoor
        // code; there is no separate outdoor pressure.
        stationPressureHPa = values["indoor_pressure"]
        schemaVersion = Self.archiveSchemaVersion
    }

    /// How many station fields carry a value, to prefer the fuller of two
    /// copies of one round.
    var filledFieldCount: Int {
        [indoorTempC, indoorHumidity, outdoorTempC, outdoorHumidity, windSpeedMS,
         windGustMS, windDirectionDeg, lightKLux, rainfallMM, stationPressureHPa]
            .compactMap { $0 }.count
    }

    /// True when the row carries the indoor pair the model needs as its target.
    var hasIndoorTarget: Bool { indoorTempC != nil && indoorHumidity != nil }
}

// MARK: - Local store

/// The local copy of the station's readings, kept in step with its archive.
struct StationReadingStore {

    /// Bring the stored rows for one UTC day in line with the station's record
    /// of that day, returning how many rounds were filed.
    ///
    /// Rows are updated in place where a round's time is already stored, not
    /// deleted and reinserted: with sync across devices on, two devices reading
    /// the same record then converge on the same rows instead of each adding
    /// its own copy. Stored rows for that day and station that the record no
    /// longer contains are removed, and so are that day's rows from the
    /// key-value feed, which only ever carried this one station. Rows from any
    /// other station are left alone.
    ///
    /// Does not save; the caller saves once for the whole batch.
    @discardableResult
    static func applyDay(_ day: String, station: String,
                         rounds: [StationDay.Round], context: ModelContext) throws -> Int {
        guard let start = StationDay.start(ofDay: day) else { return 0 }
        let end = start.addingTimeInterval(24 * 3600)
        let archived = IndoorReading.archiveSchemaVersion
        // Filtered by source in memory: a day is about 72 rows, and the
        // compound predicate buys nothing but compile time.
        let stored = try context.fetch(FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))
            .filter { $0.sourceID == station || $0.schemaVersion < archived }

        var byDate: [Date: [IndoorReading]] = [:]
        for row in stored { byDate[row.date, default: []].append(row) }

        var filed = 0
        for round in rounds where round.date >= start && round.date < end {
            let copies = byDate.removeValue(forKey: round.date) ?? []
            let row: IndoorReading
            if let existing = copies.first {
                row = existing
                row.sourceID = station
            } else {
                row = IndoorReading(date: round.date, sourceID: station)
                context.insert(row)
            }
            row.fill(from: round.values)
            for extra in copies.dropFirst() { context.delete(extra) }
            filed += 1
        }
        for leftovers in byDate.values {
            for row in leftovers { context.delete(row) }
        }
        return filed
    }

    /// Remove every row that came from the key-value feed, returning how many.
    ///
    /// Called once the archive has been read from the start: it holds every
    /// reading the feed ever carried, and more.
    @discardableResult
    static func retireFeedRows(context: ModelContext) throws -> Int {
        let archived = IndoorReading.archiveSchemaVersion
        let rows = try context.fetch(FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.schemaVersion < archived }))
        for row in rows { context.delete(row) }
        return rows.count
    }

    /// The station each day record belongs to, in the same order.
    ///
    /// A record normally names its station. One that does not — written before
    /// the station app knew the device's name — belongs to the only station the
    /// other records name, or to the one remembered from an earlier read. Where
    /// that is ambiguous it stays nil and the record is not filed.
    static func stationNames(_ named: [String?], remembered: String?) -> [String?] {
        let names = Set(named.compactMap { $0 })
        let fallback = names.isEmpty ? remembered : (names.count == 1 ? names.first : nil)
        return named.map { $0 ?? fallback }
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

    /// Stored rows for a station, oldest first, one per time.
    ///
    /// Two copies of one round can exist for a while when sync across devices
    /// merges rows two devices filed independently; the fuller copy is used.
    static func history(sourceID: String,
                        since: Date = .distantPast,
                        context: ModelContext) -> [IndoorReading] {
        let descriptor = FetchDescriptor<IndoorReading>(
            predicate: #Predicate { $0.sourceID == sourceID && $0.date >= since },
            sortBy: [SortDescriptor(\.date)])
        var rows: [IndoorReading] = []
        for row in (try? context.fetch(descriptor)) ?? [] {
            if let last = rows.last, last.date == row.date {
                if row.filledFieldCount > last.filledFieldCount { rows[rows.count - 1] = row }
            } else {
                rows.append(row)
            }
        }
        return rows
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

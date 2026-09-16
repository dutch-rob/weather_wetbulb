//
//  WeatherArchive.swift
//  weather_wetbulb
//
//  A durable copy of the outdoor weather behind the indoor model.
//
//  WeatherKit serves only about ten days of history and the app does not get to
//  keep it, so every station reading older than that used to be matched against
//  the oldest hour still on hand — in one export, 71 readings all received the
//  same hour's weather, out by 4.4 °C on average and 11 °C at worst. Those rows
//  then taught the model relationships that never happened.
//
//  So each hour is archived as it arrives: one record per UTC day per place,
//  holding the whole hourly point rather than only the fields today's model
//  reads, since re-fetching a past hour later is not possible. WeatherCloudArchive
//  keeps the same days in CloudKit; this is the local copy the fit reads.
//

import Foundation
import SwiftData
import CoreLocation

@Model
final class ArchivedWeatherDay {
    /// "yyyy-MM-dd", UTC — the day these hours belong to.
    var day: String = ""
    /// Rounded coordinates, so days for one house group together.
    var place: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    /// Hours held, kept beside the payload so a day can be compared without
    /// decompressing it.
    var hourCount: Int = 0
    /// Deflated JSON array of `ForecastPoint`.
    var hours: Data = Data()
    var updatedAt: Date = Date()

    init(day: String, place: String, latitude: Double, longitude: Double) {
        self.day = day
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
    }

    var points: [ForecastPoint] { WeatherArchive.decode(hours) }
}

enum WeatherArchive {

    /// Days of history a normal refresh asks WeatherKit for. Anything older has
    /// to be requested on its own, which is what the backfill does.
    static let normalHistoryDays = 10

    /// Days per backfill request. WeatherKit answers a range at a time, and a
    /// week keeps each request small enough to fail cheaply.
    static let backfillChunkDays = 7

    /// Coordinates rounded to about a hundred metres. Two readings from the
    /// same house then share an archive, while a genuinely different place
    /// keeps its own.
    static func placeKey(_ location: CLLocation) -> String {
        String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func day(of date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func start(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func encode(_ points: [ForecastPoint]) -> Data? {
        guard let json = try? JSONEncoder().encode(points.sorted { $0.date < $1.date }) else { return nil }
        return (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
    }

    static func decode(_ data: Data) -> [ForecastPoint] {
        guard !data.isEmpty else { return [] }
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        return (try? JSONDecoder().decode([ForecastPoint].self, from: json)) ?? []
    }

    /// Spans still worth asking WeatherKit for, oldest first.
    ///
    /// Only whole days missing from `covered` are requested, and days already
    /// tried without result are skipped so a stretch WeatherKit simply has no
    /// data for is not asked for again on every refresh. Runs of missing days
    /// are split into chunks so one request cannot become enormous.
    static func missingSpans(needed: DateInterval,
                             covered: Set<String>,
                             ignoring: Set<String> = [],
                             chunkDays: Int = backfillChunkDays) -> [DateInterval] {
        guard needed.duration > 0 else { return [] }
        let calendar = utcCalendar
        var missing: [String] = []
        var cursor = calendar.startOfDay(for: needed.start)
        while cursor < needed.end {
            let name = day(of: cursor)
            if !covered.contains(name) && !ignoring.contains(name) { missing.append(name) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !missing.isEmpty else { return [] }

        var spans: [DateInterval] = []
        var run: [String] = []
        func flush() {
            guard let first = run.first, let last = run.last,
                  let from = start(ofDay: first), let to = start(ofDay: last),
                  let end = calendar.date(byAdding: .day, value: 1, to: to) else { run = []; return }
            spans.append(DateInterval(start: max(from, needed.start), end: min(end, needed.end)))
            run = []
        }
        for name in missing {
            if let last = run.last,
               let previous = start(ofDay: last),
               let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               day(of: expected) != name {
                flush()                         // a gap: start a new run
            }
            run.append(name)
            if run.count == chunkDays { flush() }
        }
        flush()
        return spans.filter { $0.duration > 0 }
    }
}

// MARK: - Local copy

struct WeatherArchiveStore {

    /// File `points` into their days, merging with what is already stored.
    /// Returns the days that changed, so only those need pushing to CloudKit.
    @discardableResult
    static func upsert(_ points: [ForecastPoint], location: CLLocation,
                       context: ModelContext) throws -> [String] {
        guard !points.isEmpty else { return [] }
        let place = WeatherArchive.placeKey(location)
        var byDay: [String: [ForecastPoint]] = [:]
        for point in points { byDay[WeatherArchive.day(of: point.date), default: []].append(point) }

        var changed: [String] = []
        for (day, fresh) in byDay {
            let existing = try record(day: day, place: place, context: context)
            var byHour: [Date: ForecastPoint] = [:]
            for point in existing?.points ?? [] { byHour[point.date] = point }
            // A freshly fetched hour replaces an archived one: WeatherKit
            // revises its own history, and the later answer is its best one.
            for point in fresh { byHour[point.date] = point }
            let merged = byHour.values.sorted { $0.date < $1.date }
            guard let payload = WeatherArchive.encode(merged) else { continue }

            let row = existing ?? {
                let fresh = ArchivedWeatherDay(day: day, place: place,
                                               latitude: location.coordinate.latitude,
                                               longitude: location.coordinate.longitude)
                context.insert(fresh)
                return fresh
            }()
            guard row.hours != payload else { continue }
            row.hours = payload
            row.hourCount = merged.count
            row.updatedAt = Date()
            changed.append(day)
        }
        return changed
    }

    static func record(day: String, place: String, context: ModelContext) throws -> ArchivedWeatherDay? {
        var descriptor = FetchDescriptor<ArchivedWeatherDay>(
            predicate: #Predicate { $0.day == day && $0.place == place })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func coveredDays(place: String, context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<ArchivedWeatherDay>(predicate: #Predicate { $0.place == place })
        descriptor.propertiesToFetch = [\.day]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.day))
    }

    /// Archived hours for a place, oldest first.
    static func points(place: String, from: Date = .distantPast, to: Date = .distantFuture,
                       context: ModelContext) -> [ForecastPoint] {
        let descriptor = FetchDescriptor<ArchivedWeatherDay>(
            predicate: #Predicate { $0.place == place },
            sortBy: [SortDescriptor(\.day)])
        let days = (try? context.fetch(descriptor)) ?? []
        return days.flatMap(\.points).filter { $0.date >= from && $0.date <= to }
            .sorted { $0.date < $1.date }
    }

    /// Everything stored for a place, for pushing to CloudKit.
    static func allDays(place: String, context: ModelContext) -> [ArchivedWeatherDay] {
        let descriptor = FetchDescriptor<ArchivedWeatherDay>(
            predicate: #Predicate { $0.place == place }, sortBy: [SortDescriptor(\.day)])
        return (try? context.fetch(descriptor)) ?? []
    }
}

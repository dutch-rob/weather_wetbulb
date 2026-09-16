//
//  WeatherArchiveCoordinator.swift
//  weather_wetbulb
//
//  Keeps the weather archive in step: what another device wrote, what this
//  refresh just fetched, and whatever older stretch the station's readings
//  reach back to but WeatherKit's ten-day window no longer covers.
//
//  The backfill rule: a normal refresh already asks for the last ten days, so
//  only days older than that are worth a request of their own — and only those
//  not already archived. They are fetched oldest-first, a few days at a time,
//  so a long history fills in over several refreshes instead of stalling one.
//

import Foundation
import SwiftData
import CoreLocation
import OSLog

private let log = Logger(subsystem: "robotex.weather-wetbulb", category: "WeatherArchive")

@MainActor
final class WeatherArchiveCoordinator {
    static let shared = WeatherArchiveCoordinator()
    private init() {}

    private let cloud = WeatherCloudArchive()
    /// Days WeatherKit returned nothing for, so they are not asked for again on
    /// every refresh. A stretch before the station existed is simply not there.
    private static let emptyDaysKey = "weatherArchive.daysWithoutData"
    /// Backfill requests per sync. Enough to fill a fortnight in two refreshes,
    /// few enough that the screen is not waiting on the network for long.
    private let requestsPerSync = 3

    /// Bring the archive up to date for one place and report what happened.
    @discardableResult
    func sync(location: CLLocation,
              live: [ForecastPoint],
              earliestNeeded: Date?,
              context: ModelContext,
              now: Date = .now) async -> String {
        let place = WeatherArchive.placeKey(location)
        var notes: [String] = []

        // 1. Days another device archived.
        do {
            let incoming = try await cloud.fetchChanges()
            var stored = 0
            for day in incoming where day.place == place {
                stored += try WeatherArchiveStore.upsert(WeatherArchive.decode(day.hours),
                                                         location: location, context: context).count
            }
            if !incoming.isEmpty { try context.save() }
            await cloud.commit()
            if stored > 0 { notes.append("\(stored) days from iCloud") }
        } catch {
            log.error("Reading the weather archive failed: \(error, privacy: .public)")
        }

        // 2. Hours this refresh already has. Only settled ones: a forecast hour
        //    would be archived as a prediction and then never revisited.
        var changed: Set<String> = []
        do {
            let settled = live.filter { $0.date <= now && $0.kind != .current }
            changed.formUnion(try WeatherArchiveStore.upsert(settled, location: location, context: context))
        } catch {
            log.error("Archiving fresh weather failed: \(error, privacy: .public)")
        }

        // 3. Older days the station's readings reach but a refresh never asks for.
        if let earliest = earliestNeeded {
            let boundary = now.addingTimeInterval(-Double(WeatherArchive.normalHistoryDays) * 86400)
            if earliest < boundary {
                let defaults = UserDefaults.standard
                var blank = Set(defaults.stringArray(forKey: Self.emptyDaysKey) ?? [])
                let spans = WeatherArchive.missingSpans(
                    needed: DateInterval(start: earliest, end: boundary),
                    covered: WeatherArchiveStore.coveredDays(place: place, context: context),
                    ignoring: blank)
                var filled = 0
                for span in spans.prefix(requestsPerSync) {
                    do {
                        let points = try await WeatherService.pastHours(at: location,
                                                                        from: span.start, to: span.end)
                        if points.isEmpty {
                            blank.formUnion(Self.days(in: span))
                        } else {
                            changed.formUnion(try WeatherArchiveStore.upsert(points, location: location,
                                                                             context: context))
                            filled += points.count
                        }
                    } catch {
                        log.error("Backfill request failed: \(error, privacy: .public)")
                        break                     // try again next time rather than hammer
                    }
                }
                defaults.set(Array(blank).sorted(), forKey: Self.emptyDaysKey)
                if filled > 0 { notes.append("\(filled) older hours fetched") }
                if spans.count > requestsPerSync {
                    notes.append("\(spans.count - requestsPerSync) older stretches still to fetch")
                }
            }
        }

        // 4. Save, then hand the changed days to CloudKit.
        if context.hasChanges {
            do { try context.save() } catch {
                context.rollback()
                log.error("Saving the weather archive failed: \(error, privacy: .public)")
                return notes.joined(separator: "; ")
            }
        }
        if !changed.isEmpty {
            let days = WeatherArchiveStore.allDays(place: place, context: context)
                .filter { changed.contains($0.day) }
                .map { WeatherCloudArchive.DayRecord(day: $0.day, place: $0.place,
                                                     latitude: $0.latitude, longitude: $0.longitude,
                                                     hourCount: $0.hourCount, hours: $0.hours) }
            do {
                let written = try await cloud.save(days)
                if written > 0 { notes.append("\(written) days written to iCloud") }
            } catch {
                log.error("Writing the weather archive failed: \(error, privacy: .public)")
            }
        }
        return notes.joined(separator: "; ")
    }

    private static func days(in span: DateInterval) -> [String] {
        let calendar = WeatherArchive.utcCalendar
        var out: [String] = []
        var cursor = calendar.startOfDay(for: span.start)
        while cursor < span.end {
            out.append(WeatherArchive.day(of: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}

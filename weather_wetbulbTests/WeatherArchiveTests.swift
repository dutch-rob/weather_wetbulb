//
//  WeatherArchiveTests.swift
//  weather_wetbulbTests
//
//  The archive that keeps WeatherKit's history past the ten days it will serve:
//  how hours are filed into UTC days, and which older stretches are still worth
//  asking for.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import weather_wetbulb

@MainActor
struct WeatherArchiveTests {

    // MARK: - Fixtures

    static let home = CLLocation(latitude: 34.1056379, longitude: -116.4166359)
    static let dayStart: Date = WeatherArchive.start(ofDay: "2026-09-10")!

    static func point(_ date: Date, tempC: Double = 20) -> ForecastPoint {
        ForecastPoint(kind: .historic, date: date, symbolName: "sun.max", isDaylight: true, uvIndex: 3,
                      temperatureF: tempC * 9 / 5 + 32, temperatureC: tempC,
                      apparentTemperatureF: 0, apparentTemperatureC: 0,
                      wetBulbF: 0, wetBulbC: 0, dewPointF: 0, dewPointC: 0,
                      precipProbability: 0, precipitationMM: 0,
                      windSpeedMPH: 0, windSpeedKPH: 4, windGustMPH: 0, windGustKPH: 8,
                      windDirectionDegrees: 180, cloudCover: 0.2,
                      cloudCoverLow: 0, cloudCoverMedium: 0, cloudCoverHigh: 0,
                      humidity: 0.4, stationPressurePa: 89_000)
    }

    static func hours(_ day: String, _ range: Range<Int>, tempC: Double = 20) -> [ForecastPoint] {
        let start = WeatherArchive.start(ofDay: day)!
        return range.map { point(start.addingTimeInterval(Double($0) * 3600), tempC: tempC) }
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: ArchivedWeatherDay.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                              cloudKitDatabase: .none))
    }

    // MARK: - Days and places

    @Test func namesTheUTCDayAnHourBelongsTo() {
        #expect(WeatherArchive.day(of: Self.dayStart) == "2026-09-10")
        #expect(WeatherArchive.day(of: Self.dayStart.addingTimeInterval(23 * 3600 + 3599)) == "2026-09-10")
        #expect(WeatherArchive.day(of: Self.dayStart.addingTimeInterval(24 * 3600)) == "2026-09-11")
        #expect(WeatherArchive.start(ofDay: "not a day") == nil)
    }

    @Test func groupsOneHouseUnderOnePlace() {
        let nearby = CLLocation(latitude: 34.1056, longitude: -116.41661)
        let elsewhere = CLLocation(latitude: 33.4484, longitude: -112.0740)
        #expect(WeatherArchive.placeKey(Self.home) == WeatherArchive.placeKey(nearby))
        #expect(WeatherArchive.placeKey(Self.home) != WeatherArchive.placeKey(elsewhere))
    }

    @Test func keepsEveryFieldThroughTheStoredForm() throws {
        let original = Self.hours("2026-09-10", 0..<24)
        let data = try #require(WeatherArchive.encode(original))
        let back = WeatherArchive.decode(data)
        #expect(back.count == 24)
        #expect(back.first?.stationPressurePa == 89_000)
        #expect(back.first?.windDirectionDegrees == 180)
        #expect(data.count < original.count * 200)      // deflated, not raw JSON
    }

    // MARK: - What still needs fetching

    @Test func asksOnlyForDaysItDoesNotHave() {
        let needed = DateInterval(start: WeatherArchive.start(ofDay: "2026-09-01")!,
                                  end: WeatherArchive.start(ofDay: "2026-09-05")!)
        let spans = WeatherArchive.missingSpans(needed: needed, covered: ["2026-09-02", "2026-09-03"])
        #expect(spans.count == 2)
        #expect(spans.first?.start == WeatherArchive.start(ofDay: "2026-09-01"))
        #expect(spans.first?.end == WeatherArchive.start(ofDay: "2026-09-02"))
        #expect(spans.last?.start == WeatherArchive.start(ofDay: "2026-09-04"))
    }

    @Test func splitsALongStretchIntoChunks() {
        let needed = DateInterval(start: WeatherArchive.start(ofDay: "2026-08-01")!,
                                  end: WeatherArchive.start(ofDay: "2026-08-20")!)
        let spans = WeatherArchive.missingSpans(needed: needed, covered: [], chunkDays: 7)
        #expect(spans.count == 3)
        #expect(spans[0].duration == 7 * 86400)
        #expect(spans.last?.end == needed.end)
    }

    @Test func doesNotAskAgainForDaysWithNoData() {
        let needed = DateInterval(start: WeatherArchive.start(ofDay: "2026-09-01")!,
                                  end: WeatherArchive.start(ofDay: "2026-09-04")!)
        let spans = WeatherArchive.missingSpans(needed: needed, covered: [],
                                                ignoring: ["2026-09-01", "2026-09-02", "2026-09-03"])
        #expect(spans.isEmpty)
    }

    @Test func asksForNothingWhenEverythingIsHeld() {
        let needed = DateInterval(start: WeatherArchive.start(ofDay: "2026-09-01")!,
                                  end: WeatherArchive.start(ofDay: "2026-09-03")!)
        #expect(WeatherArchive.missingSpans(needed: needed, covered: ["2026-09-01", "2026-09-02"]).isEmpty)
    }

    // MARK: - The local copy

    @Test func filesHoursIntoTheirDays() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        let changed = try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 20..<24)
                                                     + Self.hours("2026-09-11", 0..<3),
                                                     location: Self.home, context: context)
        try context.save()
        #expect(Set(changed) == ["2026-09-10", "2026-09-11"])
        let place = WeatherArchive.placeKey(Self.home)
        #expect(WeatherArchiveStore.coveredDays(place: place, context: context) == ["2026-09-10", "2026-09-11"])
        #expect(WeatherArchiveStore.points(place: place, context: context).count == 7)
    }

    @Test func addsHoursToADayAlreadyHeld() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<12), location: Self.home, context: context)
        try context.save()
        let changed = try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 12..<24), location: Self.home, context: context)
        try context.save()
        #expect(changed == ["2026-09-10"])
        let place = WeatherArchive.placeKey(Self.home)
        #expect(WeatherArchiveStore.points(place: place, context: context).count == 24)
        #expect(try WeatherArchiveStore.record(day: "2026-09-10", place: place, context: context)?.hourCount == 24)
    }

    @Test func aFreshlyFetchedHourReplacesAnArchivedOne() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<3, tempC: 18), location: Self.home, context: context)
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<3, tempC: 21), location: Self.home, context: context)
        try context.save()
        let points = WeatherArchiveStore.points(place: WeatherArchive.placeKey(Self.home), context: context)
        #expect(points.count == 3)
        #expect(points.allSatisfy { $0.temperatureC == 21 })
    }

    @Test func readsBackOnlyTheRangeAsked() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<24), location: Self.home, context: context)
        try context.save()
        let noon = Self.dayStart.addingTimeInterval(12 * 3600)
        let points = WeatherArchiveStore.points(place: WeatherArchive.placeKey(Self.home),
                                                from: noon, to: Self.dayStart.addingTimeInterval(15 * 3600),
                                                context: context)
        #expect(points.map(\.date) == (12...15).map { Self.dayStart.addingTimeInterval(Double($0) * 3600) })
    }

    @Test func keepsPlacesApart() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        let elsewhere = CLLocation(latitude: 33.4484, longitude: -112.0740)
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<4), location: Self.home, context: context)
        try WeatherArchiveStore.upsert(Self.hours("2026-09-10", 0..<9), location: elsewhere, context: context)
        try context.save()
        #expect(WeatherArchiveStore.points(place: WeatherArchive.placeKey(Self.home), context: context).count == 4)
        #expect(WeatherArchiveStore.points(place: WeatherArchive.placeKey(elsewhere), context: context).count == 9)
    }
}

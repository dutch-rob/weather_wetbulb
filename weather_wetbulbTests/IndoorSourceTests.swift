//
//  IndoorSourceTests.swift
//  weather_wetbulbTests
//
//  Which station's readings the model is fitted from. No station is compiled
//  into the app, so these pin the decisions that replaced the list: recognising
//  a feed by its content, refiling rows stored under the app's old name for the
//  station, and refusing to guess between stations.
//

import Testing
import Foundation
import SwiftData
@testable import weather_wetbulb

@MainActor
struct IndoorSourceTests {

    // MARK: - Fixtures

    static let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func feed(source: String, minutes: [Double]) -> IndoorFeed {
        IndoorFeed(version: 1, source: source,
                   generated: Int(t0.timeIntervalSince1970),
                   readings: minutes.map {
                       IndoorFeed.Reading(t: Int(at($0).timeIntervalSince1970),
                                          indoorTemperatureC: 22, indoorHumidity: 40)
                   })
    }

    /// A row as stored before stations named themselves.
    static func legacyRow(minutes: Double, context: ModelContext) {
        let row = IndoorReading(date: at(minutes), sourceID: "old-label")
        row.schemaVersion = IndoorReading.legacySchemaVersion
        context.insert(row)
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: IndoorReading.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                              cloudKitDatabase: .none))
    }

    static let home = Place(name: "Home", latitude: 10, longitude: 20,
                            altitude: 900, indoorMonitoring: true)

    // MARK: - Recognising feeds

    @Test func findsAFeedUnderWhateverKeyItWasPublishedAs() throws {
        let data = try JSONEncoder().encode(Self.feed(source: "north-station", minutes: [0]))
        #expect(IndoorFeedReader.feeds(in: ["any_key_at_all": data]).map(\.source) == ["north-station"])
    }

    @Test func skipsEverythingElseSharingTheStore() throws {
        let places = try JSONEncoder().encode([Place(name: "Somewhere", latitude: 1, longitude: 2)])
        let values: [String: Any] = [
            "places": places,
            "useFahrenheit": true,
            "notJSON": Data("hello".utf8),
        ]
        #expect(IndoorFeedReader.feeds(in: values).isEmpty)
    }

    @Test func ignoresAFeedThatDoesNotNameItsStation() throws {
        let data = try JSONEncoder().encode(Self.feed(source: "", minutes: [0]))
        #expect(IndoorFeedReader.feeds(in: ["k": data]).isEmpty)
    }

    // MARK: - Deciding whose readings they are

    @Test func oneStationIsTheHomes() {
        #expect(IndoorSourceResolution(sourceIDs: ["a", "a", "a"]) == .single("a"))
    }

    @Test func noReadingsMeansNoStation() {
        #expect(IndoorSourceResolution(sourceIDs: [String]()) == .noStation)
    }

    @Test func severalStationsAreRefusedAndListed() {
        #expect(IndoorSourceResolution(sourceIDs: ["b", "a", "b"]) == .several(["a", "b"]))
    }

    // MARK: - Stored rows

    @Test func filesReadingsUnderTheNameTheFeedGivesItself() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try IndoorFeedStore.ingest(Self.feed(source: "north-station", minutes: [0, 20]), context: context)
        #expect(IndoorFeedStore.resolveSource(context: context) == .single("north-station"))
        // Republishing an overlapping window stores only what is new.
        #expect(try IndoorFeedStore.ingest(Self.feed(source: "north-station", minutes: [0, 20, 40]),
                                           context: context) == 1)
    }

    @Test func refilesRowsStoredUnderTheOldName() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        for m in [0.0, 20, 40] { Self.legacyRow(minutes: m, context: context) }
        try context.save()

        #expect(try IndoorFeedStore.adoptLegacyRows(as: "north-station", context: context) == 3)
        try IndoorFeedStore.ingest(Self.feed(source: "north-station", minutes: [20, 40, 60]), context: context)

        #expect(IndoorFeedStore.resolveSource(context: context) == .single("north-station"))
        let rows = IndoorFeedStore.history(sourceID: "north-station", context: context)
        #expect(rows.map(\.date) == [0.0, 20, 40, 60].map(Self.at))
        #expect(rows.allSatisfy { $0.schemaVersion == IndoorReading.currentSchemaVersion })
    }

    @Test func dropsALegacyRowAlreadyStoredUnderTheNewName() throws {
        // The order ingest avoids, which must still not leave one reading
        // stored twice.
        let container = try Self.makeContainer()
        let context = container.mainContext
        try IndoorFeedStore.ingest(Self.feed(source: "north-station", minutes: [0, 20]), context: context)
        for m in [0.0, 20, 40] { Self.legacyRow(minutes: m, context: context) }
        try context.save()
        #expect(IndoorFeedStore.resolveSource(context: context) == .several(["north-station", "old-label"]))

        try IndoorFeedStore.adoptLegacyRows(as: "north-station", context: context)

        #expect(IndoorFeedStore.history(sourceID: "north-station", context: context).map(\.date)
                == [0.0, 20, 40].map(Self.at))
        #expect(IndoorFeedStore.resolveSource(context: context) == .single("north-station"))
    }

    // MARK: - When the model may be fitted

    @Test func needsAMarkedHome() {
        #expect(ModelReportView.blocker(home: nil, resolution: .single("s")) == .noHome)
    }

    @Test func needsTheHomesAltitude() {
        var unknown = Self.home
        unknown.altitude = 0
        #expect(ModelReportView.blocker(home: unknown, resolution: .single("s")) == .noAltitude(home: "Home"))
    }

    @Test func needsReadingsFromExactlyOneStation() {
        #expect(ModelReportView.blocker(home: Self.home, resolution: .noStation) == .noReadings)
        #expect(ModelReportView.blocker(home: Self.home, resolution: .several(["a", "b"]))
                == .severalStations(["a", "b"]))
        #expect(ModelReportView.blocker(home: Self.home, resolution: .single("a")) == nil)
    }
}

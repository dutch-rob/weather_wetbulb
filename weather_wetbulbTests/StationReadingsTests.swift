//
//  StationReadingsTests.swift
//  weather_wetbulbTests
//
//  The station's CloudKit day records turned into the rows the model uses, and
//  the decisions about whose readings they are. Payloads are built the way the
//  station app builds them: deflated JSON of {c, t, v} samples, one burst of
//  data points a second apart per report round.
//

import Testing
import Foundation
import SwiftData
@testable import weather_wetbulb

@MainActor
struct StationReadingsTests {

    // MARK: - Fixtures

    static let day = "2026-09-10"
    static let dayStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
    }()

    static func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }

    /// One report round as the console sends it, with the wind direction the
    /// station app re-timed onto its first sample.
    static func burst(atMinute minutes: Double, indoor: Double = 24, outdoor: Double = 30) -> [StationSample] {
        let s = Int(at(minutes).timeIntervalSince1970)
        return [StationSample(c: "indoor_temperature", t: s, v: indoor),
                StationSample(c: "outdoor_temperature", t: s + 1, v: outdoor),
                StationSample(c: "indoor_humidity", t: s + 2, v: 40),
                StationSample(c: "outdoor_humidity", t: s + 3, v: 20),
                StationSample(c: "indoor_pressure", t: s + 4, v: 889),
                StationSample(c: "rainfall", t: s + 5, v: 0),
                StationSample(c: "wind_speed", t: s + 6, v: 2.5),
                StationSample(c: "wind_gust", t: s + 7, v: 4),
                StationSample(c: "light_intensity", t: s + 8, v: 0),
                StationSample(c: "uvi", t: s + 9, v: 0),
                StationSample(c: StationDay.windDirectionCode, t: s, v: 270)]
    }

    static func deflated(_ samples: [StationSample]) throws -> Data {
        try (JSONEncoder().encode(samples) as NSData).compressed(using: .zlib) as Data
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: IndoorReading.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                              cloudKitDatabase: .none))
    }

    static let home = Place(name: "Home", latitude: 10, longitude: 20,
                            altitude: 900, indoorMonitoring: true)

    // MARK: - Reading a day record

    @Test func readsADeflatedPayload() throws {
        let samples = Self.burst(atMinute: 0)
        #expect(StationDay.samples(fromPayload: try Self.deflated(samples)) == samples)
    }

    @Test func readsAnUncompressedPayloadToo() throws {
        let samples = Self.burst(atMinute: 0)
        #expect(StationDay.samples(fromPayload: try JSONEncoder().encode(samples)) == samples)
    }

    @Test func readsAnythingElseAsNoSamples() {
        #expect(StationDay.samples(fromPayload: Data("not a payload".utf8)).isEmpty)
    }

    @Test func findsTheStartOfTheUTCDayARecordIsNamedFor() {
        #expect(StationDay.start(ofDay: Self.day) == Self.dayStart)
        #expect(StationDay.start(ofDay: "yesterday") == nil)
    }

    // MARK: - Report rounds

    @Test func gathersEachBurstIntoOneRound() {
        let rounds = StationDay.rounds(Self.burst(atMinute: 20) + Self.burst(atMinute: 0))
        #expect(rounds.map(\.date) == [Self.at(0), Self.at(20)])
        #expect(rounds.first?.values.count == 11)
        #expect(rounds.first?.values[StationDay.windDirectionCode] == 270)
    }

    @Test func keepsABurstTogetherAcrossAMinuteBoundary() {
        // Starts five seconds before the hour turns.
        let rounds = StationDay.rounds(Self.burst(atMinute: 59 + 55.0 / 60))
        #expect(rounds.count == 1)
        #expect(rounds.first?.values.count == 11)
    }

    @Test func dropsARoundWithOnlyAWindDirection() {
        let lone = [StationSample(c: StationDay.windDirectionCode,
                                  t: Int(Self.at(40).timeIntervalSince1970), v: 90)]
        #expect(StationDay.rounds(Self.burst(atMinute: 0) + lone).count == 1)
    }

    @Test func fillsEveryStationFieldFromARound() {
        let row = IndoorReading(date: Self.at(0), sourceID: "Backyard")
        row.fill(from: StationDay.rounds(Self.burst(atMinute: 0, indoor: 23.5, outdoor: 31))[0].values)
        #expect(row.indoorTempC == 23.5)
        #expect(row.outdoorTempC == 31)
        #expect(row.indoorHumidity == 40)
        #expect(row.outdoorHumidity == 20)
        #expect(row.windSpeedMS == 2.5)
        #expect(row.windGustMS == 4)
        #expect(row.windDirectionDeg == 270)
        #expect(row.stationPressureHPa == 889)
        #expect(row.rainfallMM == 0)
        #expect(row.lightKLux == 0)
        #expect(row.schemaVersion == IndoorReading.archiveSchemaVersion)
    }

    // MARK: - Filing days

    @Test func filesADayUnderTheStationItNames() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        let rounds = StationDay.rounds(Self.burst(atMinute: 0) + Self.burst(atMinute: 20))
        #expect(try StationReadingStore.applyDay(Self.day, station: "Backyard", rounds: rounds, context: context) == 2)
        try context.save()
        #expect(StationReadingStore.resolveSource(context: context) == .single("Backyard"))
        #expect(StationReadingStore.history(sourceID: "Backyard", context: context).count == 2)
    }

    @Test func readingADayAgainUpdatesRatherThanDuplicates() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try StationReadingStore.applyDay(Self.day, station: "Backyard",
                                         rounds: StationDay.rounds(Self.burst(atMinute: 0)), context: context)
        try context.save()
        // Later that day the record holds the same round, revised, plus a new one.
        let later = StationDay.rounds(Self.burst(atMinute: 0, indoor: 25) + Self.burst(atMinute: 20))
        try StationReadingStore.applyDay(Self.day, station: "Backyard", rounds: later, context: context)
        try context.save()
        let rows = try context.fetch(FetchDescriptor<IndoorReading>(sortBy: [SortDescriptor(\.date)]))
        #expect(rows.map(\.date) == [Self.at(0), Self.at(20)])
        #expect(rows.first?.indoorTempC == 25)
    }

    @Test func removesRoundsTheRecordNoLongerHolds() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        try StationReadingStore.applyDay(Self.day, station: "Backyard",
                                         rounds: StationDay.rounds(Self.burst(atMinute: 0) + Self.burst(atMinute: 20)),
                                         context: context)
        try context.save()
        try StationReadingStore.applyDay(Self.day, station: "Backyard",
                                         rounds: StationDay.rounds(Self.burst(atMinute: 20)), context: context)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<IndoorReading>()).map(\.date) == [Self.at(20)])
    }

    @Test func replacesThatDaysRowsFromTheKeyValueFeed() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        // Feed rows were timed to the whole minute and carried the feed's name.
        let sameDay = IndoorReading(date: Self.at(1), sourceID: "feed-name")
        sameDay.schemaVersion = 2
        let earlierDay = IndoorReading(date: Self.at(-60), sourceID: "feed-name")
        earlierDay.schemaVersion = 1
        context.insert(sameDay)
        context.insert(earlierDay)
        try StationReadingStore.applyDay(Self.day, station: "Backyard",
                                         rounds: StationDay.rounds(Self.burst(atMinute: 0)), context: context)
        try context.save()
        #expect(StationReadingStore.sourceIDs(context: context) == ["Backyard", "feed-name"])

        #expect(try StationReadingStore.retireFeedRows(context: context) == 1)
        try context.save()
        #expect(StationReadingStore.resolveSource(context: context) == .single("Backyard"))
    }

    @Test func leavesAnotherStationsRowsAlone() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        context.insert(IndoorReading(date: Self.at(20), sourceID: "Neighbour"))
        try StationReadingStore.applyDay(Self.day, station: "Backyard",
                                         rounds: StationDay.rounds(Self.burst(atMinute: 0)), context: context)
        try context.save()
        #expect(StationReadingStore.resolveSource(context: context) == .several(["Backyard", "Neighbour"]))
    }

    @Test func historyKeepsOneRowPerTimeAndPrefersTheFullerCopy() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext
        let sparse = IndoorReading(date: Self.at(0), sourceID: "Backyard")
        sparse.indoorTempC = 24
        let full = IndoorReading(date: Self.at(0), sourceID: "Backyard")
        full.fill(from: StationDay.rounds(Self.burst(atMinute: 0))[0].values)
        context.insert(sparse)
        context.insert(full)
        try context.save()
        let rows = StationReadingStore.history(sourceID: "Backyard", context: context)
        #expect(rows.count == 1)
        #expect(rows.first?.windSpeedMS == 2.5)
    }

    // MARK: - Naming the station

    @Test func anUnnamedRecordBelongsToTheOnlyStationNamed() {
        #expect(StationReadingStore.stationNames(["Backyard", nil], remembered: nil) == ["Backyard", "Backyard"])
        #expect(StationReadingStore.stationNames([nil], remembered: "Backyard") == ["Backyard"])
    }

    @Test func anUnnamedRecordAmongTwoStationsIsNotFiled() {
        #expect(StationReadingStore.stationNames(["A", "B", nil], remembered: "A") == ["A", "B", nil])
        #expect(StationReadingStore.stationNames([nil], remembered: nil) == [nil])
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

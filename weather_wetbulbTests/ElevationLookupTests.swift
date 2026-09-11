//
//  ElevationLookupTests.swift
//  weather_wetbulbTests
//
//  The bodies here are the ones the USGS service actually returned when this
//  was written, copied verbatim: a success for Phoenix, and the plain sentence
//  it sends for a point outside its coverage.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct ElevationLookupTests {

    @Test func readsTheQuotedElevationFromARealReply() throws {
        // Verbatim reply for Phoenix (-112.0740, 33.4484).
        let body = #"{"location":{"x":-112.074,"y":33.4484,"spatialReference":{"wkid":4326,"latestWkid":4326}},"locationId":0,"value":"331.673278809","rasterId":19368,"resolution":1}"#
        let metres = try ElevationLookup.parse(Data(body.utf8))
        #expect(abs(metres - 331.673278809) < 1e-6)
    }

    @Test func acceptsABareNumberToo() throws {
        // Today the service quotes the value. A future version sending it as a
        // number should not break the lookup.
        let body = #"{"value":331.673278809}"#
        let metres = try ElevationLookup.parse(Data(body.utf8))
        #expect(abs(metres - 331.673278809) < 1e-6)
    }

    @Test func treatsTheOutsideCoverageSentenceAsNoData() {
        // Verbatim reply for Adelaide: not JSON at all. This is the normal
        // answer anywhere outside the United States, so it must read as "no
        // elevation here" rather than as a failed request.
        let body = "Invalid or missing input parameters."
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parse(Data(body.utf8))
        }
    }

    @Test func rejectsNoDataSentinels() {
        // Rasters with no value report large negatives; believing one would
        // put the house below the sea and skew every pressure correction.
        let body = #"{"value":"-1000000"}"#
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parse(Data(body.utf8))
        }
    }

    @Test func acceptsTheHighestAndLowestPlausibleGround() throws {
        // Dead Sea shore is about -430 m; the plausible range must not exclude
        // somewhere people actually live.
        #expect(try ElevationLookup.parse(Data(#"{"value":"-430"}"#.utf8)) == -430)
        #expect(try ElevationLookup.parse(Data(#"{"value":"4300"}"#.utf8)) == 4300)
    }
}

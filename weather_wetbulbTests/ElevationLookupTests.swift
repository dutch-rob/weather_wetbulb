//
//  ElevationLookupTests.swift
//  weather_wetbulbTests
//
//  Every reply body here was copied verbatim from a real call made while this
//  was written — including the two ways the services say "no data here", which
//  are the cases most likely to be got wrong.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct ElevationLookupTests {

    // MARK: - USGS

    @Test func readsTheQuotedElevationFromARealUSGSReply() throws {
        // Verbatim reply for Phoenix (-112.0740, 33.4484).
        let body = #"{"location":{"x":-112.074,"y":33.4484,"spatialReference":{"wkid":4326,"latestWkid":4326}},"locationId":0,"value":"331.673278809","rasterId":19368,"resolution":1}"#
        #expect(abs(try ElevationLookup.parseUSGS(Data(body.utf8)) - 331.673278809) < 1e-6)
    }

    @Test func acceptsABareNumberFromUSGSToo() throws {
        // The service quotes the value today; a future version sending a number
        // should not break the lookup.
        #expect(abs(try ElevationLookup.parseUSGS(Data(#"{"value":331.673278809}"#.utf8))
                    - 331.673278809) < 1e-6)
    }

    @Test func treatsTheUSGSOutsideCoverageSentenceAsNoData() {
        // Verbatim reply for Adelaide: not JSON at all. This is the normal
        // answer anywhere outside the United States, so it must read as "no
        // elevation here" and let the global service take over.
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parseUSGS(Data("Invalid or missing input parameters.".utf8))
        }
    }

    // MARK: - Open Topo Data

    @Test func readsAGlobalReplyAndKeepsTheDatasetThatAnswered() throws {
        // Verbatim reply for Adelaide.
        let body = #"{"results":[{"dataset":"srtm30m","elevation":58.0,"location":{"lat":-34.9285,"lng":138.6007}}],"status":"OK"}"#
        let reading = try ElevationLookup.parseOpenTopoData(Data(body.utf8))
        #expect(reading.metres == 58)
        #expect(reading.source.label == "SRTM (30 m)")
        #expect(reading.source.isSurfaceModel)
    }

    @Test func reportsTheFallbackDatasetAboveSrtmsLatitudeLimit() throws {
        // Verbatim reply for Reykjavik, north of SRTM's 60-degree limit: the
        // srtm30m,aster30m endpoint fell through to ASTER and said so.
        let body = #"{"results":[{"dataset":"aster30m","elevation":9.0,"location":{"lat":64.1466,"lng":-21.9426}}],"status":"OK"}"#
        let reading = try ElevationLookup.parseOpenTopoData(Data(body.utf8))
        #expect(reading.metres == 9)
        #expect(reading.source.label == "ASTER (30 m)")
    }

    @Test func treatsANullElevationAsNoData() {
        // Verbatim reply for a mid-ocean point. Note status is "OK": a null
        // elevation is the service working, not failing.
        let body = #"{"results":[{"dataset":"aster30m","elevation":null,"location":{"lat":0.0,"lng":-30.0}}],"status":"OK"}"#
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parseOpenTopoData(Data(body.utf8))
        }
    }

    // MARK: - Guards shared by both

    @Test func rejectsNoDataSentinels() {
        // Rasters with no value report large negatives; believing one would put
        // the house below the sea and skew every pressure correction.
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parseUSGS(Data(#"{"value":"-1000000"}"#.utf8))
        }
        #expect(throws: ElevationLookup.Failure.self) {
            try ElevationLookup.parseOpenTopoData(Data(#"{"results":[{"dataset":"srtm30m","elevation":-9999}]}"#.utf8))
        }
    }

    @Test func acceptsTheHighestAndLowestPlausibleGround() throws {
        // The Dead Sea shore is about -430 m: the range must not exclude
        // somewhere people actually live.
        #expect(try ElevationLookup.parseUSGS(Data(#"{"value":"-430"}"#.utf8)) == -430)
        #expect(try ElevationLookup.parseUSGS(Data(#"{"value":"4300"}"#.utf8)) == 4300)
    }

    // MARK: - Requests

    @Test func usgsTakesLongitudeAsXAndLatitudeAsY() {
        // The reversed order is the easy mistake, and it would silently return
        // the elevation of somewhere else entirely.
        let url = ElevationLookup.usgsURL(latitude: 33.4484, longitude: -112.074).absoluteString
        #expect(url.contains("x=-112.074"))
        #expect(url.contains("y=33.4484"))
        #expect(url.contains("units=Meters"))
    }

    @Test func globalRequestAsksSrtmBeforeAster() {
        // Order matters: the endpoint tries datasets left to right, and SRTM is
        // preferred where it reaches.
        let url = ElevationLookup.openTopoDataURL(latitude: 64.1466, longitude: -21.9426).absoluteString
        #expect(url.contains("/v1/srtm30m,aster30m"))
        #expect(url.contains("locations=64.1466,-21.9426"))
    }
}

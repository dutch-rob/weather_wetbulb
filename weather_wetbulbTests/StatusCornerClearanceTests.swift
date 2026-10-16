//
//  StatusCornerClearanceTests.swift
//  weather_wetbulbTests
//
//  The folded screen cannot be reached from a script — the hinge is set by
//  hand in the Simulator app — so the arithmetic that decides whether a graph
//  may spread under the clock is checked here instead of on a device.
//

import Testing
import CoreGraphics
@testable import weather_wetbulb

struct StatusCornerClearanceTests {

    // MARK: - Reading the corner off two rectangles

    @Test func readsATrailingCornerAsAFractionOfTheChart() {
        let chart = CGRect(x: 0, y: 0, width: 200, height: 400)
        let status = CGRect(x: 160, y: 0, width: 40, height: 100)
        let corner = StatusCorner(status: status, chart: chart)
        #expect(corner.trailing)
        #expect(abs(corner.width - 0.2) < 0.001)
        #expect(abs(corner.depth - 0.25) < 0.001)
        #expect(abs(corner.startFraction - 0.8) < 0.001)
    }

    @Test func readsALeadingCorner() {
        let chart = CGRect(x: 0, y: 0, width: 200, height: 400)
        let status = CGRect(x: 0, y: 0, width: 40, height: 100)
        let corner = StatusCorner(status: status, chart: chart)
        #expect(!corner.trailing)
        #expect(abs(corner.startFraction - 0) < 0.001)
        #expect(abs(corner.endFraction - 0.2) < 0.001)
    }

    @Test func aCornerThatMissesTheChartIsEmpty() {
        let chart = CGRect(x: 0, y: 200, width: 200, height: 200)
        let status = CGRect(x: 160, y: 0, width: 40, height: 100)
        #expect(StatusCorner(status: status, chart: chart).isEmpty)
        #expect(StatusCorner(status: .zero, chart: chart).isEmpty)
    }

    // MARK: - Raising the ceiling

    /// A corner a quarter of the way down the chart: anything plotted beneath
    /// it must sit in the bottom three quarters of the scale.
    @Test func liftsTheCeilingUntilThePeakSitsBelowTheCorner() throws {
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        let raised = try #require(StatusCornerClearance.raisedCeiling(
            peak: 80, domain: 30...90, corner: corner))
        #expect(raised > 90)
        let fromTheTop = (raised - 80) / (raised - 30)
        #expect(fromTheTop >= 0.27)
    }

    /// The case from the note that prompted this: the hot part of the day is
    /// on the left and the hours under the clock are the cool end, so the
    /// scale is already tall enough and nothing moves.
    @Test func leavesTheScaleAloneWhenThePeakAlreadyClearsTheCorner() throws {
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        for peak in [40.0, 68.0] {
            let raised = try #require(StatusCornerClearance.raisedCeiling(
                peak: peak, domain: 30...90, corner: corner))
            #expect(raised == 90)
        }
    }

    /// The same note's other case: put the afternoon peak under the clock and
    /// the ceiling goes up a long way — 30…90 becomes roughly 30…111 — which
    /// is the bargain being struck, a flatter curve for a wider one.
    @Test func acceptsALongLiftWhenThePeakItselfIsUnderTheCorner() throws {
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        let raised = try #require(StatusCornerClearance.raisedCeiling(
            peak: 89, domain: 30...90, corner: corner))
        #expect(raised > 105 && raised < 115)
    }

    @Test func refusesWhenTheStretchWouldFlattenTheCurve() {
        // A corner three fifths of the way down the chart leaves so little
        // room beneath it that the graph is better off narrow.
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 240),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(StatusCornerClearance.raisedCeiling(peak: 85, domain: 30...90, corner: corner) == nil)
    }

    @Test func refusesACornerTooWideToBeACorner() {
        let corner = StatusCorner(status: CGRect(x: 0, y: 0, width: 160, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(StatusCornerClearance.raisedCeiling(peak: 50, domain: 30...90, corner: corner) == nil)
    }

    @Test func refusesWhenNoHourFallsUnderTheCorner() {
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(StatusCornerClearance.raisedCeiling(peak: nil, domain: 30...90, corner: corner) == nil)
    }

    @Test func refusesWhenThereIsNoCorner() {
        #expect(StatusCornerClearance.raisedCeiling(peak: 70, domain: 30...90, corner: .none) == nil)
    }

    @Test func refusesAFlatScale() {
        let corner = StatusCorner(status: CGRect(x: 160, y: 0, width: 40, height: 100),
                                  chart: CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(StatusCornerClearance.raisedCeiling(peak: 50, domain: 50...50, corner: corner) == nil)
    }
}

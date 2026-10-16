//
//  StatusCornerClearance.swift
//  weather_wetbulb
//
//  Letting a graph spread under the clock and wifi corner without drawing
//  anything behind it.
//
//  On the folded screen the system reserves a strip down one side for that
//  corner, and a graph that respects the strip gives up a fifth of its width
//  for the sake of a box that only occupies the top of it. The graph can have
//  the whole width instead, provided the curve stays below the box — and
//  where the curve runs is a thing we choose, because the top of the scale is
//  ours to set.
//

import CoreGraphics
import Foundation

/// The clock-and-wifi corner as a chart sees it: how far down the plot it
/// reaches, and which hours pass beneath it.
struct StatusCorner: Equatable {
    /// How far down from the top of the chart the corner comes, as a fraction
    /// of the chart's height.
    var depth: Double
    /// How much of the chart's width it covers, as a fraction.
    var width: Double
    /// True when it sits against the trailing edge, false for leading.
    var trailing: Bool

    /// Nothing in the way.
    static let none = StatusCorner(depth: 0, width: 0, trailing: true)

    var isEmpty: Bool { depth <= 0 || width <= 0 }

    /// Where the corner starts, along the chart's width, as a fraction.
    var startFraction: Double { trailing ? 1 - width : 0 }
    /// Where it ends.
    var endFraction: Double { trailing ? 1 : width }

    /// Read the corner off two rectangles in the same coordinate space.
    init(status: CGRect, chart: CGRect) {
        let box = status.intersection(chart)
        guard !box.isNull, box.width > 0, box.height > 0,
              chart.width > 0, chart.height > 0 else {
            self = .none
            return
        }
        depth = Double((box.maxY - chart.minY) / chart.height)
        width = Double(box.width / chart.width)
        // Whichever edge it is nearer to. A corner in the middle of the top is
        // a Dynamic Island, not a reserved side strip, and no amount of
        // headroom moves a curve out from under the middle of a chart — the
        // caller gets `trailing` either way and the width test below is what
        // keeps that case out.
        trailing = (chart.maxX - box.maxX) <= (box.minX - chart.minX)
    }

    private init(depth: Double, width: Double, trailing: Bool) {
        self.depth = depth
        self.width = width
        self.trailing = trailing
    }
}

enum StatusCornerClearance {
    /// Widest slice of a chart worth clearing this way. A corner covering more
    /// than this is not a corner, and raising the ceiling enough to clear it
    /// would flatten the whole curve into the bottom of the frame.
    static let maxWidthFraction: Double = 0.45

    /// How much taller than its natural self the scale may be stretched.
    /// Beyond this the graph reads worse full width with a squashed curve than
    /// it did narrow with an honest one.
    static let maxStretch: Double = 1.8

    /// The top of the scale that puts `peak` just below the corner.
    ///
    /// - Parameters:
    ///   - peak: the highest value plotted in the hours that pass under the
    ///     corner. Nil when no plotted hour falls under it, which needs no
    ///     clearing at all.
    ///   - domain: the scale the chart would use were the corner not there.
    ///   - corner: the corner, as a fraction of the chart.
    /// - Returns: a replacement upper bound, or nil when the corner cannot be
    ///   cleared on sensible terms and the graph should keep clear of the
    ///   strip instead.
    static func raisedCeiling(peak: Double?,
                              domain: ClosedRange<Double>,
                              corner: StatusCorner) -> Double? {
        guard !corner.isEmpty else { return nil }
        guard corner.width <= maxWidthFraction else { return nil }
        guard corner.depth > 0, corner.depth < 1 else { return nil }
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return nil }
        guard let peak else { return nil }

        // Clear the corner by a hair more than its depth, so the curve does not
        // graze the underside of the clock.
        let clearance = min(0.95, corner.depth + 0.02)
        let needed = (peak - clearance * domain.lowerBound) / (1 - clearance)
        guard needed > domain.upperBound else { return domain.upperBound }
        guard needed - domain.lowerBound <= span * maxStretch else { return nil }
        return needed
    }
}

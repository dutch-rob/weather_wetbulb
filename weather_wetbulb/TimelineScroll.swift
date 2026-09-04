//
//  TimelineScroll.swift
//  weather_wetbulb
//
//  Shared pan state for the scrollable graph screens. With the fold timeline
//  off, a horizontal swipe pans a fixed-width window over the full -10d…+10d
//  series; a vertical swipe switches screens. Both graph screens share one
//  offset so panning survives a screen switch.
//

import Foundation

/// Which screen the paged (non-fold) mode is showing. The vertical swipe walks
/// this list and wraps around.
enum ForecastScreen: Int, CaseIterable {
    case today  = 0     // 24-hour window
    case tenDay = 1     // 10-day window
    case table  = 2

    var span: TimeInterval {
        switch self {
        case .today:  return 24 * 3600
        case .tenDay: return 240 * 3600
        case .table:  return 240 * 3600
        }
    }

    var title: String {
        switch self {
        case .today:  return "24 hour forecast"
        case .tenDay: return "10 day forecast"
        case .table:  return "table"
        }
    }

    /// Next/previous with wrap-around, so the three screens form a cycle.
    func advanced(by n: Int, includeTable: Bool) -> ForecastScreen {
        let cycle: [ForecastScreen] = includeTable ? [.today, .tenDay, .table] : [.today, .tenDay]
        guard let i = cycle.firstIndex(of: self) else { return cycle[0] }
        let j = ((i + n) % cycle.count + cycle.count) % cycle.count
        return cycle[j]
    }
}

enum TimelineScroll {
    /// How far back and forward the user may scroll, relative to "now".
    static let historyDays: Double = 10
    static let forecastDays: Double = 10

    /// Clamp a window-start offset (seconds from "now") so the window stays
    /// inside the data we actually have.
    static func clampStartOffset(_ offset: TimeInterval,
                                 span: TimeInterval,
                                 now: Date,
                                 dataLo: Date?,
                                 dataHi: Date?) -> TimeInterval {
        let lo = (dataLo ?? now).timeIntervalSince(now)
        let hiEdge = (dataHi ?? now.addingTimeInterval(span)).timeIntervalSince(now)
        let hi = max(lo, hiEdge - span)
        return min(hi, max(lo, offset))
    }
}

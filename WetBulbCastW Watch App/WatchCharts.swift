//
//  WatchCharts.swift
//  WetBulbCastW Watch App
//
//  Shared axis styling for the watch charts: prominent gridlines drawn at a
//  finer interval than the labels.
//

import SwiftUI
import Charts

private let gridLine = StrokeStyle(lineWidth: 0.5)
private let gridFine = Color.gray.opacity(0.3)
private let gridBold = Color.gray.opacity(0.6)
private let axisLabelFont = Font.system(size: 13)

/// Temperature y-axis: gridlines twice as dense as labels.
@AxisContentBuilder
func tempYAxis(useF: Bool) -> some AxisContent {
    let gridStride: Double  = useF ? 5  : 2.5
    let labelStride: Double = useF ? 10 : 5
    AxisMarks(position: .leading, values: .stride(by: gridStride)) {
        AxisGridLine(stroke: gridLine).foregroundStyle(gridBold)
    }
    AxisMarks(position: .leading, values: .stride(by: labelStride)) {
        AxisValueLabel().font(axisLabelFont)
    }
}

/// Generic (wind/precip) y-axis: prominent gridlines at the default ticks.
@AxisContentBuilder
func plainYAxis() -> some AxisContent {
    AxisMarks(position: .leading) { _ in
        AxisGridLine(stroke: gridLine).foregroundStyle(gridBold)
        AxisValueLabel().font(axisLabelFont)
    }
}

/// 24-hour x-axis: faint gridlines every 3 h, labeled bold gridlines every 6 h.
@AxisContentBuilder
func hourlyXAxis() -> some AxisContent {
    AxisMarks(values: .stride(by: .hour, count: 3)) {
        AxisGridLine(stroke: gridLine).foregroundStyle(gridFine)
    }
    AxisMarks(values: .stride(by: .hour, count: 6)) {
        AxisGridLine(stroke: gridLine).foregroundStyle(gridBold)
        AxisValueLabel(format: .dateTime.hour()).font(axisLabelFont)
    }
}

/// 10-day x-axis: faint gridlines every day, labeled bold gridlines every 2.
@AxisContentBuilder
func dailyXAxis() -> some AxisContent {
    AxisMarks(values: .stride(by: .day, count: 1)) {
        AxisGridLine(stroke: gridLine).foregroundStyle(gridFine)
    }
    AxisMarks(values: .stride(by: .day, count: 2)) {
        AxisGridLine(stroke: gridLine).foregroundStyle(gridBold)
        AxisValueLabel(format: .dateTime.weekday()).font(axisLabelFont)
    }
}

/// Whether the synced chart style is "filled" (the default) vs "classic" lines.
func watchUseFilledStyle() -> Bool {
    (WatchSyncReceiver.shared.payload?.chartStyle ?? "filled") != "classic"
}

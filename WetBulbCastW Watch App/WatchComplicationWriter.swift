//
//  WatchComplicationWriter.swift
//  WetBulbCastW Watch App
//
//  Builds the hourly ComplicationSnapshot from a forecast and writes it to the
//  App Group, then reloads the complications. Used by both the foreground model
//  and the background refresh.
//

import Foundation
import WidgetKit

enum WatchComplicationWriter {

    static func write(current: ForecastPoint?, series10d: [ForecastPoint],
                      useFahrenheit: Bool) {
        guard let snap = build(current: current, series10d: series10d,
                               useFahrenheit: useFahrenheit) else { return }
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()   // corner + circular
    }

    /// "now" + forecast hours up to +48 h, each tagged with its day's wet-bulb
    /// range. `now` is injectable so tests are deterministic.
    static func build(current: ForecastPoint?, series10d: [ForecastPoint],
                      useFahrenheit: Bool, now: Date = Date()) -> ComplicationSnapshot? {
        let cal = Calendar.current
        func dayKey(_ d: Date) -> Date { cal.startOfDay(for: d) }

        var dWetMin: [Date: Double] = [:], dWetMax: [Date: Double] = [:]
        for p in series10d {
            let k = dayKey(p.date)
            dWetMin[k] = min(dWetMin[k] ?? .greatestFiniteMagnitude, p.wetBulbC)
            dWetMax[k] = max(dWetMax[k] ?? -.greatestFiniteMagnitude, p.wetBulbC)
        }

        var hours: [ForecastPoint] = []
        if let c = current { hours.append(c) }
        let cutoff = now.addingTimeInterval(48 * 3600)
        let afterNow = current?.date ?? now
        hours += series10d.filter { $0.date > afterNow && $0.date <= cutoff }

        let frames: [ComplicationFrame] = hours.map { p in
            let k = dayKey(p.date)
            let wMin = dWetMin[k] ?? p.wetBulbC
            let wMax = dWetMax[k] ?? p.wetBulbC
            return ComplicationFrame(
                date: p.date,
                wetBulbC: p.wetBulbC,
                tempC: p.temperatureC,
                dayWetBulbMinC: wMin,
                dayWetBulbMaxC: wMax)
        }
        guard !frames.isEmpty else { return nil }

        return ComplicationSnapshot(updated: Date(), useFahrenheit: useFahrenheit,
                                    frames: frames)
    }
}

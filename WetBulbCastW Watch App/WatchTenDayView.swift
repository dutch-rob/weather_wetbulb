//
//  WatchTenDayView.swift
//  WetBulbCastW Watch App
//
//  10-day overview: temperature graph over a wind/precip graph, sharing day
//  labels. Honors the synced chart style (filled bands or classic lines).
//

import SwiftUI
import Charts

struct WatchTenDayView: View {
    @ObservedObject var model: WatchWeatherModel
    @ObservedObject private var sync = WatchSyncReceiver.shared
    @State private var showPlaces = false
    private var useF: Bool { sync.payload?.useFahrenheit ?? false }
    private var filled: Bool { (sync.payload?.chartStyle ?? "filled") != "classic" }

    /// Observed past + forecast, oldest → newest — so both charts span the same
    /// range and the first daily column is complete (full bar).
    private var allPoints: [ForecastPoint] { model.historic + model.series10d }

    /// Tight y-range covering the three temperature curves (+ small padding).
    private var tempYDomain: ClosedRange<Double> {
        let vals = allPoints.flatMap { p -> [Double] in
            useF ? [p.temperatureF, p.wetBulbF, p.dewPointF]
                 : [p.temperatureC, p.wetBulbC, p.dewPointC]
        }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.08)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    if model.series10d.isEmpty {
                        VStack { ProgressView() }
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        label("10-day")
                        tempChart.frame(height: 140)
                        label("Wind / precip")
                        windChart.frame(height: 150)
                    }
                }
                .padding(.horizontal, 4)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPlaces = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                            Text(model.placeName).lineLimit(1)
                        }
                        .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showPlaces) {
                NavigationStack { WatchPlacesView(model: model) }
            }
        }
    }

    @ViewBuilder private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var tempChart: some View {
        let base = tempYDomain.lowerBound
        Chart(allPoints) { p in
            if filled {
                AreaMark(x: .value("t", p.date), yStart: .value("base", base),
                         yEnd: .value("temp", useF ? p.temperatureF : p.temperatureC),
                         series: .value("s", "dry"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                AreaMark(x: .value("t", p.date), yStart: .value("base", base),
                         yEnd: .value("wet", useF ? p.wetBulbF : p.wetBulbC),
                         series: .value("s", "wet"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                AreaMark(x: .value("t", p.date), yStart: .value("base", base),
                         yEnd: .value("dew", useF ? p.dewPointF : p.dewPointC),
                         series: .value("s", "dew"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
            } else {
                LineMark(x: .value("t", p.date),
                         y: .value("temp", useF ? p.temperatureF : p.temperatureC),
                         series: .value("s", "dry"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                LineMark(x: .value("t", p.date),
                         y: .value("wet", useF ? p.wetBulbF : p.wetBulbC),
                         series: .value("s", "wet"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                LineMark(x: .value("t", p.date),
                         y: .value("dew", useF ? p.dewPointF : p.dewPointC),
                         series: .value("s", "dew"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
            }
        }
        .chartYScale(domain: tempYDomain)
        .chartYAxis { tempYAxis(useF: useF) }
        .chartXAxis { dailyXAxis() }
    }

    @ViewBuilder private var windChart: some View {
        Chart(allPoints) { p in
            if filled {
                AreaMark(x: .value("t", p.date), yStart: .value("base", 0),
                         yEnd: .value("gust", useF ? p.windGustMPH : p.windGustKPH),
                         series: .value("s", "gustA"))
                    .foregroundStyle(.red.opacity(0.35)).interpolationMethod(.linear)
                AreaMark(x: .value("t", p.date), yStart: .value("base", 0),
                         yEnd: .value("wind", useF ? p.windSpeedMPH : p.windSpeedKPH),
                         series: .value("s", "windA"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                AreaMark(x: .value("t", p.date), yStart: .value("base", 0),
                         yEnd: .value("precip", p.precipProbability * 100),
                         series: .value("s", "rainA"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                LineMark(x: .value("t", p.date),
                         y: .value("gust", useF ? p.windGustMPH : p.windGustKPH),
                         series: .value("s", "gustL"))
                    .foregroundStyle(.red.opacity(0.7)).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [3, 2]))
                LineMark(x: .value("t", p.date),
                         y: .value("wind", useF ? p.windSpeedMPH : p.windSpeedKPH),
                         series: .value("s", "windL"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
            } else {
                AreaMark(x: .value("t", p.date),
                         y: .value("precip", p.precipProbability * 100),
                         series: .value("s", "rainA"))
                    .foregroundStyle(Color.blue.opacity(0.3)).interpolationMethod(.linear)
                LineMark(x: .value("t", p.date),
                         y: .value("wind", useF ? p.windSpeedMPH : p.windSpeedKPH),
                         series: .value("s", "windL"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
            }
        }
        .chartYAxis { plainYAxis() }
        .chartXAxis { dailyXAxis() }
    }
}

//
//  WatchTodayView.swift
//  WetBulbCastW Watch App
//
//  24-hour screen: the temperature graph with the wind/precip graph below
//  (scroll up to reach it). Honors the synced chart style — filled area bands
//  (default) or classic lines.
//

import SwiftUI
import Charts

struct WatchTodayView: View {
    @ObservedObject var model: WatchWeatherModel
    @ObservedObject private var sync = WatchSyncReceiver.shared
    @State private var showPlaces = false
    private var useF: Bool { sync.payload?.useFahrenheit ?? false }
    private var filled: Bool { (sync.payload?.chartStyle ?? "filled") != "classic" }

    /// Tight y-range covering the three temperature curves (+ small padding).
    private var tempYDomain: ClosedRange<Double> {
        let vals = model.series24h.flatMap { p -> [Double] in
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
                VStack(spacing: 4) {
                    if model.series24h.isEmpty {
                        placeholder
                    } else {
                        tempChart.frame(height: 120)
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

    private var placeholder: some View {
        VStack(spacing: 8) {
            if model.isLoading { ProgressView() }
            if let e = model.errorText {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Loading…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    // Temperature — filled bands (green dry / blue wet / red dew) or classic
    // lines (blue temp / green wet / red dew), matching the phone's two styles.
    @ViewBuilder private var tempChart: some View {
        let base = tempYDomain.lowerBound
        Chart(model.series24h) { p in
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
        .chartXAxis { hourlyXAxis() }
    }

    // Wind/precip — filled areas with dashed gust + wind line, or classic
    // precip area + wind line.
    @ViewBuilder private var windChart: some View {
        Chart(model.series24h) { p in
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
        .chartXAxis { hourlyXAxis() }
    }
}

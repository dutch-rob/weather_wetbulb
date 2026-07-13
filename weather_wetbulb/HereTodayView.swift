//
//  HereTodayView.swift
//  weather_wetbulb
//
//  The 24-hour forecast screen: a temperature chart (dry-bulb, wet-bulb,
//  dew-point) over a precipitation/wind chart. Two visual styles, chosen in
//  Settings: "classic" line charts and "filled" area bands (with "now"
//  markers) modeled on the MyFeelsLike app.
//

import SwiftUI
import Charts

struct HereTodayView: View {
    var series: [ForecastPoint]
    /// Apple's current-conditions nowcast, drawn as prominent "now" dots in a
    /// small gap to the left of the forecast curves (filled style only).
    var current: ForecastPoint? = nil
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil

    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled

    // Axis text/grid color. WetBulbCast has no sky background, so this is just
    // the adaptive system color.
    private var axisInk: Color { .primary }

    /// Classic style: domain spans the data exactly.
    private var dateDomain: ClosedRange<Date>? {
        guard let first = series.first?.date, let last = series.last?.date else { return nil }
        return first...last
    }

    /// Filled style: domain begins ~1 h before "now" so the forecast curves sit
    /// slightly to the right, leaving a gap on the left for the current dots.
    private var filledDateDomain: ClosedRange<Date>? {
        guard let last = series.last?.date else { return nil }
        let lo: Date
        if let c = current?.date {
            lo = c.addingTimeInterval(-3600)
        } else if let first = series.first?.date {
            lo = first
        } else {
            return nil
        }
        return lo...last
    }

    /// Tight y-range covering the three temperature curves (+ the current dots),
    /// used as the explicit scale so the filled bands have a defined baseline.
    private var tempYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series + (current.map { [$0] } ?? []) {
            vals.append(useFahrenheit ? p.temperatureF : p.temperatureC)
            vals.append(useFahrenheit ? p.wetBulbF : p.wetBulbC)
            vals.append(useFahrenheit ? p.dewPointF : p.dewPointC)
        }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.08)
        return (lo - pad)...(hi + pad)
    }

    /// y-range for the precip/wind chart, anchored at 0 so the filled areas have
    /// a sensible baseline.
    private var windYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series + (current.map { [$0] } ?? []) {
            vals.append(p.precipProbability * 100)
            vals.append(useFahrenheit ? p.windGustMPH : p.windGustKPH)
            vals.append(useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH)
        }
        let hi = vals.max() ?? 1
        return 0...(hi + max(1, hi * 0.08))
    }

    private static let hourFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH"
        return df
    }()

    private func hourLabel(for date: Date) -> String {
        HereTodayView.hourFormatter.string(from: date)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ScrollView {
                if series.isEmpty {
                    ForecastLoadingView(progress: progress, nowTick: nowTick, errorMessage: errorMessage)
                        .padding()
                        .frame(minHeight: h)
                } else {
                    VStack(spacing: 8) {
                        temperatureChart(height: h * 0.55)
                        precipWindChart(height: h * 0.36)
                        if let attribution {
                            WeatherAttributionLink(info: attribution)
                        }
                    }
                    .padding(.horizontal)
                    .frame(minHeight: h)
                }
            }
            .refreshable { await onRefresh?() }
        }
    }

    @ViewBuilder
    private func temperatureChart(height: CGFloat) -> some View {
        switch chartStyle {
        case .classic: classicTemperatureChart(height: height)
        case .filled:  filledTemperatureChart(height: height)
        }
    }

    @ViewBuilder
    private func precipWindChart(height: CGFloat) -> some View {
        switch chartStyle {
        case .classic: classicPrecipWindChart(height: height)
        case .filled:  filledPrecipWindChart(height: height)
        }
    }

    // MARK: - Filled style

    @ViewBuilder
    private func filledTemperatureChart(height: CGFloat) -> some View {
        let dom = tempYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.green, "Temp",     true),
                (.blue,  "Wet Bulb", true),
                (.red,   "Dew Pt",   true)
            ], ink: axisInk)
            .padding(.leading, 36)

            Chart {
                ForEach(series) { p in
                    // Bands fill from the axis baseline up to each curve, drawn
                    // back→front (dry → wet → dew). Since dry ≥ wet ≥ dew, the
                    // opaque fronts nest into clean bands.
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                             series: .value("S", "dry"))
                        .foregroundStyle(.green).interpolationMethod(.linear)
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                             series: .value("S", "wet"))
                        .foregroundStyle(.blue).interpolationMethod(.linear)
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                             series: .value("S", "dew"))
                        .foregroundStyle(.red).interpolationMethod(.linear)
                }
                if let c = current {
                    PointMark(x: .value("Time", c.date),
                              y: .value("Temp", useFahrenheit ? c.temperatureF : c.temperatureC))
                        .foregroundStyle(.green).symbolSize(110)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Wet Bulb", useFahrenheit ? c.wetBulbF : c.wetBulbC))
                        .foregroundStyle(.blue).symbolSize(110)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Dew Point", useFahrenheit ? c.dewPointF : c.dewPointC))
                        .foregroundStyle(.red).symbolSize(110)
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: dom)
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption).foregroundStyle(axisInk)
                    }
                }
            }
            .ifLet(filledDateDomain) { view, domain in view.chartXScale(domain: domain) }
            // In-plot unit annotation so the chart area doesn't shrink.
            .overlay(alignment: .topLeading) {
                Text(useFahrenheit ? "°F" : "°C")
                    .font(.caption2)
                    .foregroundStyle(axisInk)
                    .padding(.leading, 4)
                    .padding(.top, 14)
            }
            .frame(height: height - 20)
        }
    }

    @ViewBuilder
    private func filledPrecipWindChart(height: CGFloat) -> some View {
        let dom = windYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            Chart {
                ForEach(series) { p in
                    let gust = useFahrenheit ? p.windGustMPH : p.windGustKPH
                    let wind = useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH
                    // Areas back→front: gust (translucent red) → wind (solid
                    // red) → rain (solid blue).
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Gust", gust), series: .value("S", "gustA"))
                        .foregroundStyle(.red.opacity(0.35)).interpolationMethod(.linear)
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Wind", wind), series: .value("S", "windA"))
                        .foregroundStyle(.red).interpolationMethod(.linear)
                    AreaMark(x: .value("Time", p.date),
                             yStart: .value("base", base),
                             yEnd: .value("Precip %", p.precipProbability * 100), series: .value("S", "rainA"))
                        .foregroundStyle(.blue).interpolationMethod(.linear)
                    // Gust dashed + wind solid lines, on top of the areas.
                    LineMark(x: .value("Time", p.date),
                             y: .value("Gust", gust), series: .value("S", "gustL"))
                        .foregroundStyle(.red.opacity(0.7)).interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, dash: [4, 3]))
                        .symbol(Circle()).symbolSize(0)
                    LineMark(x: .value("Time", p.date),
                             y: .value("Wind", wind), series: .value("S", "windL"))
                        .foregroundStyle(.red).interpolationMethod(.linear)
                        .symbol(Circle()).symbolSize(0)
                }
                if let c = current {
                    PointMark(x: .value("Time", c.date),
                              y: .value("Gust", useFahrenheit ? c.windGustMPH : c.windGustKPH))
                        .foregroundStyle(.red.opacity(0.45)).symbolSize(90)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Wind", useFahrenheit ? c.windSpeedMPH : c.windSpeedKPH))
                        .foregroundStyle(.red).symbolSize(90)
                }
            }
            .chartLegend(.hidden)
            // Flipped: zero at the top, so the wind/rain areas hang downward and
            // this chart shares the hour labels of the temperature chart above.
            .chartYScale(domain: [dom.upperBound, dom.lowerBound])
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis {
                // Grid lines only — hour labels are shared with the chart above.
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                }
            }
            .ifLet(filledDateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)

            ChartLegendRow(entries: [
                (.blue,            "Precip %",                              true),
                (.red,             useFahrenheit ? "Wind mph" : "Wind kph", false),
                (.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph", false)
            ], ink: axisInk)
            .padding(.leading, 36)
        }
    }

    // MARK: - Classic style (original line charts)

    @ViewBuilder
    private func classicTemperatureChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.blue,  useFahrenheit ? "Temp °F"     : "Temp °C",     false),
                (.green, useFahrenheit ? "Wet Bulb °F" : "Wet Bulb °C", false),
                (.red,   useFahrenheit ? "Dew Pt °F"   : "Dew Pt °C",   false)
            ])
            .padding(.leading, 8)

            Chart(series) { p in
                LineMark(x: .value("Time", p.date),
                         y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                         series: .value("S", "A"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                         series: .value("S", "B"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                         series: .value("S", "C"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)
        }
    }

    @ViewBuilder
    private func classicPrecipWindChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.blue, "Precip %",                               true),
                (.red,  useFahrenheit ? "Wind mph" : "Wind kph",  false)
            ])
            .padding(.leading, 8)

            Chart(series) { p in
                AreaMark(x: .value("Time", p.date),
                         y: .value("Precip %", p.precipProbability * 100))
                    .foregroundStyle(Color.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                    .symbol(Circle()).symbolSize(0)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)
        }
    }
}

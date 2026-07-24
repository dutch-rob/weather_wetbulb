//
//  HereTodayView.swift
//  weather_wetbulb
//
//  The 24-hour forecast screen: a temperature chart (dry-bulb, wet-bulb,
//  dew-point) over a precipitation/wind chart. Two visual styles, chosen in
//  Settings: "classic" line charts and "filled" area bands (with "now"
//  markers) modeled on the MyFeelsLike app. Series visibility and color
//  saturation are user-toggleable (Settings → Graphs).
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
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp)     private var graphTemp     = true
    @AppStorage(GraphKey.wetBulb)  private var graphWetBulb  = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true
    @AppStorage(GraphKey.precip)   private var graphPrecip   = true
    @AppStorage(GraphKey.wind)     private var graphWind      = true
    @AppStorage(GraphKey.gust)     private var graphGust      = true

    // Axis text/grid color. WetBulbCast has no sky background, so this is just
    // the adaptive system color.
    private var axisInk: Color { .primary }

    private var tempPanelVisible: Bool { graphTemp || graphWetBulb || graphDewPoint }
    private var windPanelVisible: Bool { graphPrecip || graphWind || graphGust }

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

    /// Tight y-range covering the visible temperature curves (+ current dots).
    private var tempYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series + (current.map { [$0] } ?? []) {
            if graphTemp     { vals.append(useFahrenheit ? p.temperatureF : p.temperatureC) }
            if graphWetBulb  { vals.append(useFahrenheit ? p.wetBulbF : p.wetBulbC) }
            if graphDewPoint { vals.append(useFahrenheit ? p.dewPointF : p.dewPointC) }
        }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.08)
        return (lo - pad)...(hi + pad)
    }

    /// y-range for the precip/wind chart, anchored at 0.
    private var windYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series + (current.map { [$0] } ?? []) {
            if graphPrecip { vals.append(p.precipProbability * 100) }
            if graphGust   { vals.append(useFahrenheit ? p.windGustMPH : p.windGustKPH) }
            if graphWind   { vals.append(useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH) }
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
                        if tempPanelVisible { temperatureChart(height: h * 0.55) }
                        if windPanelVisible { precipWindChart(height: h * 0.36) }
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

    // MARK: - Legends

    private var filledTempLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphTemp     { e.append((palette.green, "Temp",     true)) }
        if graphWetBulb  { e.append((palette.blue,  "Wet Bulb", true)) }
        if graphDewPoint { e.append((palette.red,   "Dew Pt",   true)) }
        return e
    }

    private var classicTempLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphTemp     { e.append((palette.blue,  useFahrenheit ? "Temp °F"     : "Temp °C",     false)) }
        if graphWetBulb  { e.append((palette.green, useFahrenheit ? "Wet Bulb °F" : "Wet Bulb °C", false)) }
        if graphDewPoint { e.append((palette.red,   useFahrenheit ? "Dew Pt °F"   : "Dew Pt °C",   false)) }
        return e
    }

    private var filledWindLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphPrecip { e.append((palette.blue, "Precip %", true)) }
        if graphWind   { e.append((palette.red, useFahrenheit ? "Wind mph" : "Wind kph", false)) }
        if graphGust   { e.append((palette.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph", false)) }
        return e
    }

    private var classicWindLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphPrecip { e.append((palette.blue, "Precip %", true)) }
        if graphWind   { e.append((palette.red, useFahrenheit ? "Wind mph" : "Wind kph", false)) }
        return e
    }

    // MARK: - Filled style

    @ViewBuilder
    private func filledTemperatureChart(height: CGFloat) -> some View {
        let dom = tempYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: filledTempLegend, ink: axisInk)
                .padding(.leading, 36)

            Chart {
                ForEach(series) { p in
                    // Bands fill from the axis baseline up to each curve, drawn
                    // back→front (dry → wet → dew). Since dry ≥ wet ≥ dew, the
                    // opaque fronts nest into clean bands.
                    if graphTemp {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                                 series: .value("S", "dry"))
                            .foregroundStyle(palette.green).interpolationMethod(.linear)
                    }
                    if graphWetBulb {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                                 series: .value("S", "wet"))
                            .foregroundStyle(palette.blue).interpolationMethod(.linear)
                    }
                    if graphDewPoint {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                                 series: .value("S", "dew"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                    }
                }
                if let c = current {
                    if graphTemp {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Temp", useFahrenheit ? c.temperatureF : c.temperatureC))
                            .foregroundStyle(palette.green).symbolSize(110)
                    }
                    if graphWetBulb {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Wet Bulb", useFahrenheit ? c.wetBulbF : c.wetBulbC))
                            .foregroundStyle(palette.blue).symbolSize(110)
                    }
                    if graphDewPoint {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Dew Point", useFahrenheit ? c.dewPointF : c.dewPointC))
                            .foregroundStyle(palette.red).symbolSize(110)
                    }
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
                    if graphGust {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Gust", gust), series: .value("S", "gustA"))
                            .foregroundStyle(palette.red.opacity(0.35)).interpolationMethod(.linear)
                    }
                    if graphWind {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Wind", wind), series: .value("S", "windA"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                    }
                    if graphPrecip {
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("base", base),
                                 yEnd: .value("Precip %", p.precipProbability * 100), series: .value("S", "rainA"))
                            .foregroundStyle(palette.blue).interpolationMethod(.linear)
                    }
                    if graphGust {
                        LineMark(x: .value("Time", p.date),
                                 y: .value("Gust", gust), series: .value("S", "gustL"))
                            .foregroundStyle(palette.red.opacity(0.7)).interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, dash: [4, 3]))
                            .symbol(Circle()).symbolSize(0)
                    }
                    if graphWind {
                        LineMark(x: .value("Time", p.date),
                                 y: .value("Wind", wind), series: .value("S", "windL"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                            .symbol(Circle()).symbolSize(0)
                    }
                }
                if let c = current {
                    if graphGust {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Gust", useFahrenheit ? c.windGustMPH : c.windGustKPH))
                            .foregroundStyle(palette.red.opacity(0.45)).symbolSize(90)
                    }
                    if graphWind {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Wind", useFahrenheit ? c.windSpeedMPH : c.windSpeedKPH))
                            .foregroundStyle(palette.red).symbolSize(90)
                    }
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

            ChartLegendRow(entries: filledWindLegend, ink: axisInk)
                .padding(.leading, 36)
        }
    }

    // MARK: - Classic style (original line charts)

    @ViewBuilder
    private func classicTemperatureChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: classicTempLegend)
                .padding(.leading, 8)

            Chart(series) { p in
                if graphTemp {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                             series: .value("S", "A"))
                        .foregroundStyle(palette.blue).interpolationMethod(.linear)
                }
                if graphWetBulb {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                             series: .value("S", "B"))
                        .foregroundStyle(palette.green).interpolationMethod(.linear)
                }
                if graphDewPoint {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                             series: .value("S", "C"))
                        .foregroundStyle(palette.red).interpolationMethod(.linear)
                }
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
            ChartLegendRow(entries: classicWindLegend)
                .padding(.leading, 8)

            Chart(series) { p in
                if graphPrecip {
                    AreaMark(x: .value("Time", p.date),
                             y: .value("Precip %", p.precipProbability * 100))
                        .foregroundStyle(palette.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                }
                if graphWind {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH))
                        .foregroundStyle(palette.red).interpolationMethod(.linear)
                        .symbol(Circle()).symbolSize(0)
                }
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

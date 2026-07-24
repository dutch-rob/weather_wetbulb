//
//  TenDayView.swift
//  weather_wetbulb
//
//  The 10-day forecast screen: a temperature chart (dry-bulb, wet-bulb,
//  dew-point) over a precipitation/wind chart, sharing day labels. Two visual
//  styles chosen in Settings: "classic" line charts and "filled" area bands
//  modeled on the MyFeelsLike app. Series visibility and color saturation are
//  user-toggleable (Settings → Graphs).
//

import SwiftUI
import Charts

struct TenDayView: View {
    var series: [ForecastPoint]
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

    private var axisInk: Color { .primary }

    private var tempPanelVisible: Bool { graphTemp || graphWetBulb || graphDewPoint }
    private var windPanelVisible: Bool { graphPrecip || graphWind || graphGust }

    private var dateDomain: ClosedRange<Date>? {
        guard let first = series.first?.date, let last = series.last?.date else { return nil }
        return first...last
    }

    private var tempYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series {
            if graphTemp     { vals.append(useFahrenheit ? p.temperatureF : p.temperatureC) }
            if graphWetBulb  { vals.append(useFahrenheit ? p.wetBulbF : p.wetBulbC) }
            if graphDewPoint { vals.append(useFahrenheit ? p.dewPointF : p.dewPointC) }
        }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.08)
        return (lo - pad)...(hi + pad)
    }

    private var windYDomain: ClosedRange<Double> {
        var vals: [Double] = []
        for p in series {
            if graphPrecip { vals.append(p.precipProbability * 100) }
            if graphGust   { vals.append(useFahrenheit ? p.windGustMPH : p.windGustKPH) }
            if graphWind   { vals.append(useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH) }
        }
        let hi = vals.max() ?? 1
        return 0...(hi + max(1, hi * 0.08))
    }

    private var startMidnight: Date? {
        guard let first = series.first?.date else { return nil }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: first)
        return first > midnight ? cal.date(byAdding: .day, value: 1, to: midnight) : midnight
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE"
        return df
    }()

    private static let dayAbbreviations = [
        "Mon": "Mo", "Tue": "Tu", "Wed": "We",
        "Thu": "Th", "Fri": "Fr", "Sat": "Sa", "Sun": "Su"
    ]

    private func dayLabel(for date: Date) -> String {
        guard let start = startMidnight, date >= start,
              Calendar.current.component(.hour, from: date) == 0 else { return "" }
        let key = TenDayView.dayFormatter.string(from: date)
        return TenDayView.dayAbbreviations[key] ?? String(key.prefix(2))
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

            Chart(series) { p in
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
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
                            .font(.caption).foregroundStyle(axisInk)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
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
            Chart(series) { p in
                let gust = useFahrenheit ? p.windGustMPH : p.windGustKPH
                let wind = useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH
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
            .chartLegend(.hidden)
            .chartYScale(domain: [dom.upperBound, dom.lowerBound])
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
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
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
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
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)
        }
    }
}

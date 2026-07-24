//
//  FoldTimelineView.swift
//  weather_wetbulb
//
//  Optional "fold timeline" (Settings → Experimental). Instead of paging
//  between a 24-hour screen and a 10-day screen, one continuous timeline morphs
//  between them: a horizontal swipe drives a progress value 0…1 and the
//  temperature + precip/wind charts zoom their x-axis from a single day out to
//  the whole forecast. Honors the same graph options and the long-press
//  scrubber as the paged screens.
//

import SwiftUI
import Charts

struct FoldTimelineView: View {
    var series: [ForecastPoint]          // 10-day
    var current: ForecastPoint? = nil
    var progressLoad: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil

    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = true
    @AppStorage(SettingsKey.use12HourClock) private var use12Hour = false
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp)     private var graphTemp     = true
    @AppStorage(GraphKey.wetBulb)  private var graphWetBulb  = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true
    @AppStorage(GraphKey.feels)    private var graphFeels     = true
    @AppStorage(GraphKey.precip)   private var graphPrecip   = true
    @AppStorage(GraphKey.wind)     private var graphWind      = true
    @AppStorage(GraphKey.gust)     private var graphGust      = true

    /// 0 = 24-hour view, 1 = 10-day view.
    @State private var progress: Double = 0
    @State private var dragBase: Double? = nil
    @State private var scrubDate: Date? = nil

    private var axisInk: Color { .primary }
    private var tempPanelVisible: Bool { graphTemp || graphWetBulb || graphDewPoint || graphFeels }
    private var windPanelVisible: Bool { graphPrecip || graphWind || graphGust }

    // MARK: - Interpolated time domain

    private var narrowLo: Date { current?.date ?? series.first?.date ?? nowTick }
    private var narrowHi: Date { narrowLo.addingTimeInterval(24 * 3600) }
    private var fullLo: Date { series.first?.date ?? narrowLo }
    private var fullHi: Date { series.last?.date ?? narrowHi }

    private func lerpDate(_ a: Date, _ b: Date, _ t: Double) -> Date {
        Date(timeIntervalSinceReferenceDate:
                a.timeIntervalSinceReferenceDate
                + (b.timeIntervalSinceReferenceDate - a.timeIntervalSinceReferenceDate) * t)
    }
    private var visLo: Date { lerpDate(narrowLo, fullLo, progress) }
    private var visHi: Date { lerpDate(narrowHi, fullHi, progress) }
    private var visDomain: ClosedRange<Date> { visLo...max(visLo.addingTimeInterval(3600), visHi) }
    private var visSpanHours: Double { visDomain.upperBound.timeIntervalSince(visDomain.lowerBound) / 3600 }

    // MARK: - Y ranges (over all data, stable while zooming)

    private var tempYDomain: ClosedRange<Double> {
        var v: [Double] = []
        for p in series {
            if graphTemp     { v.append(useFahrenheit ? p.temperatureF : p.temperatureC) }
            if graphWetBulb  { v.append(useFahrenheit ? p.wetBulbF : p.wetBulbC) }
            if graphDewPoint { v.append(useFahrenheit ? p.dewPointF : p.dewPointC) }
            if graphFeels    { v.append(useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC) }
        }
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.08)
        return (lo - pad)...(hi + pad)
    }
    private var windYDomain: ClosedRange<Double> {
        var v: [Double] = []
        for p in series {
            if graphPrecip { v.append(p.precipProbability * 100) }
            if graphGust   { v.append(useFahrenheit ? p.windGustMPH : p.windGustKPH) }
            if graphWind   { v.append(useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH) }
        }
        let hi = v.max() ?? 1
        return 0...(hi + max(1, hi * 0.08))
    }

    // MARK: - Legends

    private var tempLegend: [(color: Color, label: String, isArea: Bool)] {
        let area = chartStyle == .filled
        var e: [(Color, String, Bool)] = []
        if graphFeels    { e.append((palette.purple, "Feels like", false)) }
        if graphTemp     { e.append((area ? palette.green : palette.blue,  "Temp",     area)) }
        if graphWetBulb  { e.append((area ? palette.blue  : palette.green, "Wet Bulb", area)) }
        if graphDewPoint { e.append((palette.red, "Dew Pt", area)) }
        return e
    }
    private var windLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphPrecip { e.append((palette.blue, "Precip %", true)) }
        if graphWind   { e.append((palette.red, useFahrenheit ? "Wind mph" : "Wind kph", false)) }
        if graphGust   { e.append((palette.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph", false)) }
        return e
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            if series.isEmpty {
                ForecastLoadingView(progress: progressLoad, nowTick: nowTick, errorMessage: errorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let avail = max(220, h - 40)
                VStack(spacing: 8) {
                    modeIndicator
                    if tempPanelVisible { temperatureChart(height: avail * 0.55) }
                    if windPanelVisible { precipWindChart(height: avail * 0.36) }
                    if let attribution { WeatherAttributionLink(info: attribution) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .gesture(foldDrag(width: geo.size.width))
            }
        }
    }

    /// Swipe hint showing which end of the morph is active.
    private var modeIndicator: some View {
        HStack(spacing: 8) {
            Text("24-hour").fontWeight(progress < 0.5 ? .semibold : .regular)
                .foregroundStyle(progress < 0.5 ? axisInk : axisInk.opacity(0.5))
            Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(axisInk.opacity(0.5))
            Text("10-day").fontWeight(progress >= 0.5 ? .semibold : .regular)
                .foregroundStyle(progress >= 0.5 ? axisInk : axisInk.opacity(0.5))
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    private func foldDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard scrubDate == nil else { return }                 // scrubbing: don't morph
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragBase == nil { dragBase = progress }
                let span = max(1, width * 0.7)
                progress = min(1, max(0, (dragBase ?? progress) - v.translation.width / span))
            }
            .onEnded { v in
                guard scrubDate == nil else { return }
                let span = max(1, width * 0.7)
                let projected = min(1, max(0, (dragBase ?? progress) - v.predictedEndTranslation.width / span))
                withAnimation(.easeOut(duration: 0.3)) { progress = projected > 0.5 ? 1 : 0 }
                dragBase = nil
            }
    }

    // MARK: - X axis (adaptive: hours when zoomed in, days when zoomed out)

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()

    @AxisContentBuilder
    private func foldXAxis() -> some AxisContent {
        if visSpanHours < 60 {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                AxisTick().foregroundStyle(axisInk.opacity(0.6))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(clockHourLabel(Calendar.current.component(.hour, from: d), use12: use12Hour))
                            .font(.caption).foregroundStyle(axisInk)
                    }
                }
            }
        } else {
            AxisMarks(values: .stride(by: .day, count: 1)) { value in
                AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                AxisTick().foregroundStyle(axisInk.opacity(0.6))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(String(FoldTimelineView.dayFmt.string(from: d).prefix(2)))
                            .font(.caption).foregroundStyle(axisInk)
                    }
                }
            }
        }
    }

    // MARK: - Temperature chart

    @ViewBuilder
    private func temperatureChart(height: CGFloat) -> some View {
        let dom = tempYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: tempLegend, ink: axisInk).padding(.leading, 36)
            Chart(series) { p in
                if chartStyle == .filled {
                    if graphTemp {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base),
                                 yEnd: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC), series: .value("s", "dry"))
                            .foregroundStyle(palette.green).interpolationMethod(.linear)
                    }
                    if graphWetBulb {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base),
                                 yEnd: .value("Wet", useFahrenheit ? p.wetBulbF : p.wetBulbC), series: .value("s", "wet"))
                            .foregroundStyle(palette.blue).interpolationMethod(.linear)
                    }
                    if graphDewPoint {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base),
                                 yEnd: .value("Dew", useFahrenheit ? p.dewPointF : p.dewPointC), series: .value("s", "dew"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                    }
                } else {
                    if graphTemp {
                        LineMark(x: .value("Time", p.date), y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC), series: .value("s", "dry"))
                            .foregroundStyle(palette.blue).interpolationMethod(.linear)
                    }
                    if graphWetBulb {
                        LineMark(x: .value("Time", p.date), y: .value("Wet", useFahrenheit ? p.wetBulbF : p.wetBulbC), series: .value("s", "wet"))
                            .foregroundStyle(palette.green).interpolationMethod(.linear)
                    }
                    if graphDewPoint {
                        LineMark(x: .value("Time", p.date), y: .value("Dew", useFahrenheit ? p.dewPointF : p.dewPointC), series: .value("s", "dew"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                    }
                }
                if graphFeels {
                    LineMark(x: .value("Time", p.date), y: .value("Feels", useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC), series: .value("s", "app"))
                        .foregroundStyle(palette.purple).interpolationMethod(.linear).lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: dom)
            .chartXScale(domain: visDomain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis { foldXAxis() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            .overlay(alignment: .topLeading) {
                Text(useFahrenheit ? "°F" : "°C").font(.caption2).foregroundStyle(axisInk)
                    .padding(.leading, 4).padding(.top, 14)
            }
            .overlay(alignment: scrubFraction < 0.5 ? .topTrailing : .topLeading) { scrubReadoutHUD }
            .frame(height: height - 20)
        }
    }

    // MARK: - Precip / wind chart

    @ViewBuilder
    private func precipWindChart(height: CGFloat) -> some View {
        let dom = windYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            Chart(series) { p in
                let gust = useFahrenheit ? p.windGustMPH : p.windGustKPH
                let wind = useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH
                if chartStyle == .filled {
                    if graphGust {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base), yEnd: .value("Gust", gust), series: .value("s", "gA"))
                            .foregroundStyle(palette.red.opacity(0.35)).interpolationMethod(.linear)
                    }
                    if graphWind {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base), yEnd: .value("Wind", wind), series: .value("s", "wA"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear)
                    }
                    if graphPrecip {
                        AreaMark(x: .value("Time", p.date), yStart: .value("b", base), yEnd: .value("Precip", p.precipProbability * 100), series: .value("s", "rA"))
                            .foregroundStyle(palette.blue).interpolationMethod(.linear)
                    }
                    if graphGust {
                        LineMark(x: .value("Time", p.date), y: .value("Gust", gust), series: .value("s", "gL"))
                            .foregroundStyle(palette.red.opacity(0.7)).interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, dash: [4, 3])).symbol(Circle()).symbolSize(0)
                    }
                    if graphWind {
                        LineMark(x: .value("Time", p.date), y: .value("Wind", wind), series: .value("s", "wL"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear).symbol(Circle()).symbolSize(0)
                    }
                } else {
                    if graphPrecip {
                        AreaMark(x: .value("Time", p.date), y: .value("Precip", p.precipProbability * 100))
                            .foregroundStyle(palette.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                    }
                    if graphGust {
                        LineMark(x: .value("Time", p.date), y: .value("Gust", gust), series: .value("s", "gL"))
                            .foregroundStyle(palette.red.opacity(0.6)).interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3])).symbol(Circle()).symbolSize(0)
                    }
                    if graphWind {
                        LineMark(x: .value("Time", p.date), y: .value("Wind", wind), series: .value("s", "wL"))
                            .foregroundStyle(palette.red).interpolationMethod(.linear).symbol(Circle()).symbolSize(0)
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: visDomain)
            .chartYScale(domain: chartStyle == .filled ? [dom.upperBound, dom.lowerBound] : [dom.lowerBound, dom.upperBound])
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis { foldXAxis() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            .frame(height: height - 20)

            ChartLegendRow(entries: windLegend, ink: axisInk).padding(.leading, 36)
        }
    }

    // MARK: - Scrubbing

    private var scrubPoint: ForecastPoint? {
        guard let t = scrubDate else { return nil }
        return nearestForecastPoint(to: t, in: series)
    }
    private var scrubFraction: Double {
        guard let t = scrubDate else { return 0.5 }
        let total = visDomain.upperBound.timeIntervalSince(visDomain.lowerBound)
        guard total > 0 else { return 0.5 }
        return min(1, max(0, t.timeIntervalSince(visDomain.lowerBound) / total))
    }
    private func scrubTimeText(_ date: Date) -> String {
        let wd = FoldTimelineView.dayFmt.string(from: date)
        let h = Calendar.current.component(.hour, from: date)
        let hm: String
        if use12Hour {
            if h == 0 { hm = "12 am" } else if h == 12 { hm = "noon" } else { hm = h < 12 ? "\(h) am" : "\(h - 12) pm" }
        } else { hm = String(format: "%02d:00", h) }
        return "\(wd) \(hm)"
    }
    private func updateScrub(atX xLocation: CGFloat, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let x = xLocation - geo[plotFrame].origin.x
        guard let date = proxy.value(atX: x, as: Date.self) else { return }
        scrubDate = nearestForecastPoint(to: date, in: series)?.date
    }
    @ViewBuilder
    private func scrubOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let t = scrubDate, let plotFrame = proxy.plotFrame, let x = proxy.position(forX: t) {
                    let plot = geo[plotFrame]
                    Path { p in
                        p.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                        p.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                    }
                    .stroke(axisInk.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                LongPressLocator { loc, state in
                    if state == .began || state == .changed { updateScrub(atX: loc.x, proxy: proxy, geo: geo) }
                }
            }
        }
    }
    @ViewBuilder
    private var scrubReadoutHUD: some View {
        if let p = scrubPoint {
            ScrubReadoutCard(point: p, timeText: scrubTimeText(p.date), useFahrenheit: useFahrenheit) { scrubDate = nil }
                .padding(.top, 6).padding(.horizontal, 6).transition(.opacity)
        }
    }
}

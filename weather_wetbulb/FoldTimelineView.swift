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
    /// Left edge of the visible window, as an offset from "now". Shared with
    /// ContentView so the table and the graph stay on the same moment; it
    /// starts an hour early so the current-time markers are not clipped by the
    /// plot edge.
    @Binding var startOffset: TimeInterval
    var current: ForecastPoint? = nil
    var progressLoad: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Vertical swipe asks for the table screen (only wired up when the table
    /// is enabled in Settings). Pinch now owns zooming, which frees this up.
    var onShowTable: (() -> Void)? = nil

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

    /// Zoom level: 0 = a 24-hour window, 1 = the whole -10d…+10d series.
    /// Not snapped, so any intermediate zoom is a valid resting place.
    @State private var zoom: Double = 0
    @State private var panBase: TimeInterval? = nil
    @State private var zoomBase: Double? = nil
    /// Time held fixed at the centre while zooming.
    @State private var zoomAnchor: Date? = nil
    @State private var dragAxis: DragAxis? = nil
    @State private var scrubDate: Date? = nil

    private enum DragAxis { case horizontal, vertical }

    private var axisInk: Color { .primary }
    private var tempPanelVisible: Bool { graphTemp || graphWetBulb || graphDewPoint || graphFeels }
    private var windPanelVisible: Bool { graphPrecip || graphWind || graphGust }

    // MARK: - Interpolated time domain

    private var dataLo: Date { series.first?.date ?? nowTick }
    private var dataHi: Date { series.last?.date ?? nowTick.addingTimeInterval(24 * 3600) }
    /// Widest window: ten days, or less if that is all the data we have.
    private var fullSpan: TimeInterval {
        min(240 * 3600, max(24 * 3600, dataHi.timeIntervalSince(dataLo)))
    }
    private static let minSpan: TimeInterval = 24 * 3600
    /// Visible span, interpolated by the zoom level.
    private var span: TimeInterval { 24 * 3600 + (fullSpan - 24 * 3600) * zoom }

    private func clampStart(_ o: TimeInterval) -> TimeInterval {
        TimelineScroll.clampStartOffset(o, span: span, now: nowTick,
                                        dataLo: dataLo, dataHi: dataHi)
    }
    /// Forecast point closest to "now", drawn as prominent dots so the current
    /// moment is obvious at any zoom level.
    private var nowPoint: ForecastPoint? {
        guard let p = nearestForecastPoint(to: nowTick, in: series) else { return nil }
        return abs(p.date.timeIntervalSince(nowTick)) <= 3600 ? p : nil
    }

    /// True for ticks hard against either edge of the window, where the label
    /// would be half outside the plot and get ellipsised to "…".
    private func tickTooCloseToEdge(_ d: Date, plotWidth: CGFloat) -> Bool {
        // Only ticks essentially on the edge: the label sizes itself
        // (fixedSize) so it no longer needs half its width of clearance.
        let usable = max(1, Double(plotWidth) - 56)
        let margin = span * (12.0 / usable)
        return d.timeIntervalSince(visLo) < margin || visHi.timeIntervalSince(d) < margin
    }

    private var visLo: Date { nowTick.addingTimeInterval(clampStart(startOffset)) }
    private var visHi: Date { visLo.addingTimeInterval(span) }
    private var visDomain: ClosedRange<Date> { visLo...max(visLo.addingTimeInterval(3600), visHi) }
    private var visSpanHours: Double { visDomain.upperBound.timeIntervalSince(visDomain.lowerBound) / 3600 }

    // MARK: - Y ranges

    /// Points inside the visible window. The y-ranges are computed from these
    /// rather than the whole ±10 days: scaling to data that is off-screen left
    /// the charts using only part of their height (a distant 45 mph gust made
    /// the wind panel reserve room for it while showing an 18 mph day).
    private var visibleSeries: [ForecastPoint] {
        let lo = visLo.addingTimeInterval(-2 * 3600)
        let hi = visHi.addingTimeInterval(2 * 3600)
        let inWindow = series.filter { $0.date >= lo && $0.date <= hi }
        return inWindow.isEmpty ? series : inWindow
    }

    private var tempYDomain: ClosedRange<Double> {
        var v: [Double] = []
        for p in visibleSeries {
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
        for p in visibleSeries {
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
                // Height left for the charts once the fixed chrome (span
                // indicator, the two legends, the attribution link and the
                // stack spacing) is accounted for, so they fill the screen
                // instead of leaving a gap at the bottom.
                let chrome: CGFloat = 22 + 16 + 18 + 16   // measured against the rendered screen
                let avail = max(200, h - chrome)
                VStack(spacing: 8) {
                    modeIndicator
                    if tempPanelVisible { temperatureChart(height: avail * 0.60, width: geo.size.width) }
                    if windPanelVisible { precipWindChart(height: avail * 0.40, width: geo.size.width) }
                    if let attribution { WeatherAttributionLink(info: attribution) }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .gesture(foldDrag(size: geo.size).simultaneously(with: foldMagnify()))
            }
        }
    }

    /// Shows how wide the window is and where it starts — the fold has no
    /// discrete modes any more, so a label beats a two-ended indicator.
    private var modeIndicator: some View {
        let hours = span / 3600
        let spanText = hours < 48
            ? "\(Int(hours.rounded())) hours"
            : "\(Int((hours / 24).rounded())) days"
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEd MMM")
        return HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right").font(.caption2)
                .foregroundStyle(axisInk.opacity(0.5))
            Text(spanText).fontWeight(.semibold)
            Text("from \(f.string(from: visLo))").foregroundStyle(axisInk.opacity(0.6))
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    /// Horizontal drag pans through time; a vertical drag asks for the table.
    /// Zooming is a pinch (below), which is the gesture people expect.
    private func foldDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard scrubDate == nil else { return }          // scrubbing wins
                if dragAxis == nil {
                    dragAxis = abs(v.translation.width) >= abs(v.translation.height)
                        ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                if panBase == nil { panBase = startOffset }
                let dt = -Double(v.translation.width) / Double(max(1, size.width)) * span
                startOffset = clampStart((panBase ?? startOffset) + dt)
            }
            .onEnded { v in
                defer { dragAxis = nil; panBase = nil }
                if dragAxis == .vertical, abs(v.translation.height) > 40 {
                    onShowTable?()
                }
            }
    }

    /// Pinch to zoom, anchored on the middle of the window so the view does not
    /// slide sideways while zooming. Nothing snaps: any span is a resting place.
    private func foldMagnify() -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { v in
                guard scrubDate == nil else { return }
                if zoomBase == nil {
                    zoomBase = zoom
                    zoomAnchor = visLo.addingTimeInterval(span / 2)
                }
                let range = max(1, fullSpan - Self.minSpan)
                let baseSpan = Self.minSpan + range * (zoomBase ?? zoom)
                // Pinch out (magnification > 1) shows less time = zoom in.
                let wanted = baseSpan / max(0.05, v.magnification)
                let clamped = min(fullSpan, max(Self.minSpan, wanted))
                zoom = (clamped - Self.minSpan) / range
                if let c = zoomAnchor {
                    startOffset = clampStart(c.addingTimeInterval(-span / 2)
                                                .timeIntervalSince(nowTick))
                }
            }
            .onEnded { _ in zoomBase = nil; zoomAnchor = nil }
    }

    // MARK: - X axis (adaptive: hours when zoomed in, days when zoomed out)

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()

    @AxisContentBuilder
    private func foldXAxis(width: CGFloat) -> some AxisContent {
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
                    if let d = value.as(Date.self),
                       !tickTooCloseToEdge(d, plotWidth: width) {
                        Text(dayTickLabel(d, includeWeekday: dayAxisFitsWeekday(
                                plotWidth: width, days: visSpanHours / 24)))
                            .font(.caption).foregroundStyle(axisInk)
                            .fixedSize()          // never ellipsise to "…"
                    }
                }
            }
        }
    }

    // MARK: - Temperature chart

    @ViewBuilder
    private func temperatureChart(height: CGFloat, width: CGFloat) -> some View {
        let dom = tempYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: tempLegend, ink: axisInk).padding(.leading, 36)
            Chart {
                ForEach(series) { p in
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
                // Solid dots at the current time, so "now" stays obvious at any
                // zoom level and wherever the window has been scrolled to.
                if let n = nowPoint {
                    if graphTemp {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Temp", useFahrenheit ? n.temperatureF : n.temperatureC))
                            .symbol { NowMarkerSymbol(color: chartStyle == .filled ? palette.green : palette.blue) }
                    }
                    if graphWetBulb {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Wet", useFahrenheit ? n.wetBulbF : n.wetBulbC))
                            .symbol { NowMarkerSymbol(color: chartStyle == .filled ? palette.blue : palette.green) }
                    }
                    if graphDewPoint {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Dew", useFahrenheit ? n.dewPointF : n.dewPointC))
                            .symbol { NowMarkerSymbol(color: palette.red) }
                    }
                    if graphFeels {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Feels", useFahrenheit ? n.apparentTemperatureF : n.apparentTemperatureC))
                            .symbol { NowMarkerSymbol(color: palette.purple) }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: dom)
            .chartXScale(domain: visDomain)
            .chartPlotStyle { $0.clipped() }
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis { foldXAxis(width: width) }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            // Trailing side: on the leading side it collides with a three-digit
            // top y-axis label (e.g. 100 °F).
            .overlay(alignment: .topTrailing) {
                Text(useFahrenheit ? "°F" : "°C").font(.caption2).foregroundStyle(axisInk)
                    .padding(.trailing, 6).padding(.top, 2)
            }
            .overlay(alignment: scrubFraction < 0.5 ? .topTrailing : .topLeading) { scrubReadoutHUD }
            .frame(height: height - 20)
        }
    }

    // MARK: - Precip / wind chart

    @ViewBuilder
    private func precipWindChart(height: CGFloat, width: CGFloat) -> some View {
        let dom = windYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            Chart {
                ForEach(series) { p in
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
                if let n = nowPoint {
                    if graphWind {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Wind", useFahrenheit ? n.windSpeedMPH : n.windSpeedKPH))
                            .symbol { NowMarkerSymbol(color: palette.red) }
                    }
                    if graphPrecip {
                        PointMark(x: .value("Time", n.date),
                                  y: .value("Precip", n.precipProbability * 100))
                            .symbol { NowMarkerSymbol(color: palette.blue) }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: visDomain)
            .chartPlotStyle { $0.clipped() }
            .chartYScale(domain: chartStyle == .filled ? [dom.upperBound, dom.lowerBound] : [dom.lowerBound, dom.upperBound])
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis { foldXAxis(width: width) }
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

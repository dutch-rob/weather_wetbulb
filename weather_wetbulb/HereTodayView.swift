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
    var allSeries: [ForecastPoint]

    /// Left edge of the visible time window. nil = show the whole `allSeries`
    /// (the pre-scrolling behaviour). When set, the charts pan over the full
    /// -10d ... +10d series instead of showing a fixed forecast slice.
    var windowStart: Date? = nil
    /// How much time the window covers.
    var windowSpan: TimeInterval = 24 * 3600

    /// The window as a range, if scrolling is active.
    private var visibleRange: ClosedRange<Date>? {
        guard let s = windowStart else { return nil }
        // A sliver of lead-in, proportional to the window, so the "now" rings sit
        // inside the plot instead of being clipped in half by its left edge. A
        // fixed hour was invisible on the 10-day scale (0.4% of the width).
        return s.addingTimeInterval(-windowSpan * 0.03)...s.addingTimeInterval(windowSpan)
    }

    /// Points inside the window (padded slightly so curves reach both edges).
    /// Everything below draws from this, so the y-axis and the scrubber follow
    /// whatever is on screen.
    private var series: [ForecastPoint] {
        guard let r = visibleRange else { return allSeries }
        let lo = r.lowerBound.addingTimeInterval(-2 * 3600)
        let hi = r.upperBound.addingTimeInterval(2 * 3600)
        return allSeries.filter { $0.date >= lo && $0.date <= hi }
    }
    /// Apple's current-conditions nowcast, drawn as prominent "now" dots in a
    /// small gap to the left of the forecast curves (filled style only).
    var current: ForecastPoint? = nil
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil

    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.use12HourClock) private var use12Hour = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp)     private var graphTemp     = true
    @AppStorage(GraphKey.wetBulb)  private var graphWetBulb  = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true
    @AppStorage(GraphKey.feels)    private var graphFeels     = true
    @AppStorage(GraphKey.precip)   private var graphPrecip   = true
    @AppStorage(GraphKey.wind)     private var graphWind      = true
    @AppStorage(GraphKey.gust)     private var graphGust      = true

    /// Time the user is scrubbing to (long-press on a chart). nil = not scrubbing.
    @State private var scrubDate: Date? = nil

    private var axisInk: Color { .primary }

    /// The system clock-and-wifi corner, in global coordinates. Empty when
    /// nothing is in the way. The graph spreads under it rather than stopping
    /// short of it, and keeps its curve below it instead — see
    /// `StatusCornerClearance`.
    var statusCorner: CGRect = .zero

    /// Use the landscape arrangement even in a nominally regular height. Set
    /// when the device is propped open on a table and only its top half is in
    /// view: that half is wider than it is tall, whatever the size class says
    /// about the panel as a whole.
    var forceLandscapeLayout: Bool = false

    /// Side by side rather than stacked. Stacked in a short panel the two
    /// charts get a strip each and neither can be read; side by side they each
    /// keep the full height and give up width, which they have to spare.
    private var landscapeLayout: Bool { verticalSizeClass == .compact || forceLandscapeLayout }

    /// Height kept above a plot for its legend. `ChartLegendRow` folds onto a
    /// second line rather than wrap mid-word, and at half the width it always
    /// does — reserving one line's worth pushed the attribution off the foot
    /// of the screen, where the pane clipped it.
    private var legendReserve: CGFloat { landscapeLayout ? 38 : 20 }

    /// Hours between labelled ticks. Side by side each chart has half the
    /// width, and a label every two hours collapses into a row of ellipses.
    /// Three rather than four: four leaves the first label most of a morning
    /// in from the axis, which reads as a missing label.
    private var hourStride: Int { landscapeLayout ? 3 : 2 }

    /// Roughly where a chart's plot sits inside the frame it is given: below
    /// its legend, above its hour labels, right of its y-axis labels. The
    /// legend is free to pass under the clock — it is short, and it hugs the
    /// leading edge — so it is the plot, not the frame, that has to clear it.
    private func plotRect(in frame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: frame.minX + 36,
               y: frame.minY + 20,
               width: max(1, frame.width - 36),
               height: max(1, height - 40))
    }

    /// Points to give back to the system strip when the ceiling could not be
    /// raised far enough: the graph goes back to stopping short of it.
    private func standOffWidth(_ corner: StatusCorner,
                               ceiling: Double?,
                               width: CGFloat) -> CGFloat {
        guard !corner.isEmpty, ceiling == nil else { return 0 }
        return width * CGFloat(corner.width)
    }

    /// Highest temperature plotted in the hours that pass under the corner.
    private func peakUnder(_ corner: StatusCorner) -> Double? {
        guard !corner.isEmpty, let domain = filledDateDomain else { return nil }
        let start = domain.lowerBound.timeIntervalSinceReferenceDate
        let end = domain.upperBound.timeIntervalSinceReferenceDate
        guard end > start else { return nil }
        let from = start + (end - start) * corner.startFraction
        let to = start + (end - start) * corner.endFraction
        var peak: Double?
        for p in series {
            let t = p.date.timeIntervalSinceReferenceDate
            guard t >= from, t <= to else { continue }
            var vals: [Double] = []
            if graphTemp     { vals.append(useFahrenheit ? p.temperatureF : p.temperatureC) }
            if graphWetBulb  { vals.append(useFahrenheit ? p.wetBulbF : p.wetBulbC) }
            if graphDewPoint { vals.append(useFahrenheit ? p.dewPointF : p.dewPointC) }
            if graphFeels    { vals.append(useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC) }
            if let hi = vals.max() { peak = max(peak ?? -.infinity, hi) }
        }
        return peak
    }

    private var tempPanelVisible: Bool { graphTemp || graphWetBulb || graphDewPoint || graphFeels }
    private var windPanelVisible: Bool { graphPrecip || graphWind || graphGust }

    /// Classic style: domain spans the data exactly.
    private var dateDomain: ClosedRange<Date>? {
        if let r = visibleRange { return r }
        guard let first = series.first?.date, let last = series.last?.date else { return nil }
        return first...last
    }

    /// Filled style: domain begins ~1 h before "now" so the forecast curves sit
    /// slightly to the right, leaving a gap on the left for the current dots.
    private var filledDateDomain: ClosedRange<Date>? {
        if let r = visibleRange { return r }
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
            if graphFeels    { vals.append(useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC) }
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

    private func hourLabel(for date: Date) -> String {
        clockHourLabel(Calendar.current.component(.hour, from: date), use12: use12Hour)
    }

    // MARK: - Scrubbing

    private var scrubPoint: ForecastPoint? {
        guard let t = scrubDate else { return nil }
        return nearestForecastPoint(to: t, in: series)
    }

    private var scrubFraction: Double {
        guard let t = scrubDate, let dom = filledDateDomain else { return 0.5 }
        let total = dom.upperBound.timeIntervalSince(dom.lowerBound)
        guard total > 0 else { return 0.5 }
        return min(1, max(0, t.timeIntervalSince(dom.lowerBound) / total))
    }

    private func scrubTimeText(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        if use12Hour {
            if h == 0 { return "12 am" }
            if h == 12 { return "noon" }
            return h < 12 ? "\(h) am" : "\(h - 12) pm"
        }
        return String(format: "%02d:00", h)
    }

    private func updateScrub(atX xLocation: CGFloat, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let x = xLocation - geo[plotFrame].origin.x
        guard let date = proxy.value(atX: x, as: Date.self) else { return }
        scrubDate = nearestForecastPoint(to: date, in: series)?.date
    }

    /// Draws the dashed scrub line at the current time and hosts the long-press
    /// (to drop/move it) + a drag layer (active only while scrubbing). Added as
    /// a chartOverlay so it works identically in both chart styles.
    @ViewBuilder
    private func scrubOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let t = scrubDate, let plotFrame = proxy.plotFrame,
                   let x = proxy.position(forX: t) {
                    let plot = geo[plotFrame]
                    Path { p in
                        p.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                        p.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                    }
                    .stroke(axisInk.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                // The long-press is continuous: after it begins it keeps
                // reporting .changed as the finger moves, so this one gesture
                // both drops and drags the scrub line.
                LongPressLocator(onEvent: { loc, state in
                    if state == .began || state == .changed {
                        updateScrub(atX: loc.x, proxy: proxy, geo: geo)
                    }
                }, onTap: { scrubDate = nil })
            }
        }
    }

    /// The readout card HUD, placed opposite the scrub line so the graph under
    /// the line stays visible.
    @ViewBuilder
    private var scrubReadoutHUD: some View {
        if let p = scrubPoint {
            ScrubReadoutCard(point: p, timeText: scrubTimeText(p.date),
                             useFahrenheit: useFahrenheit) { scrubDate = nil }
                .padding(.top, 6).padding(.horizontal, 6)
                .transition(.opacity)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // Deliberately not a ScrollView: the content is sized to the screen,
            // and a scroll view would swallow the vertical drag that now
            // switches screens.
            Group {
                if series.isEmpty {
                    ForecastLoadingView(progress: progress, nowTick: nowTick, errorMessage: errorMessage)
                        .padding()
                        .frame(minHeight: h)
                } else if landscapeLayout {
                    // Side by side, each chart the full height of the panel.
                    // The wind chart is stood the right way up here: hanging
                    // from zero only makes sense directly under the
                    // temperature chart, where the two share one set of hour
                    // labels. On its own it needs its own axis at its foot.
                    let chrome: CGFloat = 18 + 6
                    let chartH = max(120, h - chrome)
                    VStack(spacing: 4) {
                        HStack(spacing: 12) {
                            if tempPanelVisible { temperatureChart(height: chartH) }
                            if windPanelVisible { precipWindChart(height: chartH, standalone: true) }
                        }
                        if let attribution {
                            WeatherAttributionLink(info: attribution)
                        }
                    }
                    .padding(.horizontal)
                    .frame(minHeight: h)
                } else {
                    // Fill the screen: take off the fixed chrome (two legends,
                    // the attribution link, stack spacing) and split the rest.
                    let chrome: CGFloat = 16 + 16 + 18 + 16
                    let avail = max(200, h - chrome)
                    let tempH = avail * 0.60
                    // Only the top chart can reach the clock corner; the wind
                    // chart is below it whatever the scale does.
                    let corner = StatusCorner(
                        status: statusCorner,
                        chart: plotRect(in: geo.frame(in: .global).insetBy(dx: 16, dy: 0),
                                        height: tempH))
                    let ceiling = StatusCornerClearance.raisedCeiling(
                        peak: peakUnder(corner), domain: tempYDomain, corner: corner)
                    VStack(spacing: 8) {
                        if tempPanelVisible { temperatureChart(height: tempH, ceiling: ceiling) }
                        if windPanelVisible { precipWindChart(height: avail * 0.40) }
                        if let attribution {
                            WeatherAttributionLink(info: attribution)
                        }
                    }
                    .padding(.horizontal)
                    // The corner could not be cleared on sensible terms, so
                    // keep out of its strip after all — which is where the
                    // graph stopped before any of this.
                    .padding(corner.trailing ? .trailing : .leading,
                             standOffWidth(corner, ceiling: ceiling, width: geo.size.width))
                    .frame(minHeight: h)
                }
            }
        }
    }

    @ViewBuilder
    /// `ceiling` replaces the top of the scale when the curve has to be kept
    /// below the clock corner. The classic style draws thin lines on an
    /// automatic scale and is left alone.
    private func temperatureChart(height: CGFloat, ceiling: Double? = nil) -> some View {
        switch chartStyle {
        case .classic: classicTemperatureChart(height: height)
        case .filled:  filledTemperatureChart(height: height, ceiling: ceiling)
        }
    }

    @ViewBuilder
    /// `standalone` is for the landscape layout, where this chart sits beside
    /// the temperature chart rather than under it: it stands upright and
    /// labels its own time axis. The classic style already does both.
    private func precipWindChart(height: CGFloat, standalone: Bool = false) -> some View {
        switch chartStyle {
        case .classic: classicPrecipWindChart(height: height)
        case .filled:  filledPrecipWindChart(height: height, standalone: standalone)
        }
    }

    // MARK: - Legends

    private var filledTempLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphFeels    { e.append((palette.purple, "Feels like", false)) }
        if graphTemp     { e.append((palette.green,  "Temp",       true)) }
        if graphWetBulb  { e.append((palette.blue,   "Wet Bulb",   true)) }
        if graphDewPoint { e.append((palette.red,    "Dew Pt",     true)) }
        return e
    }

    private var classicTempLegend: [(color: Color, label: String, isArea: Bool)] {
        var e: [(Color, String, Bool)] = []
        if graphFeels    { e.append((palette.purple, "Feels like", false)) }
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
        if graphGust   { e.append((palette.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph", false)) }
        return e
    }

    // MARK: - Filled style

    @ViewBuilder
    private func filledTemperatureChart(height: CGFloat, ceiling: Double? = nil) -> some View {
        let natural = tempYDomain
        let dom = ceiling.map { natural.lowerBound...max($0, natural.upperBound) } ?? natural
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
                    // Apparent ("feels like") stays a line on top of the bands.
                    if graphFeels {
                        LineMark(x: .value("Time", p.date),
                                 y: .value("Feels like", useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC),
                                 series: .value("S", "app"))
                            .foregroundStyle(palette.purple).interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                if let c = current {
                    if graphTemp {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Temp", useFahrenheit ? c.temperatureF : c.temperatureC))
                            .symbol { NowMarkerSymbol(color: palette.green) }
                    }
                    if graphWetBulb {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Wet Bulb", useFahrenheit ? c.wetBulbF : c.wetBulbC))
                            .symbol { NowMarkerSymbol(color: palette.blue) }
                    }
                    if graphDewPoint {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Dew Point", useFahrenheit ? c.dewPointF : c.dewPointC))
                            .symbol { NowMarkerSymbol(color: palette.red) }
                    }
                    if graphFeels {
                        PointMark(x: .value("Time", c.date),
                                  y: .value("Feels like", useFahrenheit ? c.apparentTemperatureF : c.apparentTemperatureC))
                            .symbol { NowMarkerSymbol(color: palette.purple) }
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
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { value in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption).foregroundStyle(axisInk)
                    }
                }
            }
            .ifLet(filledDateDomain) { view, domain in view.chartXScale(domain: domain) }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            // In-plot unit annotation so the chart area doesn't shrink. Kept on
            // the trailing side: on the leading side it collides with a
            // three-digit top y-axis label (e.g. 100 °F).
            .overlay(alignment: .topTrailing) {
                Text(useFahrenheit ? "°F" : "°C")
                    .font(.caption2)
                    .foregroundStyle(axisInk)
                    .padding(.trailing, 6)
                    .padding(.top, 2)
            }
            .overlay(alignment: scrubFraction < 0.5 ? .topTrailing : .topLeading) { scrubReadoutHUD }
            .frame(height: height - legendReserve)
        }
    }

    @ViewBuilder
    private func filledPrecipWindChart(height: CGFloat, standalone: Bool = false) -> some View {
        let dom = windYDomain
        let base = dom.lowerBound
        VStack(alignment: .leading, spacing: 2) {
            // Standing on its own the legend belongs above, where every other
            // chart in the app keeps it. Hanging under the temperature chart it
            // goes below, so it does not separate the two plots.
            if standalone {
                ChartLegendRow(entries: filledWindLegend, ink: axisInk)
                    .padding(.leading, 36)
            }
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
            // Beside that chart instead of under it, there is nothing to hang
            // from and nothing to share, so it stands up the usual way.
            .chartYScale(domain: standalone ? [dom.lowerBound, dom.upperBound]
                                            : [dom.upperBound, dom.lowerBound])
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    AxisValueLabel().font(.caption).foregroundStyle(axisInk)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { value in
                    AxisGridLine().foregroundStyle(axisInk.opacity(0.25))
                    AxisTick().foregroundStyle(axisInk.opacity(0.6))
                    // Grid lines only when the hour labels are shared with the
                    // chart above; its own axis when it stands beside one.
                    if standalone {
                        AxisValueLabel(centered: true) {
                            Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                                .font(.caption).foregroundStyle(axisInk)
                        }
                    }
                }
            }
            .ifLet(filledDateDomain) { view, domain in view.chartXScale(domain: domain) }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            .frame(height: height - legendReserve)

            if !standalone {
                ChartLegendRow(entries: filledWindLegend, ink: axisInk)
                    .padding(.leading, 36)
            }
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
                if graphFeels {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Feels like", useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC),
                             series: .value("S", "D"))
                        .foregroundStyle(palette.purple).interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
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
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            .overlay(alignment: scrubFraction < 0.5 ? .topTrailing : .topLeading) { scrubReadoutHUD }
            .frame(height: height - legendReserve)
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
                if graphGust {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Gust", useFahrenheit ? p.windGustMPH : p.windGustKPH),
                             series: .value("S", "gust"))
                        .foregroundStyle(palette.red.opacity(0.6)).interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .symbol(Circle()).symbolSize(0)
                }
                if graphWind {
                    LineMark(x: .value("Time", p.date),
                             y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH),
                             series: .value("S", "wind"))
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
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in scrubOverlay(proxy) }
            .frame(height: height - legendReserve)
        }
    }
}

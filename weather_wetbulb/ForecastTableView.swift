import SwiftUI

struct ForecastTableView: View {
    @ObservedObject var weatherService: WeatherService
    var nowTick: Date
    var onRefresh: (() async -> Void)? = nil
    /// Called when the user swipes past an end of the table: -1 = previous
    /// screen, +1 = next. The table owns its own scrolling, so it switches
    /// screens on over-scroll rather than on any vertical drag.
    var onSwitchScreen: ((Int) -> Void)? = nil
    /// The moment showing at the top of the table, shared with the graph
    /// screens so switching between them keeps the same place in time. Read on
    /// the way out, written on the way in.
    @Binding var topDate: Date?

    @State private var atTop = true
    @State private var atBottom = false
    /// False until the table has been scrolled to the graph's moment. The scroll
    /// observer fires during the first layout (reporting the top of the content)
    /// and would otherwise overwrite the very position we are about to restore.
    @State private var hasAligned = false

    private struct ScrollEdges: Equatable {
        var top: Bool
        var bottom: Bool
        /// How far down the content we are, 0…1.
        var fraction: Double
    }
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        return df
    }()

    private static let dayHeaderFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "EEEE d MMM"
        return df
    }()

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let points: [ForecastPoint]
    }

    /// The full -10d…+10d series when history has arrived, else the forecast.
    private var tableSeries: [ForecastPoint] {
        weatherService.seriesFull.isEmpty ? weatherService.series10d : weatherService.seriesFull
    }

    /// First row at or after "now" — the table opens here rather than 10 days ago.
    private var nowRowID: ForecastPoint.ID? {
        (tableSeries.first { $0.date >= nowTick } ?? tableSeries.last)?.id
    }

    private var daySections: [DaySection] {
        var sections: [DaySection] = []
        var currentKey  = ""
        var currentPts: [ForecastPoint] = []

        for pt in tableSeries {
            let key = Self.dayHeaderFormatter.string(from: pt.date)
            if key != currentKey {
                if !currentPts.isEmpty {
                    sections.append(DaySection(id: currentKey, title: currentKey, points: currentPts))
                }
                currentKey = key
                currentPts = [pt]
            } else {
                currentPts.append(pt)
            }
        }
        if !currentPts.isEmpty {
            sections.append(DaySection(id: currentKey, title: currentKey, points: currentPts))
        }
        return sections
    }

    // Column widths
    private let wTime:   CGFloat = 48
    private let wSym:    CGFloat = 26
    private let wUV:     CGFloat = 30
    private let wTemp:   CGFloat = 95
    private let wWet:    CGFloat = 62
    private let wDew:    CGFloat = 55
    private let wWind:   CGFloat = 52
    private let wPrecip: CGFloat = 82
    private let wCloud:  CGFloat = 150

    private var totalWidth: CGFloat {
        wTime + wSym + wUV + wTemp + wWet + wDew + wWind + wPrecip + wCloud + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tableSeries.isEmpty || weatherService.isRefreshing {
                ForecastLoadingView(
                    progress: weatherService.loadProgress,
                    nowTick: nowTick,
                    errorMessage: weatherService.lastErrorMessage
                )
                .padding()
            } else {
                ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(daySections) { section in
                            Section {
                                ForEach(section.points) { point in
                                    dataRow(point)
                                        .background(rowBackground(point))
                                        .id(point.id)
                                }
                            } header: {
                                VStack(spacing: 0) {
                                    Text(section.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .padding(.horizontal)
                                        .padding(.vertical, 4)
                                        .frame(minWidth: totalWidth, alignment: .center)
                                        .background(.bar)
                                    columnHeaderRow
                                }
                            }
                        }

                        if let attr = weatherService.attribution {
                            WeatherAttributionLink(info: attr)
                                .padding()
                        }
                    }
                    .frame(minWidth: totalWidth)
                    // scrollPosition(id:) only tracks rows when the layout is
                    // marked as the scroll target.
                    .scrollTargetLayout()
                }
                .onScrollGeometryChange(for: ScrollEdges.self) { g in
                    let span = max(1, g.contentSize.height - g.containerSize.height)
                    let f = (g.contentOffset.y + g.contentInsets.top) / span
                    return ScrollEdges(
                        top: g.contentOffset.y <= g.contentInsets.top + 1,
                        bottom: g.contentOffset.y + g.containerSize.height
                                >= g.contentSize.height - 1,
                        fraction: min(1, max(0, f)))
                } action: { _, v in
                    atTop = v.top; atBottom = v.bottom
                    guard hasAligned else { return }
                    // Rows are hourly and evenly spaced, so scroll position maps
                    // almost linearly onto time — close enough to hand the graph
                    // the moment the user is looking at. (scrollPosition(id:)
                    // does not track in a two-axis scroll view.)
                    if let f = tableSeries.first?.date, let l = tableSeries.last?.date {
                        topDate = f.addingTimeInterval(v.fraction * l.timeIntervalSince(f))
                    }
                }
                // Only an over-scroll past an end switches screens, so normal
                // scrolling through the rows is untouched.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { v in
                            guard abs(v.translation.height) > abs(v.translation.width) else { return }
                            if v.translation.height < -70 && atBottom { onSwitchScreen?(1) }
                            else if v.translation.height > 70 && atTop { onSwitchScreen?(-1) }
                        }
                )
                .onDisappear { hasAligned = false }
                .onAppear {
                    // Line up with the graph every time the table is opened,
                    // not just the first time — SwiftUI keeps this view's state
                    // between visits, so a one-shot guard would only ever work
                    // once. Falls back to "now" when there is nothing to match.
                    let target = topDate ?? nowTick
                    guard let id = nearestForecastPoint(to: target, in: tableSeries)?.id
                    else { return }
                    // Two passes: in a LazyVStack the target row may not exist
                    // yet, and a scrollTo to an unrealised row does nothing. The
                    // first jump realises the rows around it, the second lands
                    // on it exactly.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .topLeading)
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .topLeading)
                            hasAligned = true
                        }
                    }
                }
                }
            }
        }
    }

    // MARK: Column header row

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            cell("Time",                                         width: wTime,   align: .leading,  bold: true)
            cell("",                                             width: wSym,    align: .center,   bold: true)
            cell("UV",                                           width: wUV,     align: .trailing, bold: true)
            cell(useFahrenheit ? "Temp/feels °F" : "Temp/feels °C", width: wTemp, align: .trailing, bold: true)
            cell(useFahrenheit ? "Wet bulb °F"   : "Wet bulb °C",   width: wWet,  align: .trailing, bold: true)
            cell(useFahrenheit ? "Dew Pt °F"     : "Dew Pt °C",     width: wDew,  align: .trailing, bold: true)
            cell(useFahrenheit ? "Wind mph"       : "Wind kph",      width: wWind, align: .trailing, bold: true)
            cell("Precip (%)",                                   width: wPrecip, align: .trailing, bold: true)
            cell("Cloud (%)",                                    width: wCloud,  align: .trailing, bold: true)
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.bar)
    }

    // MARK: Data row

    private func dataRow(_ p: ForecastPoint) -> some View {
        HStack(spacing: 0) {
            cell(Self.timeFormatter.string(from: p.date), width: wTime, align: .leading)

            // Weather condition icon
            Image(systemName: p.symbolName)
                .font(.caption)
                .frame(width: wSym, alignment: .center)

            cell(fmtUV(p.uvIndex),                                              width: wUV,   align: .trailing)
            cell(fmtTemp(p),                                                    width: wTemp, align: .trailing)
            cell(fmt1(useFahrenheit ? p.wetBulbF    : p.wetBulbC),             width: wWet,  align: .trailing)
            cell(fmt1(useFahrenheit ? p.dewPointF   : p.dewPointC),            width: wDew,  align: .trailing)
            cell(fmt1(useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH),        width: wWind, align: .trailing)
            cell(fmtPrecip(p),        width: wPrecip, align: .trailing)
            cell(fmtCloud(p),         width: wCloud,  align: .trailing)
        }
        .font(.caption)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }

    // MARK: Formatting helpers

    private func fmt1(_ n: Double) -> String { String(format: "%.1f", n) }
    private func fmtUV(_ n: Double) -> String { String(format: "%d", Int(n)) }

    private func fmtTemp(_ p: ForecastPoint) -> String {
        useFahrenheit
            ? String(format: "%.1f (%.1f)", p.temperatureF, p.apparentTemperatureF)
            : String(format: "%.1f (%.1f)", p.temperatureC, p.apparentTemperatureC)
    }

    private func fmtPrecip(_ p: ForecastPoint) -> String {
        String(format: "%.1f (%.0f%%)", p.precipitationMM, p.precipProbability * 100)
    }

    private func fmtCloud(_ p: ForecastPoint) -> String {
        String(format: "%.0f (l:%.0f m:%.0f h:%.0f)",
               p.cloudCover * 100,
               p.cloudCoverLow * 100,
               p.cloudCoverMedium * 100,
               p.cloudCoverHigh * 100)
    }

    // MARK: Layout helpers

    @ViewBuilder
    private func cell(_ text: String, width: CGFloat, align: Alignment, bold: Bool = false) -> some View {
        Text(text)
            .fontWeight(bold ? .semibold : .regular)
            .frame(width: width, alignment: align)
            .lineLimit(1)
    }

    // Subtle alternating row tint (uses the current hour's row for extra emphasis)
    private func rowBackground(_ p: ForecastPoint) -> Color {
        let isNearNow = abs(p.date.timeIntervalSinceNow) < 1800
        if isNearNow { return Color.accentColor.opacity(0.08) }
        let idx = weatherService.series10d.firstIndex(where: { $0.id == p.id }) ?? 0
        return idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03)
    }
}

#Preview {
    ForecastTableView(weatherService: WeatherService(), nowTick: .now,
                      topDate: .constant(nil))
}

import SwiftUI

struct ForecastTableView: View {
    @ObservedObject var weatherService: WeatherService
    var nowTick: Date
    var onRefresh: (() async -> Void)? = nil
    /// Called when the user swipes past an end of the table: -1 = previous
    /// screen, +1 = next. The table owns its own scrolling, so it switches
    /// screens on over-scroll rather than on any vertical drag.
    var onSwitchScreen: ((Int) -> Void)? = nil

    @State private var atTop = true
    @State private var atBottom = false
    @State private var didScrollToNow = false

    private struct ScrollEdges: Equatable { var top: Bool; var bottom: Bool }
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
                }
                .onScrollGeometryChange(for: ScrollEdges.self) { g in
                    ScrollEdges(
                        top: g.contentOffset.y <= g.contentInsets.top + 1,
                        bottom: g.contentOffset.y + g.containerSize.height
                                >= g.contentSize.height - 1)
                } action: { _, v in
                    atTop = v.top; atBottom = v.bottom
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
                .onAppear {
                    guard !didScrollToNow, let id = nowRowID else { return }
                    didScrollToNow = true
                    proxy.scrollTo(id, anchor: .topLeading)
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
    ForecastTableView(weatherService: WeatherService(), nowTick: .now)
}

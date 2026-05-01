import SwiftUI

struct ForecastTableView: View {
    @ObservedObject var weatherService: WeatherService
    var nowTick: Date

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

    private var daySections: [DaySection] {
        var sections: [DaySection] = []
        var currentKey  = ""
        var currentPts: [ForecastPoint] = []

        for pt in weatherService.series10d {
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
            if weatherService.series10d.isEmpty {
                ForecastLoadingView(
                    progress: weatherService.loadProgress,
                    nowTick: nowTick,
                    errorMessage: weatherService.lastErrorMessage
                )
                .padding()
            } else {
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
                                        .frame(minWidth: totalWidth, alignment: .leading)
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
            }
        }
    }

    // MARK: Column header row

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            cell("Time",         width: wTime,   align: .leading,  bold: true)
            cell("",             width: wSym,    align: .center,   bold: true)   // symbol – no header
            cell("UV",           width: wUV,     align: .trailing, bold: true)
            cell("Temp (feels)", width: wTemp,   align: .trailing, bold: true)
            cell("Wet bulb",     width: wWet,    align: .trailing, bold: true)
            cell("Dew Pt",       width: wDew,    align: .trailing, bold: true)
            cell("Wind",         width: wWind,   align: .trailing, bold: true)
            cell("Precip (%)",   width: wPrecip, align: .trailing, bold: true)
            cell("Cloud (%)",    width: wCloud,  align: .trailing, bold: true)
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

            cell(fmtUV(p.uvIndex),    width: wUV,     align: .trailing)
            cell(fmtTemp(p),          width: wTemp,   align: .trailing)
            cell(fmt1(p.wetBulbF),    width: wWet,    align: .trailing)
            cell(fmt1(p.dewPointF),   width: wDew,    align: .trailing)
            cell(fmt1(p.windSpeedMPH), width: wWind,  align: .trailing)
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
        String(format: "%.1f (%.1f)", p.temperatureF, p.apparentTemperatureF)
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

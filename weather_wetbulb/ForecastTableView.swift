import SwiftUI

struct ForecastTableView: View {
    @ObservedObject var weatherService: WeatherService
    var nowTick: Date
    var onRefresh: (() async -> Void)? = nil
    /// Applied to the 10-day series so the leftmost MyFeelsLike column reflects
    /// the personalised regression model when one exists.
    var personalise: ([ForecastPoint]) -> [ForecastPoint] = { $0 }
    /// Features currently in the regression model. Used to decide which
    /// scenario adjusters to display (matches the graph screens).
    var activeFeatures: Set<Feature>? = nil
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

    private var daySections: [DaySection] {
        var sections: [DaySection] = []
        var currentKey  = ""
        var currentPts: [ForecastPoint] = []

        for pt in personalise(weatherService.series10d) {
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

    // Column widths (tweaked for narrower cloud column + extra space after MyFeel)
    private let wMyFL:   CGFloat = 70
    private let wTime:   CGFloat = 48
    private let wSym:    CGFloat = 26
    private let wUV:     CGFloat = 30
    private let wTemp:   CGFloat = 95
    private let wWet:    CGFloat = 62
    private let wDew:    CGFloat = 55
    private let wWind:   CGFloat = 78
    private let wPrecip: CGFloat = 82
    private let wCloud:  CGFloat = 110

    /// Right-padding applied to the MyFeel cell so its numbers sit further
    /// from the Time column (user-visible: extra breathing room between
    /// the two leftmost columns).
    private let myFLTrailingGap: CGFloat = 10

    private var totalWidth: CGFloat {
        wMyFL + myFLTrailingGap + wTime + wSym + wUV + wTemp + wWet + wDew + wWind + wPrecip + wCloud + 16
    }

    // MARK: - 25%-darker variants of the graph colours, used for data text

    private static let cTemp:   Color = .blue.mix(   with: .black, by: 0.25)
    private static let cWet:    Color = .green.mix(  with: .black, by: 0.25)
    private static let cDew:    Color = .red.mix(    with: .black, by: 0.25)
    private static let cWind:   Color = .red.mix(    with: .black, by: 0.25)
    private static let cPrecip: Color = .blue.mix(   with: .black, by: 0.25)
    private static let cMyFL:   Color = .purple.mix( with: .black, by: 0.25)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if weatherService.series10d.isEmpty || weatherService.isRefreshing {
                ForecastLoadingView(
                    progress: weatherService.loadProgress,
                    nowTick: nowTick,
                    errorMessage: weatherService.lastErrorMessage
                )
                .padding()
            } else {
                // Scenario adjusters (only those that are actually in the model)
                ScenarioStrip(activeFeatures: activeFeatures)

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
                .refreshable { await onRefresh?() }
            }
        }
    }

    // MARK: Column header row (two lines allowed)

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            // MyFeels score column — unitless 0…1000 scale, no °F/°C suffix.
            headerCell("MyFeels\nLike", width: wMyFL, align: .center)
                .padding(.trailing, myFLTrailingGap)
            headerCell("Time",                                              width: wTime,  align: .leading)
            headerCell("",                                                  width: wSym,   align: .center)
            headerCell("UV",                                                width: wUV,    align: .trailing)
            headerCell("Temp /\nfeels " + (useFahrenheit ? "°F" : "°C"),    width: wTemp,  align: .trailing)
            headerCell("Wet\nbulb " + (useFahrenheit ? "°F" : "°C"),        width: wWet,   align: .trailing)
            headerCell("Dew\npt " + (useFahrenheit ? "°F" : "°C"),          width: wDew,   align: .trailing)
            headerCell("Wind (gust)\n" + (useFahrenheit ? "mph" : "kph"),   width: wWind,  align: .trailing)
            headerCell("Precip\n(%)",                                       width: wPrecip, align: .trailing)
            headerCell("Cloud\n(%)",                                        width: wCloud,  align: .trailing)
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func headerCell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .fontWeight(.semibold)
            .multilineTextAlignment(textAlignment(for: align))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: align)
    }

    private func textAlignment(for align: Alignment) -> TextAlignment {
        switch align {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }

    // MARK: Data row

    private func dataRow(_ p: ForecastPoint) -> some View {
        HStack(spacing: 0) {
            myFeelsLikeCell(p)
                .padding(.trailing, myFLTrailingGap)

            cell(Self.timeFormatter.string(from: p.date), width: wTime, align: .leading)

            // Weather condition icon
            Image(systemName: p.symbolName)
                .font(.caption)
                .frame(width: wSym, alignment: .center)

            cell(fmtUV(p.uvIndex),                                       width: wUV,    align: .trailing)
            cell(fmtTemp(p),                                             width: wTemp,  align: .trailing, color: Self.cTemp)
            cell(fmt1(useFahrenheit ? p.wetBulbF    : p.wetBulbC),       width: wWet,   align: .trailing, color: Self.cWet)
            cell(fmt1(useFahrenheit ? p.dewPointF   : p.dewPointC),      width: wDew,   align: .trailing, color: Self.cDew)
            cell(fmtWind(p),                                             width: wWind,  align: .trailing, color: Self.cWind)
            cell(fmtPrecip(p),  width: wPrecip, align: .trailing, color: Self.cPrecip)
            cell(fmtCloud(p),   width: wCloud,  align: .trailing)
        }
        .font(.caption)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }

    // MyFeels score cell — coloured background, 3-digit number with text colour
    // chosen for contrast. Empty dash when no model has been fitted yet.
    @ViewBuilder
    private func myFeelsLikeCell(_ p: ForecastPoint) -> some View {
        if let score = p.myFeelsLikeScore {
            let clamped = max(ColorScale.minScore, min(ColorScale.maxScore, score))
            Text(String(format: "%.0f", clamped))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ColorScale.contrastingText(forScore: clamped))
                .frame(width: wMyFL, alignment: .center)
                .padding(.vertical, 2)
                .background(ColorScale.color(forScore: clamped))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: wMyFL, alignment: .center)
        }
    }

    // MARK: Formatting helpers

    private func fmt1(_ n: Double) -> String { String(format: "%.1f", n) }
    private func fmtUV(_ n: Double) -> String { String(format: "%d", Int(n)) }

    private func fmtTemp(_ p: ForecastPoint) -> String {
        useFahrenheit
            ? String(format: "%.1f (%.1f)", p.temperatureF, p.apparentTemperatureF)
            : String(format: "%.1f (%.1f)", p.temperatureC, p.apparentTemperatureC)
    }

    private func fmtWind(_ p: ForecastPoint) -> String {
        let s = useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH
        let g = useFahrenheit ? p.windGustMPH  : p.windGustKPH
        return String(format: "%.0f (%.0f)", s, g)
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
    private func cell(
        _ text: String,
        width: CGFloat,
        align: Alignment,
        color: Color? = nil
    ) -> some View {
        Text(text)
            .foregroundStyle(color ?? .primary)
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

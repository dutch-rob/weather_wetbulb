//
//  SharedChartComponents.swift
//  weather_wetbulb
//
//  Pieces shared by the forecast screens (HereTodayView, TenDayView): the
//  loading view, the chart legend row, the WeatherKit attribution link, a
//  compact clock-hour formatter, and a small View convenience.
//

import SwiftUI
import UIKit

// MARK: - Shared components

struct ForecastLoadingView: View {
    var progress: LoadProgress
    var nowTick: Date
    var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading forecast…")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(LoadStep.allCases) { step in
                    HStack(spacing: 8) {
                        stepIcon(for: step)
                        Text(step.rawValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if case .inProgress(let t) = (progress.steps[step] ?? .pending),
                           nowTick.timeIntervalSince(t) > 2 {
                            Text("(working…)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func stepIcon(for step: LoadStep) -> some View {
        switch progress.steps[step] ?? .pending {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .inProgress(let t):
            if nowTick.timeIntervalSince(t) > 2 {
                ProgressView().frame(width: 14, height: 14)
            } else {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            }
        case .failure:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

struct ChartLegendRow: View {
    let entries: [(color: Color, label: String, isArea: Bool)]
    /// Text color for the labels. Defaults to secondary; the filled chart style
    /// passes an explicit "ink" so labels track the axis color.
    var ink: Color = .secondary

    var body: some View {
        // One line when the panel is wide enough; two lines in narrow panels
        // (e.g. three-across iPhone landscape) instead of wrapping mid-word.
        ViewThatFits(in: .horizontal) {
            row(entries)
            VStack(alignment: .leading, spacing: 2) {
                row(Array(entries.prefix((entries.count + 1) / 2)))
                row(Array(entries.suffix(entries.count / 2)))
            }
        }
    }

    @ViewBuilder
    private func row(_ items: [(color: Color, label: String, isArea: Bool)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.label) { e in
                HStack(spacing: 4) {
                    if e.isArea {
                        // Full strength: the charts draw their bands at full
                        // opacity, so dimming the swatch made a vivid palette
                        // look muted in the legend. Entries that really are
                        // translucent (gust) pass their own opacity in.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(e.color)
                            .frame(width: 18, height: 8)
                    } else {
                        Rectangle()
                            .fill(e.color)
                            .frame(width: 18, height: 2)
                    }
                    Text(e.label)
                        .font(.caption2)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct WeatherAttributionLink: View {
    let info: WeatherAttributionInfo
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Link(destination: info.legalPageURL) {
            AsyncImage(
                url: colorScheme == .dark ? info.darkLogoURL : info.lightLogoURL
            ) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Text("Apple Weather").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Clock format

/// Compact hour-of-day label. 24-hour → "00"…"23". 12-hour → 1…12 with the
/// noon tick spelled out ("noon") and midnight shown as "12" (no am/pm suffix,
/// matching MyFeelsLike).
func clockHourLabel(_ hour: Int, use12: Bool = false) -> String {
    let h = ((hour % 24) + 24) % 24
    guard use12 else { return String(format: "%02d", h) }
    if h == 12 { return "noon" }
    let hr = h % 12
    return hr == 0 ? "12" : "\(hr)"
}

// MARK: - View extension

extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let v = value { transform(self, v) } else { self }
    }
}

// MARK: - Scrubber

/// The forecast point nearest a given time.
func nearestForecastPoint(to date: Date, in series: [ForecastPoint]) -> ForecastPoint? {
    series.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

/// A UIKit long-press recognizer that reports its location + state. It is a
/// continuous gesture, so after the press begins it keeps reporting `.changed`
/// as the finger moves — that single gesture drives both dropping and dragging
/// the scrub line.
///
/// Crucially it makes the enclosing scroll views (the tab pager and the
/// vertical ScrollView) *require this long-press to fail* before they act, so a
/// hold-then-drag scrubs instead of paging/scrolling, while a plain quick
/// swipe (which fails the long-press immediately) still pages/scrolls normally.
struct LongPressLocator: UIViewRepresentable {
    var minimumDuration: Double = 0.3
    var onEvent: (CGPoint, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> LocatorView {
        let v = LocatorView()
        v.backgroundColor = .clear
        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handle(_:)))
        lp.minimumPressDuration = minimumDuration
        lp.delegate = context.coordinator
        v.addGestureRecognizer(lp)
        v.longPress = lp
        return v
    }
    func updateUIView(_ v: LocatorView, context: Context) { context.coordinator.onEvent = onEvent }
    func makeCoordinator() -> Coordinator { Coordinator(onEvent) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (CGPoint, UIGestureRecognizer.State) -> Void
        init(_ onEvent: @escaping (CGPoint, UIGestureRecognizer.State) -> Void) { self.onEvent = onEvent }
        @objc func handle(_ g: UILongPressGestureRecognizer) { onEvent(g.location(in: g.view), g.state) }
    }

    /// Hosts the recognizer and, once in the window, makes every ancestor
    /// scroll view's pan wait for the long-press to fail.
    final class LocatorView: UIView {
        weak var longPress: UILongPressGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let lp = longPress else { return }
            var v: UIView? = superview
            while let cur = v {
                if let scroll = cur as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: lp)
                }
                v = cur.superview
            }
        }
    }
}

/// Compact "table row" card for the scrubbed forecast point.
struct ScrubReadoutCard: View {
    let point: ForecastPoint
    let timeText: String
    let useFahrenheit: Bool
    let onClose: () -> Void

    var body: some View {
        let unit = useFahrenheit ? "°F" : "°C"
        let windUnit = useFahrenheit ? "mph" : "kph"
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(timeText).font(.caption2.weight(.semibold))
                Spacer(minLength: 10)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            row("Temp/feels \(unit)",
                String(format: "%.1f (%.1f)",
                       useFahrenheit ? point.temperatureF : point.temperatureC,
                       useFahrenheit ? point.apparentTemperatureF : point.apparentTemperatureC), .green)
            row("Wet bulb \(unit)", String(format: "%.1f", useFahrenheit ? point.wetBulbF : point.wetBulbC), .blue)
            row("Dew pt \(unit)", String(format: "%.1f", useFahrenheit ? point.dewPointF : point.dewPointC), .red)
            row("Wind (gust) \(windUnit)",
                String(format: "%.0f (%.0f)",
                       useFahrenheit ? point.windSpeedMPH : point.windSpeedKPH,
                       useFahrenheit ? point.windGustMPH : point.windGustKPH), .red)
            row("Precip", String(format: "%.1f mm (%.0f%%)", point.precipitationMM, point.precipProbability * 100), .blue)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .fixedSize()
    }

    private func row(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
    }
}

// MARK: - Day axis labels

private let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"; return f
}()

/// Label for a day tick on a scrolled/zoomed axis.
///
/// Once the window covers many days there isn't room for "Mo 15" on every tick —
/// two-digit days of the month are the tight case — so the caller works out how
/// much width each tick gets and we drop the weekday when it won't fit.
func dayTickLabel(_ date: Date, includeWeekday: Bool) -> String {
    let day = Calendar.current.component(.day, from: date)
    guard includeWeekday else { return "\(day)" }
    let wd = String(weekdayFmt.string(from: date).prefix(2))
    return "\(wd) \(day)"
}

/// Whether a day axis has room for the weekday as well as the day number.
/// `plotWidth` is the chart's width; `days` the number of day ticks across it.
///
/// Measured rather than guessed: with the weekday forced on, a 10-day window on
/// an iPhone 17 (402 pt wide, so ~35 pt per tick) truncated "Mo 31" to "Mo…"
/// while single-digit days like "Tu 1" still fitted. Two-digit days of the month
/// are therefore the binding case, and they need about 44 pt. We apply that one
/// threshold to every window rather than switching style as the month rolls
/// over, which would make the labels flicker between forms while scrolling.
/// The narrowest supported iPhone (SE, 375 pt) is tighter still, so a window
/// that fails here fails there too.
func dayAxisFitsWeekday(plotWidth: CGFloat, days: Double) -> Bool {
    guard days > 0 else { return true }
    return (plotWidth - 56) / days >= 44
}

// MARK: - "Now" marker

/// Marker for the current time: a ring in the series colour whose centre is cut
/// out of the page, so it reads as hollow in both light and dark appearance. A
/// solid dot of the series colour disappeared into the filled band beneath it.
struct NowMarkerSymbol: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(Color(.systemBackground))
            Circle().strokeBorder(color, lineWidth: 2.5)
        }
        .frame(width: 13, height: 13)
    }
}

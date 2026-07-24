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
                        RoundedRectangle(cornerRadius: 2)
                            .fill(e.color.opacity(0.4))
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

/// A UIKit long-press recognizer that reports its location + state and
/// coexists with SwiftUI's pager swipe / scroll (recognizes simultaneously),
/// so a long press can drop a scrub line without breaking normal gestures.
struct LongPressLocator: UIViewRepresentable {
    var minimumDuration: Double = 0.3
    var onEvent: (CGPoint, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handle(_:)))
        lp.minimumPressDuration = minimumDuration
        lp.delegate = context.coordinator
        v.addGestureRecognizer(lp)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.onEvent = onEvent }
    func makeCoordinator() -> Coordinator { Coordinator(onEvent) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (CGPoint, UIGestureRecognizer.State) -> Void
        init(_ onEvent: @escaping (CGPoint, UIGestureRecognizer.State) -> Void) { self.onEvent = onEvent }
        @objc func handle(_ g: UILongPressGestureRecognizer) { onEvent(g.location(in: g.view), g.state) }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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

//
//  WetBulbCastComplication.swift
//  WetBulbCastComplication
//
//  Two complications (corner + circular), both driven by the App-Group
//  ComplicationSnapshot the watch app writes after each fetch. The snapshot
//  holds an hourly series of frames, so the timeline emits one entry per hour
//  and the complication advances automatically every hour from already-
//  downloaded forecast data — no new fetch needed between updates.
//
//    • Corner (.accessoryCorner): number = current wet-bulb; inner-arc gauge =
//      the day's wet-bulb range with the current value marked.
//    • Circular (.accessoryCircular): ring gauge, wet-bulb large in center.
//
//  Color is a fixed wet-bulb comfort gradient (cool cyan → hot red).
//

import WidgetKit
import SwiftUI

// MARK: - Wet-bulb comfort color

/// RGB anchors for the wet-bulb comfort scale (°C), interpolated linearly.
/// Wet bulb is a much harsher scale than dry bulb: ~20 °C (68 °F) already feels
/// oppressive and humid, and the low-30s °C approach the human survival limit.
/// So the scale is anchored with 20 °C at mid-orange (unpleasant), not benign.
private let wbStops: [(t: Double, r: Double, g: Double, b: Double)] = [
    (4,  0.35, 0.78, 0.92),   // cold — cyan
    (10, 0.30, 0.80, 0.35),   // comfortable — green
    (15, 0.95, 0.85, 0.20),   // muggy — yellow
    (20, 0.96, 0.55, 0.15),   // unpleasant/humid — orange (anchor)
    (25, 0.88, 0.20, 0.18),   // oppressive — red
    (31, 0.50, 0.06, 0.12),   // dangerous — deep red
]

private func wetBulbRGB(_ c: Double) -> (r: Double, g: Double, b: Double) {
    guard let first = wbStops.first, let last = wbStops.last else { return (0.5, 0.5, 0.5) }
    if c <= first.t { return (first.r, first.g, first.b) }
    if c >= last.t { return (last.r, last.g, last.b) }
    for i in 0..<(wbStops.count - 1) {
        let a = wbStops[i], b = wbStops[i + 1]
        if c >= a.t && c <= b.t {
            let f = (c - a.t) / (b.t - a.t)
            return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
        }
    }
    return (last.r, last.g, last.b)
}

private func wetBulbColor(_ c: Double) -> Color {
    let rgb = wetBulbRGB(c)
    return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
}

/// Whether the wet-bulb color at `c` is light (⇒ use black text over it).
private func wetBulbIsLight(_ c: Double) -> Bool {
    let rgb = wetBulbRGB(c)
    let lum = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
    return lum > 0.6
}

// MARK: - Timeline

struct WetBulbEntry: TimelineEntry {
    let date: Date
    let frame: ComplicationFrame?
    let useFahrenheit: Bool
}

struct WetBulbProvider: TimelineProvider {
    func placeholder(in context: Context) -> WetBulbEntry {
        WetBulbEntry(date: .now, frame: nil, useFahrenheit: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WetBulbEntry) -> Void) {
        let snap = ComplicationSnapshot.load()
        completion(WetBulbEntry(date: .now, frame: snap?.frames.first,
                                useFahrenheit: snap?.useFahrenheit ?? false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WetBulbEntry>) -> Void) {
        guard let snap = ComplicationSnapshot.load(), !snap.frames.isEmpty else {
            // No data yet: show a placeholder and try again soon.
            let entry = placeholder(in: context)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
            return
        }
        let now = Date()
        var entries = snap.frames.map { f in
            WetBulbEntry(date: f.date, frame: f, useFahrenheit: snap.useFahrenheit)
        }
        // Make sure something is valid right now (first frame may be future).
        if let first = entries.first, first.date > now {
            entries.insert(WetBulbEntry(date: now, frame: snap.frames.first,
                                        useFahrenheit: snap.useFahrenheit), at: 0)
        }
        // .atEnd asks for a fresh timeline once the hourly entries run out.
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Shared gauge values

/// Derives the gauge's number, value, range and color from one frame. All
/// gauge math stays in °C (units cancel in the fraction); only the displayed
/// number is converted.
struct WetBulbGauge {
    let frame: ComplicationFrame?
    let useFahrenheit: Bool

    var label: String {
        guard let f = frame else { return "--°" }
        let t = useFahrenheit ? f.wetBulbC * 9.0 / 5.0 + 32.0 : f.wetBulbC
        return "\(Int(t.rounded()))°"
    }

    var range: ClosedRange<Double> {
        guard let f = frame else { return 0...1 }
        let lo = f.dayWetBulbMinC, hi = f.dayWetBulbMaxC
        return hi > lo ? lo...hi : lo...(lo + 1)
    }

    var value: Double {
        guard let f = frame else { return 0.5 }
        let r = range
        return min(max(f.wetBulbC, r.lowerBound), r.upperBound)
    }

    /// Position of the current value within the day's range, 0…1.
    var fraction: Double {
        let r = range
        let span = r.upperBound - r.lowerBound
        return span > 0 ? (value - r.lowerBound) / span : 0.5
    }

    /// Gradient across the day's wet-bulb range (cool → hot).
    var gradient: Gradient {
        guard frame != nil else { return Gradient(colors: [.gray.opacity(0.5)]) }
        let r = range
        let n = 5
        let colors = (0..<n).map { i -> Color in
            let c = r.lowerBound + (r.upperBound - r.lowerBound) * Double(i) / Double(n - 1)
            return wetBulbColor(c)
        }
        return Gradient(colors: colors)
    }

    /// Fill for the center disc of the circular complication.
    var centerColor: Color? {
        guard let f = frame else { return nil }
        return wetBulbColor(f.wetBulbC)
    }

    var centerTextColor: Color? {
        guard let f = frame else { return nil }
        return wetBulbIsLight(f.wetBulbC) ? .black : .white
    }

    var centerOutlineColor: Color? {
        guard let f = frame else { return nil }
        return wetBulbIsLight(f.wetBulbC) ? .white : .black
    }

    init(_ entry: WetBulbEntry) {
        self.frame = entry.frame
        self.useFahrenheit = entry.useFahrenheit
    }
}

// MARK: - Views

/// Text with a thin contrasting outline so the number stays readable over the
/// colored disc. Draws the outline color in eight directions behind the fill.
private struct OutlinedText: View {
    let text: String
    let fill: Color
    let outline: Color
    var width: CGFloat = 0.7

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8.0 * 2.0 * .pi
                Text(text)
                    .foregroundStyle(outline)
                    .offset(x: width * CGFloat(cos(angle)), y: width * CGFloat(sin(angle)))
            }
            Text(text).foregroundStyle(fill)
        }
    }
}

struct WetBulbCornerView: View {
    let entry: WetBulbEntry
    var body: some View {
        let g = WetBulbGauge(entry)
        Text(g.label)
            .font(.system(size: 50, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.4)
            .widgetLabel {
                Gauge(value: g.value, in: g.range) { EmptyView() }
                    .tint(g.gradient)
            }
    }
}

/// A circular range gauge (like the weather app): an open ~270° arc tinted with
/// the day's whole wet-bulb range, a marker at the current value, and the
/// outlined wet-bulb number in the center.
private struct RangeGauge<Center: View>: View {
    let gradient: Gradient
    let fraction: Double            // 0…1 position of "now" within the range
    var lineWidth: CGFloat = 5
    @ViewBuilder var center: () -> Center

    private let gapDegrees = 90.0
    private var sweep: Double { 360 - gapDegrees }            // 270° arc
    private var startDegrees: Double { 90 + gapDegrees / 2 }  // gap centered at the bottom

    private var arc: some Shape { Circle().trim(from: 0, to: CGFloat(sweep / 360)) }
    private var markerRadians: Double { max(0, min(1, fraction)) * sweep * .pi / 180 }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - lineWidth / 2
            ZStack {
                ZStack {
                    arc.stroke(Color.gray.opacity(0.25),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    arc.stroke(AngularGradient(gradient: gradient, center: .center,
                                               startAngle: .degrees(0), endAngle: .degrees(sweep)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    Circle()
                        .fill(.white)
                        .frame(width: lineWidth + 1.5, height: lineWidth + 1.5)
                        .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 0.5))
                        .offset(x: radius * CGFloat(cos(markerRadians)),
                                y: radius * CGFloat(sin(markerRadians)))
                }
                .rotationEffect(.degrees(startDegrees))
                center()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct WetBulbCircularView: View {
    let entry: WetBulbEntry
    var body: some View {
        let g = WetBulbGauge(entry)
        RangeGauge(gradient: g.gradient, fraction: g.fraction) { center(g) }
    }

    @ViewBuilder
    private func center(_ g: WetBulbGauge) -> some View {
        ZStack {
            if let c = g.centerColor {
                Circle().fill(c).padding(7)
            }
            if let fill = g.centerTextColor, let outline = g.centerOutlineColor {
                OutlinedText(text: g.label, fill: fill, outline: outline)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.4)
            } else {
                Text(g.label)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Widgets

struct WetBulbCastComplication: Widget {
    let kind = "WetBulbCastComplication"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WetBulbProvider()) { entry in
            WetBulbCornerView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Wet Bulb")
        .description("Current wet-bulb temperature with today's range.")
        .supportedFamilies([.accessoryCorner])
    }
}

struct WetBulbCastCircularComplication: Widget {
    let kind = "WetBulbCastCircular"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WetBulbProvider()) { entry in
            WetBulbCircularView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Wet Bulb")
        .description("Current wet-bulb temperature ringed by today's range.")
        .supportedFamilies([.accessoryCircular])
    }
}

#Preview(as: .accessoryCircular) {
    WetBulbCastCircularComplication()
} timeline: {
    WetBulbEntry(
        date: .now,
        frame: ComplicationFrame(date: .now, wetBulbC: 22, tempC: 30,
                                 dayWetBulbMinC: 14, dayWetBulbMaxC: 26),
        useFahrenheit: false)
    WetBulbEntry(date: .now, frame: nil, useFahrenheit: false)
}

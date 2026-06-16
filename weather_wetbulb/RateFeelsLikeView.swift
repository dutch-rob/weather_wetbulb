//
//  RateFeelsLikeView.swift
//  MyFeelsLike
//
//  Sheet for the user to record one "feels like" rating, expressed purely as
//  a position on a colour scale — no temperature units are shown.
//
//  Layout
//  ──────
//    LEFT  — A wide colour column that is taller than the visible viewport
//            (at most half of it fits on screen). The user scrolls the
//            column up/down; a fixed horizontal indicator sits across the
//            middle of the visible area, with small triangles overhanging
//            the left and right edges and pointing inward. The colour
//            under the indicator is the rating.
//    RIGHT — The "How does it feel right now?" prompt and the categorical
//            questions (Activity / Dressed / Sun, where sun is hidden
//            after sunset).
//
//  The rating is stored as a Double in [0, 1000] (feelsLikeScore on Rating).
//  This score is the regression model's target variable and has no
//  temperature units — colour is interpreted directly by the user.
//

import SwiftUI
import SwiftData

struct RateFeelsLikeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Current weather sample to attach to this rating.
    let snapshot: ForecastPoint
    /// Place this rating belongs to (nil if user is on "current location").
    let placeID: UUID?
    /// Kept on the API for source compatibility but no longer used in the UI.
    let useFahrenheit: Bool

    // User selections
    @State private var feelsLikeScore: Double = 500   // middle of [0, 1000]
    @State private var activity: Int = 1              // Light
    @State private var dress: Int = 0                 // nice
    @State private var sun: Int = 0                   // partial

    /// Identifies which option's hint popover is currently open (if any).
    @State private var shownHint: HintID? = nil

    init(snapshot: ForecastPoint,
         placeID: UUID?,
         useFahrenheit: Bool) {
        self.snapshot = snapshot
        self.placeID = placeID
        self.useFahrenheit = useFahrenheit
        // After sunset there is no meaningful sun/shade distinction; default to shade.
        _sun = State(initialValue: snapshot.isDaylight ? 0 : -1)
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                // ── LEFT: scrollable colour column ────────────────────────
                ColorScoreColumn(score: $feelsLikeScore)
                    .frame(width: 150)
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                    .padding(.vertical, 12)

                // ── RIGHT: questions ──────────────────────────────────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        promptHeader
                        questionnaire
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Rate Feels Like")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                }
            }
        }
    }

    // MARK: Prompt + questionnaire

    private var promptHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How does it feel right now?")
                .font(.headline)
            Text("Scroll the colour column until the strip across the middle shows the colour that matches how this weather feels to you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var questionnaire: some View {
        VStack(alignment: .leading, spacing: 14) {
            categoricalPicker(
                title: "Activity",
                value: $activity,
                options: [
                    (0, "Not active",  "Sitting, standing still, lying down."),
                    (1, "Light",       "Slow walking, cooking, light chores. You can talk and sing."),
                    (2, "Moderate",    "Brisk walking, water aerobics, doubles tennis. You can talk, but not sing."),
                    (3, "Vigorous",    "Running, swimming fast, heavy lifting. You cannot say more than a few words.")
                ]
            )
            categoricalPicker(
                title: "Dressed for",
                value: $dress,
                options: [
                    (-2, "very cold", nil),
                    (-1, "cold",      nil),
                    ( 0, "nice",      nil),
                    ( 1, "warm",      nil),
                    ( 2, "very warm", nil)
                ]
            )
            if snapshot.isDaylight {
                categoricalPicker(
                    title: "Sun / shade",
                    value: $sun,
                    options: [
                        ( 1, "In full sun",      nil),
                        ( 0, "Partially shaded", nil),
                        (-1, "In shade",         nil)
                    ]
                )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sun / shade").font(.subheadline.weight(.semibold))
                    Text("After sunset, shade is assumed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func categoricalPicker(
        title: String,
        value: Binding<Int>,
        options: [(Int, String, String?)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(options, id: \.0) { (raw, label, hint) in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        value.wrappedValue = raw
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: value.wrappedValue == raw ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(value.wrappedValue == raw ? Color.accentColor : .secondary)
                            Text(label).font(.callout)
                        }
                    }
                    .buttonStyle(.plain)

                    if let hint {
                        let id = HintID(category: title, value: raw)
                        Button {
                            shownHint = (shownHint == id) ? nil : id
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(
                            isPresented: Binding(
                                get: { shownHint == id },
                                set: { if !$0 { shownHint = nil } }
                            ),
                            arrowEdge: .top
                        ) {
                            Text(hint)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: 260)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Save

    private func save() {
        let rating = Rating(
            placeID: placeID,
            feelsLikeScore: feelsLikeScore,
            activity: activity,
            dress: dress,
            sun: sun,
            snapshot: snapshot
        )
        modelContext.insert(rating)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Helpers

private struct HintID: Hashable {
    let category: String
    let value: Int
}

// MARK: - ColorScoreColumn
//
// A vertically scrollable colour column. The column's content is twice as
// tall as the visible viewport (so at most half fits on screen at once).
// A fixed horizontal indicator sits at the vertical centre of the viewport
// — as the user scrolls, the colour passing under the indicator becomes
// the selected score.
//
// The colour gradient is constructed so the indicator can sweep the full
// 0…1000 score range from one scroll extreme to the other: the middle half
// of the content height carries the anchor colours evenly distributed,
// padded with solid "hot" above and solid "cold" below.

private struct ColorScoreColumn: View {
    @Binding var score: Double   // 0…1000

    var body: some View {
        GeometryReader { geo in
            let h = max(1, geo.size.height)
            let contentHeight = h * 3.0     // 2h scroll range → factor-2 stretch vs original
            let coordSpace = "ColorScoreColumn"
            let indicatorOverhang: CGFloat = 12

            ZStack(alignment: .topLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        // A VStack with a tiny invisible anchor ("mid") placed at
                        // exactly the content midpoint. ScrollViewReader scrolls to
                        // it on appear so score 500 starts under the indicator.
                        VStack(spacing: 0) {
                            Color.clear.frame(height: contentHeight / 2 - 0.5)
                            Color.clear.frame(height: 1).id("mid")
                            Color.clear.frame(height: contentHeight / 2 - 0.5)
                        }
                        .frame(height: contentHeight)
                        .background(
                            GeometryReader { innerGeo in
                                LinearGradient(
                                    gradient: paddedScoreGradient(),
                                    startPoint: .top, endPoint: .bottom
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .preference(
                                    key: ScrollMinYKey.self,
                                    value: innerGeo.frame(in: .named(coordSpace)).minY
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: coordSpace)
                    .frame(height: h)
                    .onPreferenceChange(ScrollMinYKey.self) { minY in
                        // contentOffset goes 0…(contentHeight−h) as user scrolls down.
                        // frac 0→1 maps hot→cold, matching the gradient direction.
                        let contentOffset = -minY
                        let usableRange = contentHeight - h
                        guard usableRange > 0 else { return }
                        let frac = contentOffset / usableRange
                        let s = (1.0 - max(0, min(1, frac))) * 1000.0
                        if abs(s - score) > 0.5 { score = s }
                    }
                    .onAppear {
                        // Defer one runloop tick so layout has finished.
                        DispatchQueue.main.async {
                            proxy.scrollTo("mid", anchor: .center)
                        }
                    }
                }

                // Indicator overlay — wider than the column so the triangles
                // overhang to the left and right.
                IndicatorOverlay()
                    .frame(width: geo.size.width + 2 * indicatorOverhang, height: 16)
                    .position(x: geo.size.width / 2, y: h / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Builds the gradient for a contentHeight = h * 3.0 column.
    ///
    /// padFrac = (h/2) / (3h) = 1/6: the top and bottom 1/6 of the content
    /// are non-selectable (indicator cannot reach there) and are rendered
    /// fully transparent. The middle 2/3 carries the active colour range.
    /// Hard cut at each boundary (epsilon step) avoids a colour bleed.
    ///
    /// A power curve (exponent 0.6) is applied so that dark colour transitions
    /// (black → purple near the top) get proportionally more visible space.
    private func paddedScoreGradient() -> Gradient {
        let reversed = Array(ColorScale.anchors.reversed())
        let cold = reversed.last!.color
        let padFrac: Double = 1.0 / 6.0          // (h/2) / (3h)
        let activeRange = 1.0 - 2.0 * padFrac    // 2/3
        let eps: Double = 0.0005

        // Top padding: transparent up to just before the active area starts.
        var stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: padFrac - eps)
        ]
        // Active colour range — first anchor (hot) at padFrac, last (cold) at 1-padFrac.
        let n = reversed.count
        for (i, a) in reversed.enumerated() {
            let t    = Double(i) / Double(n - 1)
            let frac = pow(t, 0.6)
            stops.append(.init(color: a.color, location: padFrac + activeRange * frac))
        }
        // Bottom padding: hard cut from cold back to transparent.
        stops.append(.init(color: cold, location: 1.0 - padFrac + eps))
        stops.append(.init(color: .clear, location: 1.0 - padFrac + 2 * eps))
        stops.append(.init(color: .clear, location: 1.0))
        return Gradient(stops: stops)
    }
}

private struct ScrollMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Indicator overlay

/// A thin white horizontal bar with small white triangles overhanging the
/// column edges on the left and right, both pointing inward. The bar sits
/// inside the column area; the triangles stick out by 12 pt on each side.
private struct IndicatorOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let triangleW: CGFloat = 12
            let cy = geo.size.height / 2
            let halfH: CGFloat = 6

            ZStack {
                // Thin horizontal bar covering only the column area (not the
                // overhang where the triangles live).
                Path { p in
                    p.move(to: CGPoint(x: triangleW, y: cy))
                    p.addLine(to: CGPoint(x: w - triangleW, y: cy))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))

                // Left triangle (apex right — points into the column)
                Path { p in
                    p.move(to: CGPoint(x: 0,         y: cy - halfH))
                    p.addLine(to: CGPoint(x: triangleW, y: cy))
                    p.addLine(to: CGPoint(x: 0,         y: cy + halfH))
                    p.closeSubpath()
                }
                .fill(.white)

                // Right triangle (apex left — points into the column)
                Path { p in
                    p.move(to: CGPoint(x: w,             y: cy - halfH))
                    p.addLine(to: CGPoint(x: w - triangleW, y: cy))
                    p.addLine(to: CGPoint(x: w,             y: cy + halfH))
                    p.closeSubpath()
                }
                .fill(.white)
            }
            .shadow(color: .black.opacity(0.35), radius: 1.2)
        }
    }
}

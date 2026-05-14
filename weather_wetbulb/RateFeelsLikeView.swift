//
//  RateFeelsLikeView.swift
//  MyFeelsLike
//
//  Sheet for the user to record one "feels like" rating, captured against
//  the current weather snapshot at the moment of submission.
//
//  Layout: two columns side by side.
//    Left  — tall, narrow vertical colour bar with draggable thumb +
//            live value readout underneath.  Fills from just below the
//            toolbar to the bottom of the safe area.
//    Right — the "How does it feel right now?" prompt and the three
//            textual ratings (Activity / Dressed / Sun).  Long hints
//            (Activity) are hidden behind an ⓘ button that shows a
//            popover.
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
    /// Display in Fahrenheit on the scale labels (storage is always Celsius).
    let useFahrenheit: Bool

    // User selections
    @State private var feelsLikeC: Double
    @State private var activity: Int = 1   // Light
    @State private var dress: Int = 0      // nice
    @State private var sun: Int = 0        // partial

    /// Identifies which option's hint popover is currently open (if any).
    @State private var shownHint: HintID? = nil

    init(snapshot: ForecastPoint,
         placeID: UUID?,
         useFahrenheit: Bool) {
        self.snapshot = snapshot
        self.placeID = placeID
        self.useFahrenheit = useFahrenheit
        // Start the slider at the apparent temperature.
        _feelsLikeC = State(initialValue: snapshot.apparentTemperatureC)
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                // ── Left column: tall colour bar + value readout ──────────
                VStack(spacing: 8) {
                    colorBar
                        .frame(maxHeight: .infinity)
                    valueReadout
                }
                .frame(width: 90)
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 12)

                // ── Right column: prompt + categorical ratings ────────────
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

    private var promptHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How does it feel right now?")
                .font(.headline)
            Text("Drag the marker on the colour bar to the temperature that matches how this weather feels to you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var valueReadout: some View {
        let f = TempUnit.cToF(feelsLikeC)
        let primary = useFahrenheit ? String(format: "%.0f °F", f) : String(format: "%.1f °C", feelsLikeC)
        let secondary = useFahrenheit ? String(format: "%.1f °C", feelsLikeC) : String(format: "%.0f °F", f)
        return VStack(spacing: 2) {
            Text(primary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ColorScale.color(forC: feelsLikeC))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(secondary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Color bar with draggable thumb

    private var colorBar: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let barW: CGFloat = 30

            // Map current value to vertical position.
            let frac = (feelsLikeC - ColorScale.minC) / (ColorScale.maxC - ColorScale.minC)
            let y = h * (1 - CGFloat(max(0, min(1, frac))))

            ZStack(alignment: .topLeading) {
                // Gradient bar (top = hot, bottom = cold)
                LinearGradient(
                    gradient: Gradient(stops: ColorScale.anchors.reversed().map { a in
                        let frac = (a.tempC - ColorScale.minC) / (ColorScale.maxC - ColorScale.minC)
                        return Gradient.Stop(color: a.color, location: 1 - CGFloat(frac))
                    }),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: barW, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.gray.opacity(0.3), lineWidth: 0.5)
                )

                // Tick labels to the right of the bar
                tickLabels(height: h, barWidth: barW)

                // Indicator thumb — slightly wider than the bar
                Capsule()
                    .fill(.white)
                    .frame(width: barW + 12, height: 4)
                    .overlay(
                        Capsule().stroke(.black.opacity(0.7), lineWidth: 1)
                    )
                    .offset(x: -6, y: y - 2)
                    .shadow(radius: 1)
            }
            .frame(width: geo.size.width, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let yClamped = max(0, min(h, drag.location.y))
                        let f = 1 - Double(yClamped / h)
                        feelsLikeC = ColorScale.minC + f * (ColorScale.maxC - ColorScale.minC)
                    }
            )
        }
    }

    @ViewBuilder
    private func tickLabels(height: CGFloat, barWidth: CGFloat) -> some View {
        let ticks: [Double] = useFahrenheit
            ? stride(from: -10.0, through: 110.0, by: 10.0).map(TempUnit.fToC)
            : stride(from: -20.0, through: 45.0, by: 5.0).map { $0 }
        ForEach(ticks, id: \.self) { tC in
            let frac = (tC - ColorScale.minC) / (ColorScale.maxC - ColorScale.minC)
            if frac >= 0 && frac <= 1 {
                let y = height * CGFloat(1 - frac)
                let label = useFahrenheit
                    ? String(format: "%.0f", TempUnit.cToF(tC))
                    : String(format: "%.0f", tC)
                HStack(spacing: 4) {
                    Rectangle().fill(.black.opacity(0.4)).frame(width: 6, height: 1)
                    Text(label).font(.caption2).foregroundStyle(.primary)
                }
                .offset(x: barWidth + 4, y: y - 6)
            }
        }
    }

    // MARK: Questionnaire (right column)

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
            categoricalPicker(
                title: "Sun / shade",
                value: $sun,
                options: [
                    ( 1, "In full sun",        nil),
                    ( 0, "Partially shaded",   nil),
                    (-1, "In shade",           nil)
                ]
            )
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
            feelsLikeC: feelsLikeC,
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

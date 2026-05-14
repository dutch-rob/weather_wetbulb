//
//  RateFeelsLikeView.swift
//  MyFeelsLike
//
//  Sheet for the user to record one "feels like" rating, captured against
//  the current weather snapshot at the moment of submission.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promptHeader
                    colorBar
                        .frame(height: 280)
                        .padding(.horizontal, 24)
                    valueReadout
                        .frame(maxWidth: .infinity)
                    questionnaire
                }
                .padding()
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
            Text("Drag the marker to the temperature that matches how this weather feels to you.")
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
                .font(.title2.weight(.semibold))
                .foregroundStyle(ColorScale.color(forC: feelsLikeC))
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Color bar with draggable thumb

    private var colorBar: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width

            // Map current value to vertical position.
            let frac = (feelsLikeC - ColorScale.minC) / (ColorScale.maxC - ColorScale.minC)
            // Higher temps at the top (gradient end), so y from bottom.
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.gray.opacity(0.3), lineWidth: 0.5)
                )

                // Tick labels every 5°C (or every 10°F)
                tickLabels(height: h, width: w)

                // Indicator thumb
                Capsule()
                    .fill(.white)
                    .frame(width: w + 12, height: 4)
                    .overlay(
                        Capsule().stroke(.black.opacity(0.7), lineWidth: 1)
                    )
                    .offset(x: -6, y: y - 2)
                    .shadow(radius: 1)
            }
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
    private func tickLabels(height: CGFloat, width: CGFloat) -> some View {
        let ticks: [Double] = useFahrenheit
            ? stride(from: -10.0, through: 110.0, by: 10.0).map(TempUnit.fToC) // 10°F steps
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
                .offset(x: width + 4, y: y - 6)
            }
        }
    }

    // MARK: Questionnaire

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
                Button {
                    value.wrappedValue = raw
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: value.wrappedValue == raw ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(value.wrappedValue == raw ? Color.accentColor : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label).font(.callout)
                            if let hint {
                                Text(hint).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
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

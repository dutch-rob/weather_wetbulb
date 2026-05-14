//
//  ScenarioStrip.swift
//  MyFeelsLike
//
//  Compact controls for the user's predicted "scenario" — used as inputs
//  to the personalised feels-like prediction shown on the charts/table.
//  Saved via @AppStorage so they persist across launches and screens.
//
//  When `activeFeatures` is provided, only chips whose feature is in the
//  current regression model are displayed (so the user isn't offered
//  knobs that don't actually move the prediction).
//
//  Per-option sufficiency:
//    Inside a chip menu, each option is enabled only when at least
//    `minObservations` ratings exist at that exact level.  Below that
//    threshold the model has too little information to predict
//    reliably at that level, so we grey the option and disable it.
//

import SwiftUI
import SwiftData

struct ScenarioStrip: View {
    /// Features currently in the regression model.  When non-nil, only chips
    /// corresponding to an included feature are shown.  Nil = show all
    /// three chips (used before a model is fit, or when the caller doesn't
    /// know which features are active).
    var activeFeatures: Set<Feature>? = nil

    /// Minimum number of ratings at a categorical level for the model to
    /// be considered informative at that level.
    private static let minObservations = 4

    @Query private var ratings: [Rating]

    @AppStorage("scenarioActivity") private var activity: Int = 1
    @AppStorage("scenarioDress")    private var dress:    Int = 0
    @AppStorage("scenarioSun")      private var sun:      Int = 0

    private func shows(_ feature: Feature) -> Bool {
        activeFeatures.map { $0.contains(feature) } ?? true
    }

    private var anyChipVisible: Bool {
        shows(.activity) || shows(.dress) || shows(.sun)
    }

    private func count(feature: Feature, value: Int) -> Int {
        ratings.lazy.filter { r in
            switch feature {
            case .activity: return r.activity == value
            case .dress:    return r.dress    == value
            case .sun:      return r.sun      == value
            default:        return false
            }
        }.count
    }

    var body: some View {
        if anyChipVisible {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if shows(.activity) {
                        pickerChip(title: "Activity",
                                   feature: .activity,
                                   selection: $activity,
                                   options: [
                                    (0, "—"), (1, "Light"), (2, "Moderate"), (3, "Vigorous")
                                   ])
                    }
                    if shows(.dress) {
                        pickerChip(title: "Dressed",
                                   feature: .dress,
                                   selection: $dress,
                                   options: [
                                    (-2, "very cold"), (-1, "cold"), (0, "nice"),
                                    (1, "warm"), (2, "very warm")
                                   ])
                    }
                    if shows(.sun) {
                        pickerChip(title: "Sun",
                                   feature: .sun,
                                   selection: $sun,
                                   options: [
                                    (1, "Full sun"), (0, "Partial"), (-1, "Shade")
                                   ])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func pickerChip(
        title: String,
        feature: Feature,
        selection: Binding<Int>,
        options: [(Int, String)]
    ) -> some View {
        Menu {
            ForEach(options, id: \.0) { (raw, label) in
                let n = count(feature: feature, value: raw)
                let disabled = n < Self.minObservations
                Button {
                    selection.wrappedValue = raw
                } label: {
                    if selection.wrappedValue == raw {
                        // System will style a Label with checkmark image as a
                        // selected menu item on iOS.
                        Label(displayLabel(label, n: n, disabled: disabled),
                              systemImage: "checkmark")
                    } else {
                        Text(displayLabel(label, n: n, disabled: disabled))
                    }
                }
                .disabled(disabled)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(currentLabel(for: selection.wrappedValue, in: options))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar, in: Capsule())
        }
    }

    /// Suffix the option label with an "(n rated)" hint when the level is
    /// under-sampled, so the user can tell *why* it's disabled.
    private func displayLabel(_ label: String, n: Int, disabled: Bool) -> String {
        disabled ? "\(label)  ·  \(n) rated" : label
    }

    private func currentLabel(for value: Int, in options: [(Int, String)]) -> String {
        options.first(where: { $0.0 == value })?.1 ?? "?"
    }
}

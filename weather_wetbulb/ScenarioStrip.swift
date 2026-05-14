//
//  ScenarioStrip.swift
//  MyFeelsLike
//
//  Compact controls for the user's predicted "scenario" — used as inputs
//  to the personalised feels-like prediction shown on the charts/table.
//  Saved via @AppStorage so they persist across launches and screens.
//

import SwiftUI

struct ScenarioStrip: View {
    @AppStorage("scenarioActivity") private var activity: Int = 1
    @AppStorage("scenarioDress")    private var dress:    Int = 0
    @AppStorage("scenarioSun")      private var sun:      Int = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                pickerChip(title: "Activity", selection: $activity, options: [
                    (0, "—"), (1, "Light"), (2, "Moderate"), (3, "Vigorous")
                ])
                pickerChip(title: "Dressed", selection: $dress, options: [
                    (-2, "very cold"), (-1, "cold"), (0, "nice"),
                    (1, "warm"), (2, "very warm")
                ])
                pickerChip(title: "Sun", selection: $sun, options: [
                    (1, "Full sun"), (0, "Partial"), (-1, "Shade")
                ])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func pickerChip(title: String, selection: Binding<Int>, options: [(Int, String)]) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { (raw, label) in
                    Text(label).tag(raw)
                }
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

    private func currentLabel(for value: Int, in options: [(Int, String)]) -> String {
        options.first(where: { $0.0 == value })?.1 ?? "?"
    }
}

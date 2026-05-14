//
//  SettingsView.swift
//  MyFeelsLike
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = false
    @AppStorage("shareDataWithDevs") private var shareData: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var ratings: [Rating]

    @State private var showResetConfirm = false
    @State private var showInfo = false

    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $useFahrenheit) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Share data with developers", isOn: $shareData)
                Text("If enabled, your ratings and the matching weather snapshots will be shared anonymously to help improve MyFeelsLike. Sharing is currently disabled — feature coming in a future update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section("Your model") {
                LabeledContent("Ratings recorded", value: "\(ratings.count)")
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset ratings & model", systemImage: "trash")
                }
                .disabled(ratings.isEmpty)
            }

            Section {
                Button {
                    showInfo = true
                } label: {
                    Label("About MyFeelsLike", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Delete all \(ratings.count) ratings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all ratings", role: .destructive) {
                resetRatings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes every rating you've given and clears the personalised model. This cannot be undone.")
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack { InfoView() }
        }
    }

    private func resetRatings() {
        for r in ratings { modelContext.delete(r) }
        try? modelContext.save()
    }
}

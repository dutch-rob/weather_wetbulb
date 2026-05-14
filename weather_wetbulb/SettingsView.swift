//
//  SettingsView.swift
//  MyFeelsLike
//

import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = false
    @AppStorage("shareDataWithDevs") private var shareData: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var ratings: [Rating]

    @State private var showResetConfirm = false
    @State private var showInfo = false

    @State private var exportURL: URL? = nil
    @State private var showExportShare = false
    @State private var exportError: String? = nil

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

                Button {
                    exportRatings()
                } label: {
                    Label("Export ratings as JSON…", systemImage: "square.and.arrow.up")
                }
                .disabled(ratings.isEmpty)

                Text("Export the data of this app as a JSON file — share it to e.g. an email, or save it to a folder in your iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Data")
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
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Reset

    private func resetRatings() {
        for r in ratings { modelContext.delete(r) }
        try? modelContext.save()
    }

    // MARK: - Export

    private func exportRatings() {
        exportError = nil
        do {
            let url = try writeExportJSON(ratings: ratings)
            exportURL = url
            showExportShare = true
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func writeExportJSON(ratings: [Rating]) throws -> URL {
        let exports = ratings.map { RatingExport(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(exports)

        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyFeelsLike-ratings-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return df
    }()
}

// MARK: - Codable view of Rating used purely for export

private struct RatingExport: Codable {
    let id: UUID
    let timestamp: Date
    let placeID: UUID?

    let feelsLikeC: Double
    let activity: Int
    let dress: Int
    let sun: Int

    let temperatureC: Double
    let apparentTemperatureC: Double
    let wetBulbC: Double
    let dewPointC: Double
    let humidity: Double
    let stationPressurePa: Double
    let windSpeedKPH: Double
    let precipProbability: Double
    let precipitationMM: Double
    let cloudCover: Double
    let cloudCoverLow: Double
    let cloudCoverMedium: Double
    let cloudCoverHigh: Double
    let uvIndex: Double
    let isDaylight: Bool

    init(from r: Rating) {
        self.id                   = r.id
        self.timestamp            = r.timestamp
        self.placeID              = r.placeID
        self.feelsLikeC           = r.feelsLikeC
        self.activity             = r.activity
        self.dress                = r.dress
        self.sun                  = r.sun
        self.temperatureC         = r.temperatureC
        self.apparentTemperatureC = r.apparentTemperatureC
        self.wetBulbC             = r.wetBulbC
        self.dewPointC            = r.dewPointC
        self.humidity             = r.humidity
        self.stationPressurePa    = r.stationPressurePa
        self.windSpeedKPH         = r.windSpeedKPH
        self.precipProbability    = r.precipProbability
        self.precipitationMM      = r.precipitationMM
        self.cloudCover           = r.cloudCover
        self.cloudCoverLow        = r.cloudCoverLow
        self.cloudCoverMedium     = r.cloudCoverMedium
        self.cloudCoverHigh       = r.cloudCoverHigh
        self.uvIndex              = r.uvIndex
        self.isDaylight           = r.isDaylight
    }
}

// MARK: - UIKit share-sheet bridge

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

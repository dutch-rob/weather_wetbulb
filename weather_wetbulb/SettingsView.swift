//
//  SettingsView.swift
//  MyFeelsLike
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

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

    @State private var showImportPicker = false
    @State private var importMessage: String? = nil

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

                Button {
                    importMessage = nil
                    showImportPicker = true
                } label: {
                    Label("Import ratings from JSON…", systemImage: "square.and.arrow.down")
                }

                Text("Import ratings from a previously exported JSON file. Ratings already present (matched by ID) are skipped — safe to re-import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(importMessage.hasPrefix("Import failed") ? .red : .secondary)
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
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker(contentTypes: [.json]) { url in
                importRatings(from: url)
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
        let state = RegressionStateStore.load()
        let full = FullExport(
            exportedAt: Date(),
            model: state.map { ModelExport(from: $0, ratings: ratings) },
            ratings: ratings.map { RatingExport(from: $0, state: state) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(full)

        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyFeelsLike-export-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    private func importRatings(from url: URL) {
        importMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Accept both the current FullExport envelope and the legacy flat array.
            let exports: [RatingExport]
            if let full = try? decoder.decode(FullExport.self, from: data) {
                exports = full.ratings
            } else {
                exports = try decoder.decode([RatingExport].self, from: data)
            }

            let existingIDs = Set(ratings.map { $0.id })
            var added = 0
            for e in exports {
                guard !existingIDs.contains(e.id) else { continue }
                let r = Rating(
                    id: e.id, timestamp: e.timestamp, placeID: e.placeID,
                    feelsLikeScore: e.feelsLikeScore, activity: e.activity,
                    dress: e.dress, sun: e.sun,
                    temperatureC: e.temperatureC,
                    apparentTemperatureC: e.apparentTemperatureC,
                    wetBulbC: e.wetBulbC, dewPointC: e.dewPointC,
                    humidity: e.humidity,
                    stationPressurePa: e.stationPressurePa,
                    windSpeedKPH: e.windSpeedKPH,
                    precipProbability: e.precipProbability,
                    precipitationMM: e.precipitationMM,
                    cloudCover: e.cloudCover, cloudCoverLow: e.cloudCoverLow,
                    cloudCoverMedium: e.cloudCoverMedium,
                    cloudCoverHigh: e.cloudCoverHigh,
                    uvIndex: e.uvIndex, isDaylight: e.isDaylight
                )
                modelContext.insert(r)
                added += 1
            }
            try? modelContext.save()
            let skipped = exports.count - added
            importMessage = "Added \(added) rating\(added == 1 ? "" : "s")" +
                (skipped > 0 ? ", \(skipped) already present." : ".")
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return df
    }()
}

// MARK: - Top-level export envelope

/// Root object written to the JSON file.
private struct FullExport: Codable {
    let exportedAt: Date
    /// Current regression model — null when fewer than 5 ratings exist.
    let model: ModelExport?
    let ratings: [RatingExport]
}

// MARK: - Model export

private struct ModelExport: Codable {
    let fittedAt: Date
    let ratingCount: Int
    let rSquared: Double
    let aicc: Double
    /// Names of selected features in model order (apparentTempC always first).
    let features: [String]
    let intercept: CoefficientPair
    /// One entry per selected feature, in model order.
    let coefficients: [FeatureCoefficient]
    /// Leverage statistics computed over the training ratings.
    let diagnostics: LeverageDiagnostics

    struct CoefficientPair: Codable {
        /// Standardised (z-scored) coefficient.
        let std_coef: Double
        /// Unstandardised (original-units) coefficient.
        let raw_coef: Double
    }

    struct FeatureCoefficient: Codable {
        let feature: String
        let std_coef: Double
        let raw_coef: Double
    }

    struct LeverageDiagnostics: Codable {
        /// Number of model parameters (features + intercept).
        let m: Int
        /// Lower threshold 2m/n — model used as-is below this.
        let h_lower: Double
        /// Upper threshold 3m/n — falls back to apparent temperature above this.
        let h_upper: Double
        let h_min: Double
        let h_mean: Double
        let h_max: Double
        /// Training ratings whose leverage h ≤ h_lower (fully in-range).
        let n_inRange: Int
        /// Training ratings in the blend zone h_lower < h ≤ h_upper.
        let n_blended: Int
        /// Training ratings with h > h_upper (model would extrapolate).
        let n_extrapolated: Int
    }

    init(from state: RegressionState, ratings: [Rating]) {
        fittedAt    = state.lastFitAt
        ratingCount = state.ratingCount
        rSquared    = state.rSquared
        aicc        = state.aicc
        features    = state.selectedFeatures.map { $0.rawValue }

        // Intercept: convert standardised β₀ back to original scale.
        var rawInt = state.coefficients[0]
        for (i, _) in state.selectedFeatures.enumerated() {
            rawInt -= state.coefficients[i + 1] * state.means[i] / state.stds[i]
        }
        intercept = CoefficientPair(std_coef: state.coefficients[0], raw_coef: rawInt)

        // Per-feature coefficients.
        coefficients = state.selectedFeatures.enumerated().map { idx, f in
            let beta = state.coefficients[idx + 1]
            return FeatureCoefficient(
                feature:  f.rawValue,
                std_coef: beta,
                raw_coef: beta / state.stds[idx]
            )
        }

        // Leverage diagnostics over the training ratings.
        let n      = ratings.count
        let m      = state.selectedFeatures.count + 1
        let lower  = 2.0 * Double(m) / Double(n)
        let upper  = 3.0 * Double(m) / Double(n)
        let hs     = ratings.compactMap { state.leverage($0) }
        let hMin   = hs.min() ?? 0
        let hMax   = hs.max() ?? 0
        let hMean  = hs.isEmpty ? 0 : hs.reduce(0, +) / Double(hs.count)

        diagnostics = LeverageDiagnostics(
            m:               m,
            h_lower:         lower,
            h_upper:         upper,
            h_min:           hMin,
            h_mean:          hMean,
            h_max:           hMax,
            n_inRange:       hs.filter { $0 <= lower }.count,
            n_blended:       hs.filter { $0 > lower && $0 <= upper }.count,
            n_extrapolated:  hs.filter { $0 > upper }.count
        )
    }
}

// MARK: - Per-rating export

private struct RatingExport: Codable {
    // Identity
    let id: UUID
    let timestamp: Date
    let placeID: UUID?

    // User input
    let feelsLikeScore: Double   // 0…1000 colour-scale rating
    let activity: Int
    let dress: Int
    let sun: Int

    // Weather snapshot at time of rating
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

    // Model diagnostics (nil when no model was active at export time)
    /// Model's predicted score (0…1000) for this rating's feature values.
    let modelPredictionScore: Double?
    /// Hat-matrix diagonal h = x'(X'X)⁻¹x — how far this point is from
    /// the training centroid in feature space.
    let leverage_h: Double?
    /// Visual opacity of the model prediction (1 = fully reliable, 0 = beyond
    /// extrapolation threshold).
    let predictionOpacity: Double?

    init(from r: Rating, state: RegressionState?) {
        id                   = r.id
        timestamp            = r.timestamp
        placeID              = r.placeID
        feelsLikeScore       = r.feelsLikeScore
        activity             = r.activity
        dress                = r.dress
        sun                  = r.sun
        temperatureC         = r.temperatureC
        apparentTemperatureC = r.apparentTemperatureC
        wetBulbC             = r.wetBulbC
        dewPointC            = r.dewPointC
        humidity             = r.humidity
        stationPressurePa    = r.stationPressurePa
        windSpeedKPH         = r.windSpeedKPH
        precipProbability    = r.precipProbability
        precipitationMM      = r.precipitationMM
        cloudCover           = r.cloudCover
        cloudCoverLow        = r.cloudCoverLow
        cloudCoverMedium     = r.cloudCoverMedium
        cloudCoverHigh       = r.cloudCoverHigh
        uvIndex              = r.uvIndex
        isDaylight           = r.isDaylight

        if let state {
            modelPredictionScore = state.predict(r)
            leverage_h           = state.leverage(r)
            predictionOpacity    = state.predictionOpacity(r)
        } else {
            modelPredictionScore = nil
            leverage_h           = nil
            predictionOpacity    = nil
        }
    }
}

// MARK: - UIKit document-picker bridge (import)

private struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - UIKit share-sheet bridge (export)

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

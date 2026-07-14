//
//  IndoorSamplesDebugView.swift
//  weather_wetbulb
//
//  A plain list of the most recent ComfortSamples, so data collection can be
//  verified without a database inspector.
//

import SwiftUI
import SwiftData

struct IndoorSamplesDebugView: View {
    @Query(sort: \ComfortSample.date, order: .reverse) private var samples: [ComfortSample]
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit: Bool = true

    private var recent: [ComfortSample] { Array(samples.prefix(50)) }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f
    }()

    var body: some View {
        List {
            if recent.isEmpty {
                Text("No samples yet. Enable tracking and keep the app open for a bit.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(recent) { s in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.fmt.string(from: s.date)).font(.subheadline).bold()
                    HStack(spacing: 10) {
                        Text("In: \(temp(s.indoorTempC)) / \(rh(s.indoorHumidity))")
                        if let on = s.coolerOn, on {
                            Text("cooler").foregroundStyle(.blue)
                        }
                        if let hvac = s.hvacMode, hvac != 0 {
                            Text(hvac == 1 ? "heat" : "AC").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    Text("Out: \(temp(s.outdoorTempC)) / wb \(temp(s.outdoorWetBulbC)) / \(rh(s.outdoorHumidity))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Recent samples")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func temp(_ c: Double?) -> String {
        guard let c else { return "—" }
        let v = useFahrenheit ? c * 9 / 5 + 32 : c
        return String(format: "%.0f°", v)
    }

    private func rh(_ x: Double?) -> String {
        guard let x else { return "—" }
        return String(format: "%.0f%%", x * 100)
    }
}

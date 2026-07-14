//
//  IndoorSettingsSection.swift
//  weather_wetbulb
//
//  The "Indoor comfort (beta)" section of Settings: enable tracking, pick
//  sensors, log the evaporative cooler, and inspect collected samples.
//

import SwiftUI
import SwiftData

struct IndoorSettingsSection: View {
    @AppStorage(SettingsKey.indoorTrackingEnabled) private var enabled = false
    @Environment(\.modelContext) private var context
    @Query(sort: \ComfortSample.date, order: .reverse) private var samples: [ComfortSample]
    @Query(sort: \CoolerEvent.date, order: .reverse) private var coolerEvents: [CoolerEvent]
    @Query(sort: \HVACEvent.date, order: .reverse) private var hvacEvents: [HVACEvent]
    @ObservedObject private var home = HomeKitService.shared

    private var coolerOn: Bool { coolerEvents.first?.isOn ?? false }
    private var hvacMode: Int { hvacEvents.first?.mode ?? 0 }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }()

    var body: some View {
        Section {
            Toggle("Track indoor comfort", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on {
                        home.start()
                        Task { await IndoorSamplingCoordinator.shared.sampleIfDue(force: true) }
                    }
                }

            if enabled {
                NavigationLink {
                    IndoorSensorsView()
                } label: {
                    Label("Choose indoor sensors", systemImage: "sensor")
                }

                Toggle(isOn: Binding(
                    get: { coolerOn },
                    set: { IndoorSamplingCoordinator.shared.logCooler(on: $0, context: context) }
                )) {
                    Label("Evaporative cooler is on", systemImage: "wind")
                }

                Picker(selection: Binding(
                    get: { hvacMode },
                    set: { IndoorSamplingCoordinator.shared.logHVAC(mode: $0, context: context) }
                )) {
                    Text("Off").tag(0)
                    Text("Heat").tag(1)
                    Text("AC").tag(2)
                } label: {
                    Label("Thermostat", systemImage: "thermometer.medium")
                }

                LabeledContent("Samples collected", value: "\(samples.count)")
                if let last = samples.first?.date {
                    LabeledContent("Last sample", value: Self.fmt.string(from: last))
                }

                NavigationLink {
                    IndoorSamplesDebugView()
                } label: {
                    Label("Recent samples", systemImage: "list.bullet.rectangle")
                }
            }
        } header: {
            Text("Indoor comfort (beta)")
        } footer: {
            Text("Records your indoor temperature/humidity from HomeKit alongside outdoor weather, to later estimate evaporative-cooler comfort. Log the cooler on/off — and the thermostat state if it isn't in HomeKit (e.g. a Nest) — so the model can separate their effects. Sampling happens while the app is open (about every 15 minutes) and occasionally in the background, so collection is faster the more you use the app.")
        }
    }
}

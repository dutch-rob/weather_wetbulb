//
//  IndoorSensorsView.swift
//  weather_wetbulb
//
//  Lets the user pick which HomeKit sensors represent "indoors". Selection is
//  persisted as a JSON list of characteristic UUIDs in UserDefaults.
//

import SwiftUI

/// Load/save the selected indoor-sensor ids.
enum IndoorSelection {
    static func load() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.indoorSensorIDs),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func save(_ ids: Set<String>) {
        let data = try? JSONEncoder().encode(Array(ids))
        UserDefaults.standard.set(data, forKey: SettingsKey.indoorSensorIDs)
    }
}

struct IndoorSensorsView: View {
    @ObservedObject private var home = HomeKitService.shared
    @State private var selected: Set<String> = IndoorSelection.load()

    var body: some View {
        List {
            if home.didLoad && !home.isAuthorized {
                Section {
                    Label("HomeKit access is off. Enable it in Settings › Privacy & Security › HomeKit.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if home.sensors.isEmpty {
                Section {
                    Text(home.didLoad
                         ? "No temperature or humidity accessories found yet. Pull to refresh if a home is still loading."
                         : "Looking for HomeKit accessories…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            ForEach(home.homeNames, id: \.self) { homeName in
                let inHome = home.sensors.filter { $0.homeName == homeName }
                Section {
                    if inHome.isEmpty {
                        let accs = home.accessoriesByHome[homeName] ?? []
                        if accs.isEmpty {
                            Text("No accessories loaded yet — pull down to refresh.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No readable temperature/humidity sensors here.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text("Accessories found: \(accs.joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("Note: a HomePod's built-in temperature/humidity sensor isn't shared with third-party apps — only a standalone HomeKit sensor can be tracked.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(inHome) { sensor in
                        Button { toggle(sensor.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sensor.accessoryName).foregroundStyle(.primary)
                                    Text("\(sensor.roomName) · \(sensor.kind.title)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !sensor.isReachable {
                                    Image(systemName: "wifi.slash")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                if selected.contains(sensor.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text(homeName)
                }
            }
        }
        .navigationTitle("Indoor sensors")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { home.rescan() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { home.rescan() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { home.start() }
        .onDisappear {
            // Take a sample right away with the new selection, so the count
            // updates promptly instead of waiting for the next 15-min tick.
            Task { await IndoorSamplingCoordinator.shared.sampleIfDue(force: true) }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        IndoorSelection.save(selected)
    }
}

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

    private var rooms: [String] {
        Array(Set(home.sensors.map(\.roomName))).sorted()
    }

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
                         ? "No temperature or humidity accessories found in HomeKit."
                         : "Looking for HomeKit accessories…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            ForEach(rooms, id: \.self) { room in
                Section(room) {
                    ForEach(home.sensors.filter { $0.roomName == room }) { sensor in
                        Button { toggle(sensor.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sensor.accessoryName).foregroundStyle(.primary)
                                    Text(sensor.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected.contains(sensor.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Indoor sensors")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { home.start() }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        IndoorSelection.save(selected)
    }
}

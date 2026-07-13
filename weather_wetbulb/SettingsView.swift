//
//  SettingsView.swift
//  weather_wetbulb
//
//  App settings: temperature units, forecast graph style, and About.
//  Presented as a sheet from the main screen. Future indoor-comfort
//  (HomeKit) settings will get their own section here.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $useFahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Graph style", selection: $chartStyle) {
                    ForEach(ChartStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Forecast graphs")
            } footer: {
                Text("“Filled areas” fills each curve as a shaded band with a marker at the current conditions (temperature green, wet bulb blue, dew point red). “Classic lines” draws them as plain lines.")
            }

            IndoorSettingsSection()

            Section {
                NavigationLink {
                    InfoView()
                } label: {
                    Label("About WetBulbCast", systemImage: "info.circle")
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
    }
}

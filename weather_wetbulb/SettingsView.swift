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
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp)     private var graphTemp     = true
    @AppStorage(GraphKey.wetBulb)  private var graphWetBulb  = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true
    @AppStorage(GraphKey.precip)   private var graphPrecip   = true
    @AppStorage(GraphKey.wind)     private var graphWind      = true
    @AppStorage(GraphKey.gust)     private var graphGust      = true
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

                Picker("Colors", selection: $palette) {
                    ForEach(GraphPalette.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Forecast graphs")
            } footer: {
                Text("“Filled areas” fills each curve as a shaded band with a marker at the current conditions (temperature green, wet bulb blue, dew point red). “Classic lines” draws them as plain lines. “Muted” softens the colors.")
            }

            Section {
                Toggle("Temperature", isOn: $graphTemp)
                Toggle("Wet bulb", isOn: $graphWetBulb)
                Toggle("Dew point", isOn: $graphDewPoint)
                Toggle("Precipitation", isOn: $graphPrecip)
                Toggle("Wind", isOn: $graphWind)
                Toggle("Gust", isOn: $graphGust)
            } header: {
                Text("Show on graphs")
            } footer: {
                Text("Choose which series appear. Gust only shows in the Filled style.")
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

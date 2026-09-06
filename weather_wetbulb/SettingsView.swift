//
//  SettingsView.swift
//  weather_wetbulb
//
//  App settings: units, graph series/style, table screen, iCloud sync, indoor
//  comfort, and About. Section order follows the MyFeelsLike app so users of
//  both apps find things in the same place.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.use12HourClock) private var use12Hour = false
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp)     private var graphTemp     = true
    @AppStorage(GraphKey.wetBulb)  private var graphWetBulb  = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true
    @AppStorage(GraphKey.feels)    private var graphFeels     = true
    @AppStorage(GraphKey.precip)   private var graphPrecip   = true
    @AppStorage(GraphKey.wind)     private var graphWind      = true
    @AppStorage(GraphKey.gust)     private var graphGust      = true
    @AppStorage(SettingsKey.showTable) private var showTable = true
    @AppStorage(SettingsKey.useFoldTimeline) private var useFoldTimeline = false
    @AppStorage(SettingsKey.syncAcrossDevices) private var syncAcrossDevices = false
    @Environment(\.dismiss) private var dismiss

    @State private var showSyncRestartNote = false

    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $useFahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)

                Picker("Time", selection: $use12Hour) {
                    Text("24-hour").tag(false)
                    Text("12-hour").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Temperature", isOn: $graphTemp)
                Toggle("Wet bulb", isOn: $graphWetBulb)
                Toggle("Dew point", isOn: $graphDewPoint)
                Toggle("Feels like line", isOn: $graphFeels)
                Toggle("Precipitation", isOn: $graphPrecip)
                Toggle("Wind", isOn: $graphWind)
                Toggle("Gust", isOn: $graphGust)
            } header: {
                Text("Show on graphs")
            } footer: {
                Text("Choose which series appear. Emptying a panel hides it.")
            }

            Section {
                Picker("Style", selection: $chartStyle) {
                    Text("Filled").tag(ChartStyle.filled)
                    Text("Classic").tag(ChartStyle.classic)
                }
                .pickerStyle(.segmented)

                Picker("Colors", selection: $palette) {
                    ForEach(GraphPalette.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Chart style")
            } footer: {
                Text("“Filled” draws each series as a shaded band from the baseline with a marker at the current conditions; the precip/wind panel hangs from the top. “Classic” draws thin lines and the precip/wind panel reads bottom-up. “Muted” softens the colors.")
            }

            Section {
                Toggle("Table screen", isOn: $showTable)
            } footer: {
                Text("When off, swiping up/down only switches between the 24-hour and 10-day graph screens.")
            }

            Section {
                // Zooming is a pinch now, so the vertical swipe is free for the
                // table: fold mode no longer has to hide it.
                Toggle("Zoom graph", isOn: $useFoldTimeline)
            } header: {
                Text("Zoom graph")
            } footer: {
                Text("Replaces the paged 24-hour and 10-day screens with one graph you zoom: swipe left/right to scroll through time, and pinch to zoom — from a single day out to ten days, stopping wherever you like. Buttons at the top switch to the table, and long-press a chart to read exact values.")
            }

            Section {
                Toggle("Sync across my devices", isOn: $syncAcrossDevices)
                    .onChange(of: syncAcrossDevices) { _, _ in showSyncRestartNote = true }
            } header: {
                Text("iCloud")
            } footer: {
                Text("When on, your indoor-comfort data syncs across your own devices signed into the same iCloud account. Off by default. Changing it takes effect after you quit and reopen the app.")
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
        .alert("Reopen to apply", isPresented: $showSyncRestartNote) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Quit WetBulbCast (swipe it away in the App Switcher) and reopen it for the device-sync change to take effect.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

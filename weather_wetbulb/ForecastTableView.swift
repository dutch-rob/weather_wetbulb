//
//  ForecastTableView.swift
//  weather_wetbulb
//
//  Created by Rob Boer on 4/8/26.
//


import SwiftUI

struct ForecastTableView: View {
    @ObservedObject var weatherService: WeatherService

    private var rows: [ForecastPoint] {
        Array(weatherService.series10d.points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !weatherService.placeDescription.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weatherService.placeDescription)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Table")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding([.top, .horizontal])
            }

            Text("Hourly Forecast (Next 24h)")
                .font(.headline)
                .padding([.top, .horizontal])

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Header row
                    HStack {
                        Text("Time").bold().frame(width: 100, alignment: .leading)
                        Text("Temp (°F)").bold().frame(width: 80, alignment: .trailing)
                        Text("Wet bulb (°F)").bold().frame(width: 110, alignment: .trailing)
                        Text("Dew Point (°F)").bold().frame(width: 110, alignment: .trailing)
                        Text("Precip Prob").bold().frame(width: 90, alignment: .trailing)
                        Text("Precip Amt (mm)").bold().frame(width: 120, alignment: .trailing)
                        Text("Wind (mph)").bold().frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal)

                    Divider()

                    // Rows
                    ForEach(Array(rows.indices), id: \.self) { i in
                        let point = rows[i]
                        HStack {
                            Text(formatTime(point.date))
                                .frame(width: 100, alignment: .leading)
                            Text(formatNumber(point.temperatureF))
                                .frame(width: 80, alignment: .trailing)
                            Text(formatNumber(point.wetBulbF))
                                .frame(width: 110, alignment: .trailing)
                            Text(formatNumber(point.dewPointF))
                                .frame(width: 110, alignment: .trailing)
                            Text(formatPercent(point.precipProbability))
                                .frame(width: 90, alignment: .trailing)
                            Text(formatMM(point.precipAmountMM))
                                .frame(width: 120, alignment: .trailing)
                            Text(formatNumber(point.windSpeedMPH))
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Table")
    }

    private func formatTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "EE HH:mm" // e.g., Mon 14:00
        let s = df.string(from: date)
        // Convert 3-letter day to 2-letter manually for most locales
        let map = ["Mon": "Mo", "Tue": "Tu", "Wed": "We", "Thu": "Th", "Fri": "Fr", "Sat": "Sa", "Sun": "Su"]
        for (k, v) in map { if s.hasPrefix(k) { return v + String(s.dropFirst(3)) } }
        return s
    }

    private func formatNumber(_ n: Double) -> String {
        String(format: "%.1f", n)
    }

    private func formatPercent(_ p: Double) -> String {
        String(format: "%.0f%%", p * 100.0)
    }

    private func formatMM(_ mm: Double) -> String {
        String(format: "%.1f", mm)
    }
}

#Preview {
    ForecastTableView(weatherService: WeatherService())
}

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
        Array(weatherService.series24h.points.prefix(240))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hourly Forecast (Next 240)")
                .font(.headline)
                .padding([.top, .horizontal])

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Header row
                    HStack {
                        Text("Time").bold().frame(width: 120, alignment: .leading)
                        Text("Temp (°F)").bold().frame(width: 90, alignment: .trailing)
                        Text("Apparent (°F)").bold().frame(width: 120, alignment: .trailing)
                        Text("Dew Point (°F)").bold().frame(width: 120, alignment: .trailing)
                        Text("Precip Prob").bold().frame(width: 100, alignment: .trailing)
                        Text("Precip Amt (mm)").bold().frame(width: 130, alignment: .trailing)
                        Text("Wind (mph)").bold().frame(width: 100, alignment: .trailing)
                    }
                    .padding(.horizontal)

                    Divider()

                    // Rows
                    ForEach(Array(rows.indices), id: \.self) { i in
                        let point = rows[i]
                        HStack {
                            Text(formatTime(point.date))
                                .frame(width: 120, alignment: .leading)
                            Text(formatNumber(point.temperatureF))
                                .frame(width: 90, alignment: .trailing)
                            Text(formatNumber(point.apparentTemperatureF))
                                .frame(width: 120, alignment: .trailing)
                            Text(formatNumber(point.dewPointF))
                                .frame(width: 120, alignment: .trailing)
                            Text(formatPercent(point.precipProbability))
                                .frame(width: 100, alignment: .trailing)
                            Text(formatMM(point.precipAmountMM))
                                .frame(width: 130, alignment: .trailing)
                            Text(formatNumber(point.windSpeedMPH))
                                .frame(width: 100, alignment: .trailing)
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
        df.dateStyle = .none
        df.timeStyle = .short
        return df.string(from: date)
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

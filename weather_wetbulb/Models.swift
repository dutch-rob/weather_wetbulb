//
//  Models.swift
//  weather_wetbulb
//
//  One hour of weather (or the "now" nowcast). Pure value type with no UI or
//  platform dependencies (Foundation only) so it can be shared between the iOS
//  app and the watch app / complication targets.
//

import Foundation

struct ForecastPoint: Identifiable, Codable {
    /// Where this point sits relative to "now":
    ///   .historic — observed/analyzed past hour (full field set)
    ///   .current  — Apple's nowcast; lacks precip & cloud-by-altitude
    ///   .forecast — future hourly forecast (full field set)
    enum Kind: Codable { case historic, current, forecast }

    var id = UUID()
    var kind: Kind = .forecast
    let date: Date
    let symbolName: String
    let isDaylight: Bool
    let uvIndex: Double
    let temperatureF: Double
    let temperatureC: Double
    let apparentTemperatureF: Double
    let apparentTemperatureC: Double
    let wetBulbF: Double
    let wetBulbC: Double
    let dewPointF: Double
    let dewPointC: Double
    let precipProbability: Double   // 0…1
    let precipitationMM: Double
    let windSpeedMPH: Double
    let windSpeedKPH: Double
    let windGustMPH: Double
    let windGustKPH: Double
    let cloudCover: Double          // 0…1
    let cloudCoverLow: Double       // 0…1
    let cloudCoverMedium: Double    // 0…1
    let cloudCoverHigh: Double      // 0…1
    let humidity: Double            // 0…1
    let stationPressurePa: Double
}

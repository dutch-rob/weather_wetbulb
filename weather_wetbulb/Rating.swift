//
//  Rating.swift
//  MyFeelsLike
//
//  One user-reported "feels like" datum + the weather snapshot at the moment
//  the rating was given. All weather variables stored in metric/Celsius.
//

import Foundation
import SwiftData

@Model
final class Rating {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var placeID: UUID?

    // User input
    var feelsLikeC: Double = 0          // value chosen on the color scale, °C
    var activity: Int = 1               // 0 Not active / 1 Light / 2 Moderate / 3 Vigorous
    var dress: Int = 0                  // -2 very cold … 0 nice … +2 very warm
    var sun: Int = 0                    // +1 full sun / 0 partial / -1 shade

    // Weather snapshot at rating time
    var temperatureC: Double = 0
    var apparentTemperatureC: Double = 0
    var wetBulbC: Double = 0
    var dewPointC: Double = 0
    var humidity: Double = 0            // 0…1
    var stationPressurePa: Double = 0
    var windSpeedKPH: Double = 0
    var precipProbability: Double = 0   // 0…1
    var precipitationMM: Double = 0
    var cloudCover: Double = 0
    var cloudCoverLow: Double = 0
    var cloudCoverMedium: Double = 0
    var cloudCoverHigh: Double = 0
    var uvIndex: Double = 0
    var isDaylight: Bool = true

    init(
        timestamp: Date = Date(),
        placeID: UUID? = nil,
        feelsLikeC: Double,
        activity: Int,
        dress: Int,
        sun: Int,
        snapshot: ForecastPoint
    ) {
        self.timestamp = timestamp
        self.placeID = placeID
        self.feelsLikeC = feelsLikeC
        self.activity = activity
        self.dress = dress
        self.sun = sun
        self.temperatureC = snapshot.temperatureC
        self.apparentTemperatureC = snapshot.apparentTemperatureC
        self.wetBulbC = snapshot.wetBulbC
        self.dewPointC = snapshot.dewPointC
        self.humidity = snapshot.humidity
        self.stationPressurePa = snapshot.stationPressurePa
        self.windSpeedKPH = snapshot.windSpeedKPH
        self.precipProbability = snapshot.precipProbability
        self.precipitationMM = snapshot.precipitationMM
        self.cloudCover = snapshot.cloudCover
        self.cloudCoverLow = snapshot.cloudCoverLow
        self.cloudCoverMedium = snapshot.cloudCoverMedium
        self.cloudCoverHigh = snapshot.cloudCoverHigh
        self.uvIndex = snapshot.uvIndex
        self.isDaylight = snapshot.isDaylight
    }
}

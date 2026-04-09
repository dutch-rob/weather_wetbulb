import Foundation

public struct ForecastPoint: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let temperatureC: Double
    public let wetBulbC: Double
    public let dewPointC: Double
    public let precipProbability: Double // 0...1
    public let windSpeedKPH: Double
    
    public init(id: UUID = UUID(), date: Date, temperatureC: Double, wetBulbC: Double, dewPointC: Double, precipProbability: Double, windSpeedKPH: Double) {
        self.id = id
        self.date = date
        self.temperatureC = temperatureC
        self.wetBulbC = wetBulbC
        self.dewPointC = dewPointC
        self.precipProbability = precipProbability
        self.windSpeedKPH = windSpeedKPH
    }
}

public struct ForecastSeries: Sendable {
    public let points: [ForecastPoint]
    
    public init(points: [ForecastPoint]) {
        self.points = points
    }
}

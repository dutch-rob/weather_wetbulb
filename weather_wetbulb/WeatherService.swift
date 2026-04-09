import Foundation
import CoreLocation
import WeatherKit
import SwiftUI

class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?
    
    private let manager = CLLocationManager()
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
    }
    
    func requestLocation() {
        manager.requestLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocation()
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }
}

struct WeatherDataMapper {
    static func map(hour: HourWeather) -> (tempC: Double, dewC: Double, windKPH: Double, precipProb: Double) {
        let tempC = hour.temperature.converted(to: .celsius).value
        let dewC = hour.dewPoint.converted(to: .celsius).value
        let windKPH = hour.wind.speed.converted(to: .kilometersPerHour).value
        let precipProb = Double(hour.precipitationChance)
        return (tempC, dewC, windKPH, precipProb)
    }
}

struct ForecastPoint {
    let date: Date
    let tempC: Double
    let dewC: Double
    let windKPH: Double
    let precipProb: Double
    let wetBulbC: Double
}

struct ForecastSeries {
    var points: [ForecastPoint]
}

struct WeatherServiceShared {
    let service = WeatherKit.WeatherService()
}

@MainActor
class WeatherService: ObservableObject {
    @Published var series: ForecastSeries = ForecastSeries(points: [])
    @Published var placeDescription: String = ""
    
    private let weatherService = WeatherServiceShared()
    private let geocoder = CLGeocoder()
    
    func loadFor(location: CLLocation, now: Date = .now) async {
        do {
            let weather = try await weatherService.service.weather(for: location, including: .hourly)
            let hours = weather.hourlyForecast.forecast
            guard let end = Calendar.current.date(byAdding: .hour, value: 24, to: now) else {
                self.series = ForecastSeries(points: [])
                return
            }
            let window = hours.filter { $0.date >= now && $0.date <= end }
            let points = window.map { hour -> ForecastPoint in
                let mapped = WeatherDataMapper.map(hour: hour)
                let wetBulb = 0.7 * mapped.tempC + 0.3 * mapped.dewC
                return ForecastPoint(date: hour.date,
                                     tempC: mapped.tempC,
                                     dewC: mapped.dewC,
                                     windKPH: mapped.windKPH,
                                     precipProb: mapped.precipProb,
                                     wetBulbC: wetBulb)
            }
            self.series = ForecastSeries(points: points)
            
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                guard let self = self else { return }
                if let place = placemarks?.first {
                    let locality = place.locality ?? ""
                    let thoroughfare = place.thoroughfare ?? ""
                    let description = [locality, thoroughfare].filter { !$0.isEmpty }.joined(separator: ", ")
                    DispatchQueue.main.async {
                        self.placeDescription = description
                    }
                } else {
                    DispatchQueue.main.async {
                        self.placeDescription = ""
                    }
                }
            }
        } catch {
            self.series = ForecastSeries(points: [])
            self.placeDescription = ""
            print("WeatherService error: \(error.localizedDescription)")
        }
    }
}

import Foundation
import Combine
import CoreLocation
import WeatherKit
import MapKit

enum LoadStep: String, CaseIterable, Identifiable {
    case location = "Get location"
    case weather = "Fetch forecast"
    case geocode = "Reverse geocode"
    var id: String { rawValue }
}

enum StepState {
    case pending
    case inProgress(startedAt: Date)
    case success
    case failure(Error)
}

struct LoadProgress {
    var steps: [LoadStep: StepState] = [
        .location: .pending,
        .weather: .pending,
        .geocode: .pending
    ]
}

private func withTimeout<T>(_ seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(priority: nil) {
            try await operation()
        }
        group.addTask(priority: nil) {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "WeatherService", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw NSError(domain: "WeatherService", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        group.cancelAll()
        return result
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        DispatchQueue.main.async { self.currentLocation = last }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}

private let sharedWeatherService = WeatherKit.WeatherService()

@MainActor
final class WeatherService: ObservableObject {
    @Published var series24h: ForecastSeries = ForecastSeries(points: [])
    @Published var series10d: ForecastSeries = ForecastSeries(points: [])
    @Published var placeDescription: String = ""
    @Published var loadProgress: LoadProgress = LoadProgress()
    @Published var lastErrorMessage: String? = nil

    private func start(_ step: LoadStep) {
        loadProgress.steps[step] = .inProgress(startedAt: Date())
    }

    private func finish(_ step: LoadStep) {
        loadProgress.steps[step] = .success
    }

    private func fail(_ step: LoadStep, error: Error) {
        loadProgress.steps[step] = .failure(error)
    }

    func loadFor(location: CLLocation, now: Date = .now) async {
        lastErrorMessage = nil
        loadProgress = LoadProgress()
        finish(.location)
        start(.weather)

        do {
            let weather: Weather = try await withTimeout(10, operation: {
                try await sharedWeatherService.weather(for: location)
            })
            finish(.weather)

            let end: Date = Calendar.current.date(byAdding: .hour, value: 24, to: now) ?? now
            let hours = weather.hourlyForecast.forecast
            let window: [HourWeather] = hours.filter { $0.date >= now && $0.date <= end }
            let mapped: [ForecastPoint] = window.map { h in
                let tempF = h.temperature.converted(to: UnitTemperature.fahrenheit).value
                let tempC = h.temperature.converted(to: UnitTemperature.celsius).value
                let dewF = h.dewPoint.converted(to: UnitTemperature.fahrenheit).value
                let rh = h.humidity
                let seaLevelPa = h.pressure.converted(to: .newtonsPerMetersSquared).value
                let altitudeM = location.altitude
                let stationPa = seaLevelPa * pow(1 - 0.0065 * altitudeM / (tempC + 0.0065 * altitudeM + 273.15), -5.257)
                let wetF = PsychrometryCalculator.psych(pressurePa: stationPa, dryBulbFahrenheit: tempF, relativeHumidity: rh)
                let windMPH = h.wind.speed.converted(to: UnitSpeed.milesPerHour).value
                let precip = Double(h.precipitationChance)
                return ForecastPoint(date: h.date, temperatureF: tempF, wetBulbF: wetF, dewPointF: dewF, precipProbability: precip, windSpeedMPH: windMPH)
            }
            self.series24h = ForecastSeries(points: mapped)

            let end2: Date = Calendar.current.date(byAdding: .hour, value: 240, to: now) ?? now
            let hours2 = weather.hourlyForecast.forecast
            let window2: [HourWeather] = hours2.filter { $0.date >= now && $0.date <= end2 }
            let mapped2: [ForecastPoint] = window2.map { h in
                let tempF = h.temperature.converted(to: UnitTemperature.fahrenheit).value
                let tempC = h.temperature.converted(to: UnitTemperature.celsius).value
                let dewF = h.dewPoint.converted(to: UnitTemperature.fahrenheit).value
                let rh = h.humidity
                let seaLevelPa = h.pressure.converted(to: .newtonsPerMetersSquared).value
                let altitudeM = location.altitude
                let stationPa = seaLevelPa * pow(1 - 0.0065 * altitudeM / (tempC + 0.0065 * altitudeM + 273.15), -5.257)
                let wetF = PsychrometryCalculator.psych(pressurePa: stationPa, dryBulbFahrenheit: tempF, relativeHumidity: rh)
                let windMPH = h.wind.speed.converted(to: UnitSpeed.milesPerHour).value
                let precip = Double(h.precipitationChance)
                return ForecastPoint(date: h.date, temperatureF: tempF, wetBulbF: wetF, dewPointF: dewF, precipProbability: precip, windSpeedMPH: windMPH)
            }
            self.series10d = ForecastSeries(points: mapped2)

            start(.geocode)
            if #available(iOS 26.0, *) {
                // Use MKLocalSearch to obtain an MKMapItem near the coordinate, then use its address
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = nil
                let span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                request.region = MKCoordinateRegion(center: location.coordinate, span: span)
                let mapItem: MKMapItem? = try? await withTimeout(6, operation: {
                    let search = MKLocalSearch(request: request)
                    let response = try await search.start()
                    // Choose the first result, or nil if none found
                    return response.mapItems.first
                })
                if let item = mapItem {
                    // Prefer a readable title from the placemark, then the item name, else coordinates
                    if self.placeDescription.isEmpty {
                        if let title = item.placemark.title, !title.isEmpty {
                            self.placeDescription = title
                        } else if let name = item.name, !name.isEmpty {
                            self.placeDescription = name
                        } else {
                            self.placeDescription = "\(location.coordinate.latitude), \(location.coordinate.longitude)"
                        }
                    }
                }
            } else {
                // Fallback: Reverse geocode using CLGeocoder
                let placemark: CLPlacemark? = try? await withTimeout(6, operation: {
                    let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                    return placemarks.first
                })
                if let p = placemark {
                    let locality = p.locality ?? p.subAdministrativeArea
                    let thoroughfare = p.thoroughfare
                    self.placeDescription = [thoroughfare, locality].compactMap { $0 }.joined(separator: ", ")
                }
            }
            finish(.geocode)
        } catch {
            if case .inProgress = loadProgress.steps[.geocode] {
                fail(.geocode, error: error)
            } else if case .inProgress = loadProgress.steps[.weather] {
                fail(.weather, error: error)
            }
            self.lastErrorMessage = error.localizedDescription
            print("Weather load failed: \(error.localizedDescription)")
        }
    }
}


import Foundation
import Combine
import CoreLocation
import WeatherKit

// Value-type copy of WeatherAttribution so views don't need to import WeatherKit.
struct WeatherAttributionInfo {
    let lightLogoURL: URL
    let darkLogoURL: URL
    let legalPageURL: URL
}

enum LoadStep: String, CaseIterable, Identifiable {
    case location = "Get location"
    case weather  = "Fetch forecast"
    case geocode  = "Reverse geocode"
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
        .weather:  .pending,
        .geocode:  .pending
    ]
}

private func withTimeout<T>(
    _ seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "WeatherService", code: -1001,
                          userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw NSError(domain: "WeatherService", code: -1002,
                          userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
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

    func requestLocation() { manager.requestLocation() }

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

final class WeatherService: ObservableObject {
    @Published var series24h: [ForecastPoint] = []
    @Published var series10d: [ForecastPoint] = []
    @Published var current: ForecastPoint? = nil
    @Published var placeDescription: String = ""
    @Published var loadProgress: LoadProgress = LoadProgress()
    @Published var lastErrorMessage: String? = nil
    @Published var attribution: WeatherAttributionInfo? = nil
    @Published var isRefreshing: Bool = false
    @Published var lastFetchedAt: Date? = nil

    private var loadGeneration = 0

    private func start(_ step: LoadStep)              { loadProgress.steps[step] = .inProgress(startedAt: Date()) }
    private func finish(_ step: LoadStep)             { loadProgress.steps[step] = .success }
    private func fail(_ step: LoadStep, error: Error) { loadProgress.steps[step] = .failure(error) }

    func loadFor(location: CLLocation, now: Date = .now, preserveData: Bool = false) async {
        // Only keep existing data visible when there is actually data to show.
        let shouldPreserve = preserveData && !series24h.isEmpty
        loadGeneration += 1
        let gen = loadGeneration

        isRefreshing     = false           // cancel any prior refresh indicator
        lastErrorMessage = nil
        loadProgress     = LoadProgress()
        if shouldPreserve {
            isRefreshing = true            // keep existing data; show spinner above content
        } else {
            placeDescription = ""
            series24h        = []
            series10d        = []
            current          = nil
        }
        finish(.location)
        start(.weather)

        do {
            let weather: Weather = try await withTimeout(10) {
                try await sharedWeatherService.weather(for: location)
            }
            guard loadGeneration == gen else { return }
            finish(.weather)

            let hours = weather.hourlyForecast.forecast
            series24h = WeatherMapping.mapPoints(from: hours, start: now,
                                   end: now.addingTimeInterval(24 * 3600), location: location)
            series10d = WeatherMapping.mapPoints(from: hours, start: now,
                                   end: now.addingTimeInterval(240 * 3600), location: location)
            current   = WeatherMapping.mapCurrent(weather.currentWeather, location: location)
            isRefreshing  = false          // new data is in; hide spinner
            lastFetchedAt = Date()

            guard loadGeneration == gen else { return }
            start(.geocode)
            let placemark = try? await withTimeout(6) {
                try await CLGeocoder().reverseGeocodeLocation(location).first
            }
            guard loadGeneration == gen else { return }

            if let p = placemark {
                let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let parts  = [street.isEmpty ? nil : street,
                              p.locality ?? p.subAdministrativeArea].compactMap { $0 }
                placeDescription = parts.isEmpty
                    ? String(format: "%.4f, %.4f",
                              location.coordinate.latitude, location.coordinate.longitude)
                    : parts.joined(separator: ", ")
            } else {
                placeDescription = String(format: "%.4f, %.4f",
                                          location.coordinate.latitude, location.coordinate.longitude)
            }
            finish(.geocode)

            if attribution == nil {
                if let wa = try? await sharedWeatherService.attribution {
                    guard loadGeneration == gen else { return }
                    attribution = WeatherAttributionInfo(
                        lightLogoURL: wa.combinedMarkLightURL,
                        darkLogoURL:  wa.combinedMarkDarkURL,
                        legalPageURL: wa.legalPageURL
                    )
                }
            }
        } catch {
            guard loadGeneration == gen else { return }
            isRefreshing = false
            if case .inProgress = loadProgress.steps[.geocode] {
                fail(.geocode, error: error)
            } else if case .inProgress = loadProgress.steps[.weather] {
                fail(.weather, error: error)
            }
            lastErrorMessage = error.localizedDescription
            print("Weather load failed: \(error.localizedDescription)")
        }
    }
}

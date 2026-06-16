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
    /// Observed/analysed past ~24 h, oldest → newest (kind .historic).
    @Published var historic24h: [ForecastPoint] = []
    /// Apple's current-conditions nowcast (kind .current); nil until loaded.
    @Published var current: ForecastPoint? = nil
    /// True when the historic query returned nothing for this location/time.
    /// Drives a small note in the table; the graphs simply omit history.
    @Published var historicUnavailable: Bool = false
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

    /// Station pressure (Pa) and wet-bulb temperatures (°F/°C) derived from
    /// sea-level pressure, dry-bulb temperature and humidity at this location's
    /// altitude. Shared by the hourly and current-conditions mappers.
    private func derived(
        seaLevelPa: Double, tempF: Double, tempC: Double, rh: Double,
        location: CLLocation
    ) -> (stationPa: Double, wetF: Double, wetC: Double) {
        let altitudeM = location.altitude
        let stationPa = seaLevelPa * pow(
            1 - 0.0065 * altitudeM / (tempC + 0.0065 * altitudeM + 273.15), -5.257)
        let wetF = PsychrometryCalculator.psychF(pressurePa: stationPa,
                                                 dryBulbFahrenheit: tempF,
                                                 relativeHumidity: rh)
        let wetC = PsychrometryCalculator.psychC(pressurePa: stationPa,
                                                 dryBulbCelsius: tempC,
                                                 relativeHumidity: rh)
        return (stationPa, wetF, wetC)
    }

    private func mapPoints(
        from hours: [HourWeather],
        start: Date, end: Date,
        location: CLLocation,
        kind: ForecastPoint.Kind = .forecast
    ) -> [ForecastPoint] {
        hours.filter { $0.date >= start && $0.date <= end }.map { h in
            let tempF      = h.temperature.converted(to: .fahrenheit).value
            let tempC      = h.temperature.converted(to: .celsius).value
            let apparentF  = h.apparentTemperature.converted(to: .fahrenheit).value
            let apparentC  = h.apparentTemperature.converted(to: .celsius).value
            let dewF       = h.dewPoint.converted(to: .fahrenheit).value
            let dewC       = h.dewPoint.converted(to: .celsius).value
            let rh         = h.humidity
            let seaLevelPa = h.pressure.converted(to: .newtonsPerMetersSquared).value
            let d          = derived(seaLevelPa: seaLevelPa, tempF: tempF, tempC: tempC,
                                     rh: rh, location: location)
            let windMPH    = h.wind.speed.converted(to: .milesPerHour).value
            let windKPH    = h.wind.speed.converted(to: .kilometersPerHour).value
            // WeatherKit gust is optional — fall back to sustained wind when absent.
            let gustMPH    = h.wind.gust?.converted(to: .milesPerHour).value ?? windMPH
            let gustKPH    = h.wind.gust?.converted(to: .kilometersPerHour).value ?? windKPH
            let precipMM   = h.precipitationAmount.converted(to: .millimeters).value

            // cloudCoverByAltitude: available in WeatherKit on iOS 18+.
            // Each property is in the 0-1 range. If this line does not compile,
            // replace the three lines below with 0.0 and file a radar.
            let cloudByAlt  = h.cloudCoverByAltitude
            let cloudLow    = cloudByAlt.low
            let cloudMid    = cloudByAlt.medium
            let cloudHigh   = cloudByAlt.high

            return ForecastPoint(
                kind:                 kind,
                date:                 h.date,
                symbolName:           h.symbolName,
                isDaylight:           h.isDaylight,
                uvIndex:              Double(h.uvIndex.value),
                temperatureF:         tempF,
                temperatureC:         tempC,
                apparentTemperatureF: apparentF,
                apparentTemperatureC: apparentC,
                wetBulbF:             d.wetF,
                wetBulbC:             d.wetC,
                dewPointF:            dewF,
                dewPointC:            dewC,
                precipProbability:    Double(h.precipitationChance),
                precipitationMM:      precipMM,
                windSpeedMPH:         windMPH,
                windSpeedKPH:         windKPH,
                windGustMPH:          gustMPH,
                windGustKPH:          gustKPH,
                cloudCover:           h.cloudCover,
                cloudCoverLow:        cloudLow,
                cloudCoverMedium:     cloudMid,
                cloudCoverHigh:       cloudHigh,
                humidity:             rh,
                stationPressurePa:    d.stationPa
            )
        }
    }

    /// Map Apple's current-conditions nowcast to a ForecastPoint(kind: .current).
    /// CurrentWeather has no precipitation or cloud-cover-by-altitude, so those
    /// fields are filled with 0 — the table blanks them based on `kind`.
    private func mapCurrent(_ c: CurrentWeather, location: CLLocation) -> ForecastPoint {
        let tempF      = c.temperature.converted(to: .fahrenheit).value
        let tempC      = c.temperature.converted(to: .celsius).value
        let apparentF  = c.apparentTemperature.converted(to: .fahrenheit).value
        let apparentC  = c.apparentTemperature.converted(to: .celsius).value
        let dewF       = c.dewPoint.converted(to: .fahrenheit).value
        let dewC       = c.dewPoint.converted(to: .celsius).value
        let rh         = c.humidity
        let seaLevelPa = c.pressure.converted(to: .newtonsPerMetersSquared).value
        let d          = derived(seaLevelPa: seaLevelPa, tempF: tempF, tempC: tempC,
                                 rh: rh, location: location)
        let windMPH    = c.wind.speed.converted(to: .milesPerHour).value
        let windKPH    = c.wind.speed.converted(to: .kilometersPerHour).value
        let gustMPH    = c.wind.gust?.converted(to: .milesPerHour).value ?? windMPH
        let gustKPH    = c.wind.gust?.converted(to: .kilometersPerHour).value ?? windKPH

        return ForecastPoint(
            kind:                 .current,
            date:                 c.date,
            symbolName:           c.symbolName,
            isDaylight:           c.isDaylight,
            uvIndex:              Double(c.uvIndex.value),
            temperatureF:         tempF,
            temperatureC:         tempC,
            apparentTemperatureF: apparentF,
            apparentTemperatureC: apparentC,
            wetBulbF:             d.wetF,
            wetBulbC:             d.wetC,
            dewPointF:            dewF,
            dewPointC:            dewC,
            precipProbability:    0,      // not provided by CurrentWeather
            precipitationMM:      0,      // not provided by CurrentWeather
            windSpeedMPH:         windMPH,
            windSpeedKPH:         windKPH,
            windGustMPH:          gustMPH,
            windGustKPH:          gustKPH,
            cloudCover:           c.cloudCover,
            cloudCoverLow:        0,      // not provided by CurrentWeather
            cloudCoverMedium:     0,      // not provided by CurrentWeather
            cloudCoverHigh:       0,      // not provided by CurrentWeather
            humidity:             rh,
            stationPressurePa:    d.stationPa
        )
    }

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
            historic24h      = []
            current          = nil
            historicUnavailable = false
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
            series24h = mapPoints(from: hours, start: now,
                                   end: now.addingTimeInterval(24 * 3600), location: location)
            series10d = mapPoints(from: hours, start: now,
                                   end: now.addingTimeInterval(240 * 3600), location: location)
            // "now" point from Apple's current-conditions nowcast.
            current = mapCurrent(weather.currentWeather, location: location)
            isRefreshing  = false          // new data is in; hide spinner
            lastFetchedAt = Date()

            // Observed past ~24 h — a separate query that must not break the
            // forecast if it fails. Empty result → note shown in the table only.
            let histStart = now.addingTimeInterval(-24 * 3600)
            let histWeather = try? await withTimeout(10) {
                try await sharedWeatherService.weather(
                    for: location,
                    including: .hourly(startDate: histStart, endDate: now))
            }
            guard loadGeneration == gen else { return }
            if let histWeather {
                let pts = mapPoints(from: histWeather.forecast,
                                    start: histStart, end: now,
                                    location: location, kind: .historic)
                historic24h = pts
                historicUnavailable = pts.isEmpty
            } else {
                historic24h = []
                historicUnavailable = true
            }

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

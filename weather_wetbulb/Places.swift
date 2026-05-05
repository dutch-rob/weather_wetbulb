import Foundation
import CoreLocation
import Combine
import SwiftUI
import WeatherKit

// MARK: - Place model

struct Place: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var altitude: Double   // metres above sea level; 0 when unknown

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, altitude: Double = 0) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    // Backward-compatible decode: altitude was added later; treat missing key as 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        latitude  = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        altitude  = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? 0
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // Full CLLocation including stored altitude, used for psychrometry and weather fetch.
    var clLocation: CLLocation {
        CLLocation(coordinate: coordinate, altitude: altitude,
                   horizontalAccuracy: -1, verticalAccuracy: altitude == 0 ? -1 : 1,
                   timestamp: Date())
    }
}

// MARK: - PlaceWeatherSnapshot

struct PlaceWeatherSnapshot {
    let symbolName: String
    let isDaylight: Bool
    let uvIndex: Double
    let temperatureF: Double
    let temperatureC: Double
    let apparentTemperatureF: Double
    let apparentTemperatureC: Double
    let windSpeedMPH: Double
    let windSpeedKPH: Double
    let precipitationMM: Double
    let precipChance: Double    // 0–1
    let fetchedAt: Date
}

// MARK: - PlacesViewModel

private let placesWeatherKit = WeatherKit.WeatherService()

final class PlacesViewModel: ObservableObject {
    private let storageKey = "SavedPlaces_v1"
    private var icloudObserver: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    @Published var places: [Place]
    @Published var placesWeather: [UUID: PlaceWeatherSnapshot] = [:]
    private var lastRefresh: Date?

    private static let defaults: [Place] = [
        Place(name: "Phoenix, AZ",        latitude:  33.4484, longitude: -112.0740, altitude:  331),
        Place(name: "Albuquerque, NM",    latitude:  35.0844, longitude: -106.6504, altitude: 1510),
        Place(name: "Las Vegas, NV",      latitude:  36.1699, longitude: -115.1398, altitude:  620),
        Place(name: "Salt Lake City, UT", latitude:  40.7608, longitude: -111.8910, altitude: 1288),
        Place(name: "Adelaide",           latitude: -34.9285, longitude:  138.6007, altitude:   50),
        Place(name: "Ankara",             latitude:  39.9334, longitude:   32.8597, altitude:  938),
        Place(name: "New Delhi",          latitude:  28.6139, longitude:   77.2090, altitude:  216),
        Place(name: "Cairo",              latitude:  30.0444, longitude:   31.2357, altitude:   23)
    ]

    init() {
        NSUbiquitousKeyValueStore.default.synchronize()

        if let data = NSUbiquitousKeyValueStore.default.data(forKey: "SavedPlaces_v1"),
           let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            self.places = decoded
        } else if let data = UserDefaults.standard.data(forKey: "SavedPlaces_v1"),
                  let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            self.places = decoded
        } else {
            self.places = Self.defaults
        }

        icloudObserver = NotificationCenter.default
            .publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                       object: NSUbiquitousKeyValueStore.default)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      let data = NSUbiquitousKeyValueStore.default.data(forKey: self.storageKey),
                      let decoded = try? JSONDecoder().decode([Place].self, from: data)
                else { return }
                self.places = decoded
            }

        // Refresh place weather in background every 20 minutes.
        timerCancellable = Timer.publish(every: 1200, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshWeatherForAllPlaces()
            }
    }

    // Only fetches if last refresh was more than 20 minutes ago.
    func refreshWeatherIfNeeded() {
        let interval: TimeInterval = 20 * 60
        if let last = lastRefresh, Date().timeIntervalSince(last) < interval { return }
        refreshWeatherForAllPlaces()
    }

    func refreshWeatherForAllPlaces() {
        lastRefresh = Date()
        let snapshot = places   // value-type copy; safe to read off-main
        refreshTask?.cancel()
        refreshTask = Task {
            for place in snapshot {
                guard !Task.isCancelled else { return }
                guard let wd = try? await placesWeatherKit.weather(for: place.clLocation) else { continue }
                let now = Date()
                let hours = wd.hourlyForecast.forecast
                guard let nearest = hours.min(by: {
                    abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now))
                }) else { continue }
                let snap = PlaceWeatherSnapshot(
                    symbolName:           nearest.symbolName,
                    isDaylight:           nearest.isDaylight,
                    uvIndex:              Double(nearest.uvIndex.value),
                    temperatureF:         nearest.temperature.converted(to: .fahrenheit).value,
                    temperatureC:         nearest.temperature.converted(to: .celsius).value,
                    apparentTemperatureF: nearest.apparentTemperature.converted(to: .fahrenheit).value,
                    apparentTemperatureC: nearest.apparentTemperature.converted(to: .celsius).value,
                    windSpeedMPH:         nearest.wind.speed.converted(to: .milesPerHour).value,
                    windSpeedKPH:         nearest.wind.speed.converted(to: .kilometersPerHour).value,
                    precipitationMM:      nearest.precipitationAmount.converted(to: .millimeters).value,
                    precipChance:         Double(nearest.precipitationChance),
                    fetchedAt:            Date()
                )
                placesWeather[place.id] = snap
            }
        }
    }

    func addPlace(name: String, coordinate: CLLocationCoordinate2D) {
        places.append(Place(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude))
        save()
    }

    func removePlaces(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        save()
    }

    func remove(_ place: Place) {
        if let idx = places.firstIndex(of: place) {
            places.remove(at: idx)
            save()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        places.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func update(_ place: Place, name: String, coordinate: CLLocationCoordinate2D) {
        guard let idx = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[idx].name      = name
        places[idx].latitude  = coordinate.latitude
        places[idx].longitude = coordinate.longitude
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NSUbiquitousKeyValueStore.default.set(data, forKey: storageKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

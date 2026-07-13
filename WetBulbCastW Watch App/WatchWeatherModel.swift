//
//  WatchWeatherModel.swift
//  WetBulbCastW Watch App
//
//  Fetches the watch's own location + WeatherKit forecast, maps it with the
//  shared WeatherMapping, and writes the complication snapshot. The watch does
//  its own fetch (no forecast comes over WatchConnectivity).
//

import Foundation
import CoreLocation
import WeatherKit
import Combine
import WidgetKit

@MainActor
final class WatchWeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var series24h: [ForecastPoint] = []
    @Published var series10d: [ForecastPoint] = []
    /// Observed past ~1 day (kind .historic), so the 10-day chart's first daily
    /// column is complete (a full first bar, like the phone).
    @Published var historic: [ForecastPoint] = []
    @Published var current: ForecastPoint?
    @Published var isLoading = false
    @Published var errorText: String?
    /// nil = current location; otherwise a place synced from the phone.
    @Published var selectedPlace: PlaceDTO?

    var placeName: String { selectedPlace?.name ?? "Current Location" }

    private let manager = CLLocationManager()
    private let weatherService = WeatherKit.WeatherService()
    /// When the current forecast was last fetched, so wrist-raises don't trigger
    /// a fresh WeatherKit call + location request + complication reload every
    /// time (a notable battery cost). Data this fresh is reused as-is.
    private var lastLoadedAt: Date?
    private static let freshWindow: TimeInterval = 15 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
    }

    /// Fetch the forecast. On a wrist-raise / app activation this is called
    /// without `force`, so if the data is still fresh (< 15 min) it does
    /// nothing. `force` (place change, manual refresh) always refetches.
    func refresh(force: Bool = false) {
        if !force, !series10d.isEmpty, let last = lastLoadedAt,
           Date().timeIntervalSince(last) < Self.freshWindow {
            return
        }
        isLoading = true
        if let p = selectedPlace {
            let loc = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                altitude: p.altitude, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: Date())
            Task { await load(for: loc) }
        } else {
            manager.requestLocation()
        }
    }

    /// Switch to a place (nil = back to current location) and refetch.
    func select(_ place: PlaceDTO?) {
        selectedPlace = place
        refresh(force: true)
    }

    /// A fresh settings sync arrived — rewrite the complication snapshot so it
    /// reflects the new units, without a new weather fetch.
    func syncChanged() {
        writeSnapshot()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { await self.load(for: loc) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorText = error.localizedDescription
            self.isLoading = false
        }
    }

    // MARK: Fetch + map

    private func load(for location: CLLocation) async {
        do {
            let now = Date()
            let weather = try await weatherService.weather(for: location)
            let hours = weather.hourlyForecast.forecast
            let s24 = WeatherMapping.mapPoints(from: hours, start: now,
                                               end: now.addingTimeInterval(24 * 3600),
                                               location: location)
            let s10 = WeatherMapping.mapPoints(from: hours, start: now,
                                               end: now.addingTimeInterval(240 * 3600),
                                               location: location)
            let cur = WeatherMapping.mapCurrent(weather.currentWeather, location: location)

            // Observed past — a separate query (like the phone) starting at 00:00
            // of the previous day, so the 10-day chart's first daily column is
            // complete. Non-fatal: a failure just leaves the first bar partial.
            let cal = Calendar.current
            let histStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
                ?? now.addingTimeInterval(-48 * 3600)
            let histWeather = try? await weatherService.weather(
                for: location, including: .hourly(startDate: histStart, endDate: now))
            let hist = histWeather.map {
                WeatherMapping.mapPoints(from: $0.forecast, start: histStart, end: now,
                                         location: location, kind: .historic)
            } ?? []

            series24h = s24
            series10d = s10
            historic  = hist
            current   = cur
            isLoading = false
            errorText = nil
            lastLoadedAt = Date()
            BackgroundWeatherRefresh.saveLocation(location)   // for background refresh
            writeSnapshot()
        } catch {
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: Complication snapshot

    private func writeSnapshot() {
        WatchComplicationWriter.write(
            current: current,
            series10d: series10d,
            useFahrenheit: WatchSyncReceiver.shared.payload?.useFahrenheit ?? false)
    }
}

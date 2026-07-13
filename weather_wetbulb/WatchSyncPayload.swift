//
//  WatchSyncPayload.swift
//  weather_wetbulb  (shared: iOS app + watch app)
//
//  The small bundle of state the phone pushes to the watch over
//  WatchConnectivity: display settings + saved places. The watch fetches its
//  own weather, so no forecast data travels here.
//

import Foundation

/// Lightweight place for the watch (no PlacesViewModel dependency).
struct PlaceDTO: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

struct WatchSyncPayload: Codable {
    var useFahrenheit: Bool
    /// ChartStyle raw value ("classic" / "filled"); a plain String keeps this
    /// file free of any UI dependency so it compiles on the watch.
    var chartStyle: String
    var places: [PlaceDTO] = []
}

extension WatchSyncPayload {
    /// Encode for WCSession application context (a [String: Any] dictionary).
    func asApplicationContext() -> [String: Any] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return ["payload": data]
    }

    static func from(applicationContext context: [String: Any]) -> WatchSyncPayload? {
        guard let data = context["payload"] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSyncPayload.self, from: data)
    }
}

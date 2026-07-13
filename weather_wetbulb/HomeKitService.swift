//
//  HomeKitService.swift
//  weather_wetbulb
//
//  Reads indoor temperature / humidity / climate-control state from HomeKit.
//  The HMHomeManager is created lazily (only when the user turns on indoor
//  tracking) because instantiating it triggers the HomeKit permission prompt.
//

import Foundation
import HomeKit
import Combine

/// One selectable HomeKit characteristic (a single reading source).
struct DiscoveredSensor: Identifiable, Hashable {
    enum Kind: String, Codable {
        case temperature, humidity, hvacState, hvacTarget

        var title: String {
            switch self {
            case .temperature: return "Temperature"
            case .humidity:    return "Humidity"
            case .hvacState:   return "Climate state"
            case .hvacTarget:  return "Target temp"
            }
        }
    }

    /// Stable id = the characteristic's unique identifier.
    let id: String
    let accessoryName: String
    let roomName: String
    let kind: Kind

    var label: String { "\(accessoryName) — \(kind.title)" }
}

/// Aggregated indoor reading over the user's selected sensors.
struct IndoorAggregate {
    var tempC: Double?
    var humidity: Double?          // 0…1
    var sensorCount: Int = 0       // temperature sensors that contributed
    var hvacMode: Int?             // 0 off/idle, 1 heating, 2 cooling
    var hvacTargetTempC: Double?
    var perSensorJSON: Data?
}

@MainActor
final class HomeKitService: NSObject, ObservableObject, HMHomeManagerDelegate {
    static let shared = HomeKitService()

    @Published private(set) var sensors: [DiscoveredSensor] = []
    @Published private(set) var isAuthorized = false
    @Published private(set) var didLoad = false

    private var manager: HMHomeManager?
    /// Runtime map id → live characteristic, rebuilt whenever homes change.
    private var characteristics: [String: HMCharacteristic] = [:]

    private override init() { super.init() }

    /// Create the manager (prompting for permission the first time) and start
    /// discovering. Safe to call repeatedly.
    func start() {
        guard manager == nil else { return }
        manager = HMHomeManager()
        manager?.delegate = self
    }

    // MARK: HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ mgr: HMHomeManager) {
        rebuild(from: mgr)
    }

    func homeManager(_ mgr: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        isAuthorized = status.contains(.authorized)
    }

    private func rebuild(from mgr: HMHomeManager) {
        isAuthorized = mgr.authorizationStatus.contains(.authorized)
        var found: [DiscoveredSensor] = []
        var map: [String: HMCharacteristic] = [:]

        for home in mgr.homes {
            for accessory in home.accessories {
                let room = accessory.room?.name ?? home.name
                for service in accessory.services {
                    for c in service.characteristics {
                        guard let kind = Self.kind(for: c.characteristicType) else { continue }
                        let id = c.uniqueIdentifier.uuidString
                        found.append(DiscoveredSensor(id: id, accessoryName: accessory.name,
                                                      roomName: room, kind: kind))
                        map[id] = c
                    }
                }
            }
        }
        sensors = found.sorted { ($0.roomName, $0.label) < ($1.roomName, $1.label) }
        characteristics = map
        didLoad = true
    }

    /// Map a HomeKit characteristic type to one of our sensor kinds (nil = not
    /// one we track).
    private static func kind(for type: String) -> DiscoveredSensor.Kind? {
        switch type {
        case HMCharacteristicTypeCurrentTemperature:        return .temperature
        case HMCharacteristicTypeCurrentRelativeHumidity:   return .humidity
        case HMCharacteristicTypeCurrentHeatingCooling,
             HMCharacteristicTypeCurrentHeaterCoolerState:  return .hvacState
        case HMCharacteristicTypeTargetTemperature:         return .hvacTarget
        default: return nil
        }
    }

    // MARK: Reading

    /// Read the currently-selected sensors and aggregate them. Temperatures and
    /// humidities are averaged; the first available HVAC state / target is used.
    func readSelectedSensors(ids: [String]) async -> IndoorAggregate {
        var temps: [Double] = []
        var hums: [Double] = []
        var hvacStates: [Int] = []
        var hvacTargets: [Double] = []
        var perSensor: [[String: Any]] = []

        for id in ids {
            guard let c = characteristics[id] else { continue }
            guard let value = await read(c) else { continue }
            switch Self.kind(for: c.characteristicType) {
            case .temperature:
                if let t = (value as? NSNumber)?.doubleValue {
                    temps.append(t)
                    perSensor.append(["uuid": id, "tempC": t])
                }
            case .humidity:
                if let h = (value as? NSNumber)?.doubleValue {
                    hums.append(h / 100.0)
                    perSensor.append(["uuid": id, "rh": h / 100.0])
                }
            case .hvacState:
                if let s = (value as? NSNumber)?.intValue {
                    hvacStates.append(Self.normalizeHVAC(s, type: c.characteristicType))
                }
            case .hvacTarget:
                if let t = (value as? NSNumber)?.doubleValue { hvacTargets.append(t) }
            case .none:
                break
            }
        }

        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        return IndoorAggregate(
            tempC: mean(temps),
            humidity: mean(hums),
            sensorCount: temps.count,
            hvacMode: hvacStates.first,
            hvacTargetTempC: hvacTargets.first,
            perSensorJSON: try? JSONSerialization.data(withJSONObject: perSensor))
    }

    /// Read one characteristic's current value (nil on error).
    private func read(_ c: HMCharacteristic) async -> Any? {
        await withCheckedContinuation { cont in
            c.readValue { error in
                cont.resume(returning: error == nil ? c.value : nil)
            }
        }
    }

    /// Normalize HomeKit's two climate encodings to 0 off/idle, 1 heating, 2 cooling.
    private static func normalizeHVAC(_ raw: Int, type: String) -> Int {
        if type == HMCharacteristicTypeCurrentHeaterCoolerState {
            // 0 inactive, 1 idle, 2 heating, 3 cooling
            switch raw { case 2: return 1; case 3: return 2; default: return 0 }
        }
        // Thermostat CurrentHeatingCooling: 0 off, 1 heat, 2 cool
        return raw
    }
}

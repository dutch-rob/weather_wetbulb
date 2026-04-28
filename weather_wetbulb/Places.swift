import Foundation
import CoreLocation
import Combine
import SwiftUI

struct Place: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

final class PlacesViewModel: ObservableObject {
    private let storageKey = "SavedPlaces_v1"
    
    @Published var places: [Place]
    @Published var selected: Place? = nil

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            self.places = decoded
        } else {
            self.places = [
                Place(name: "Irvine", latitude: 33.6846, longitude: -117.8265),
                Place(name: "Yucca Valley", latitude: 34.1142, longitude: -116.4322),
                Place(name: "Soest", latitude: 52.1733, longitude: 5.2917),
                Place(name: "New York", latitude: 40.7128, longitude: -74.0060)
            ]
            save()
        }
    }

    func addPlace(name: String, coordinate: CLLocationCoordinate2D) {
        let place = Place(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
        places.append(place)
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

    private func save() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

import Foundation
import CoreLocation

struct Place: Identifiable, Equatable {
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
    @Published var places: [Place]
    @Published var selected: Place? = nil

    init() {
        // Default places
        self.places = [
            Place(name: "Irvine", latitude: 33.6846, longitude: -117.8265),
            Place(name: "Yucca Valley", latitude: 34.1142, longitude: -116.4322),
            Place(name: "Soest", latitude: 52.1733, longitude: 5.2917),
            Place(name: "New York", latitude: 40.7128, longitude: -74.0060)
        ]
    }

    func addPlace(name: String, coordinate: CLLocationCoordinate2D) {
        let place = Place(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
        places.append(place)
    }

    func removePlaces(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
    }

    func remove(_ place: Place) {
        if let idx = places.firstIndex(of: place) { places.remove(at: idx) }
    }
}

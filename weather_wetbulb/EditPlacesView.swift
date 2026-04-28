import SwiftUI
import MapKit

struct EditPlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlacesViewModel

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedCoordinate: CLLocationCoordinate2D? = nil
    @State private var newPlaceName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top half: list of places with delete controls
            List {
                ForEach(viewModel.places) { place in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(place.name)
                            Text(String(format: "%.4f, %.4f", place.latitude, place.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.remove(place)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom half: map + add place controls
            VStack(alignment: .leading, spacing: 8) {
                Map(position: $mapPosition, interactionModes: .all, showsUserLocation: true)
                    .onTapGesture { location in
                        selectedCoordinate = location
                    }
                    .frame(height: 260)

                if let coord = selectedCoordinate {
                    Text(String(format: "Selected: %.4f, %.4f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap on the map to pick a place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("Place name", text: $newPlaceName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add place") {
                        if let coord = selectedCoordinate, !newPlaceName.trimmingCharacters(in: .whitespaces).isEmpty {
                            viewModel.addPlace(name: newPlaceName, coordinate: coord)
                            newPlaceName = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle("Edit places")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            if case let .userLocation(center) = mapPosition { return }
            if let first = viewModel.places.first {
                mapPosition = .region(MKCoordinateRegion(center: first.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
            }
        }
    }
}

#Preview {
    NavigationStack {
        EditPlacesView(viewModel: PlacesViewModel())
    }
}

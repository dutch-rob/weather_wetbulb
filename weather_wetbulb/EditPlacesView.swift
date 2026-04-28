import SwiftUI
import MapKit

struct EditPlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlacesViewModel

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var centerCoordinate: CLLocationCoordinate2D? = nil
    @State private var newPlaceName: String = ""
    @State private var isEditing: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Top half: list of places with delete controls and drag handles
            List {
                ForEach(viewModel.places) { place in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
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
                .onMove(perform: viewModel.move)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom half: map + add place controls
            VStack(alignment: .leading, spacing: 8) {
                Map(position: $mapPosition, interactionModes: .all)
                    .onMapCameraChange { context in
                        centerCoordinate = context.region.center
                    }
                    .frame(height: 260)
                    .overlay(alignment: .center) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                    }

                if let coord = centerCoordinate {
                    Text(String(format: "Selected: %.4f, %.4f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pan the map to position the pin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("Place name", text: $newPlaceName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add place") {
                        if let coord = centerCoordinate, !newPlaceName.trimmingCharacters(in: .whitespaces).isEmpty {
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
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            if case .automatic = mapPosition {
                if let first = viewModel.places.first {
                    mapPosition = .region(MKCoordinateRegion(center: first.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        EditPlacesView(viewModel: PlacesViewModel())
    }
}

import SwiftUI
import MapKit
import CoreLocation

// MARK: - EditPlacesView (list)

struct EditPlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlacesViewModel

    @State private var editingPlace: Place? = nil
    @State private var showEditor = false
    @State private var addingNew  = false

    var body: some View {
        List {
            ForEach(viewModel.places) { place in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)

                    Button {
                        editingPlace = place
                        showEditor   = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            Text(String(format: "%.4f, %.4f", place.latitude, place.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        viewModel.remove(place)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Edit places")
        // EditButton removed — drag handles come from .environment(\.editMode, .constant(.active))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingNew = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            EditPlaceView(viewModel: viewModel, existingPlace: editingPlace)
        }
        .navigationDestination(isPresented: $addingNew) {
            EditPlaceView(viewModel: viewModel, existingPlace: nil)
        }
    }
}

// MARK: - EditPlaceView (map + name, shared for add and edit)

struct EditPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlacesViewModel

    var existingPlace: Place?

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var centerCoordinate: CLLocationCoordinate2D? = nil
    @State private var placeName: String = ""
    @State private var isGeocoding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(position: $mapPosition, interactionModes: .all)
                .onMapCameraChange { context in
                    centerCoordinate = context.region.center
                }
                .frame(maxHeight: .infinity)
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
                    .padding(.horizontal)
            } else {
                Text("Pan the map to position the pin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            HStack {
                Text("place:")
                    .foregroundStyle(.secondary)
                TextField("Name (leave empty to auto-fill)", text: $placeName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // "Add place" button removed — saving is done via the toolbar Save button.
            // Code kept for reference:
            // Button("Add place") { ... }
        }
        .navigationTitle("Edit place")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Quit") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    guard let coord = centerCoordinate else { return }
                    let name = placeName.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty {
                        isGeocoding = true
                        Task {
                            let resolved = await geocodedName(for: coord)
                            commitSave(name: resolved, coordinate: coord)
                            isGeocoding = false
                            dismiss()
                        }
                    } else {
                        commitSave(name: name, coordinate: coord)
                        dismiss()
                    }
                }
                .disabled(centerCoordinate == nil || isGeocoding)
            }
        }
        .onAppear {
            if let place = existingPlace {
                placeName    = place.name
                mapPosition  = .region(MKCoordinateRegion(
                    center: place.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)))
            }
        }
    }

    private func commitSave(name: String, coordinate: CLLocationCoordinate2D) {
        if let place = existingPlace {
            viewModel.update(place, name: name, coordinate: coordinate)
        } else {
            viewModel.addPlace(name: name, coordinate: coordinate)
        }
    }

    private func geocodedName(for coordinate: CLLocationCoordinate2D) async -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        if let p = placemark {
            let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let parts  = [street.isEmpty ? nil : street,
                          p.locality ?? p.subAdministrativeArea].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }
}

#Preview("List") {
    NavigationStack {
        EditPlacesView(viewModel: PlacesViewModel())
    }
}

#Preview("Edit") {
    NavigationStack {
        EditPlaceView(
            viewModel: PlacesViewModel(),
            existingPlace: Place(name: "Irvine", latitude: 33.6846, longitude: -117.8265)
        )
    }
}

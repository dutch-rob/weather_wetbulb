import SwiftUI
import CoreLocation

// MARK: - PlacesListView

struct PlacesListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var placesVM: PlacesViewModel
    @ObservedObject var locationProvider: LocationProvider
    @ObservedObject var currentWeather: WeatherService
    var onSelect: (Place?) -> Void

    @State private var showEditPlaces = false

    // Derive a snapshot from the already-loaded 24h series.
    private var currentLocationSnap: PlaceWeatherSnapshot? {
        let now = Date()
        guard let nearest = currentWeather.series24h.min(by: {
            abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now))
        }) else { return nil }
        return PlaceWeatherSnapshot(
            symbolName:           nearest.symbolName,
            isDaylight:           nearest.isDaylight,
            uvIndex:              nearest.uvIndex,
            temperatureF:         nearest.temperatureF,
            apparentTemperatureF: nearest.apparentTemperatureF,
            windSpeedMPH:         nearest.windSpeedMPH,
            precipitationMM:      nearest.precipitationMM,
            precipChance:         nearest.precipProbability,
            fetchedAt:            now
        )
    }

    var body: some View {
        List {
            // Top item: edit the saved list
            Button {
                showEditPlaces = true
            } label: {
                Label("Edit list", systemImage: "pencil")
                    .foregroundStyle(.primary)
            }

            // Current GPS location
            Button {
                onSelect(nil)
            } label: {
                PlaceRowView(
                    name:      "Current Location",
                    latitude:  locationProvider.currentLocation?.coordinate.latitude,
                    longitude: locationProvider.currentLocation?.coordinate.longitude,
                    altitude:  locationProvider.currentLocation?.altitude,
                    snapshot:  currentLocationSnap
                )
            }
            .buttonStyle(.plain)

            // Saved places
            ForEach(placesVM.places) { place in
                Button {
                    onSelect(place)
                } label: {
                    PlaceRowView(
                        name:      place.name,
                        latitude:  place.latitude,
                        longitude: place.longitude,
                        altitude:  place.altitude == 0 ? nil : place.altitude,
                        snapshot:  placesVM.placesWeather[place.id]
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                        Text("Back")
                    }
                    .foregroundStyle(.tint)
                }
            }
        }
        .onAppear {
            placesVM.refreshWeatherIfNeeded()
        }
        .sheet(isPresented: $showEditPlaces) {
            NavigationStack {
                EditPlacesView(viewModel: placesVM)
            }
        }
    }
}

// MARK: - PlaceRowView

struct PlaceRowView: View {
    let name: String
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let snapshot: PlaceWeatherSnapshot?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Left column: name + coordinates
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let lat = latitude, let lon = longitude {
                    Text(coordString(lat: lat, lon: lon))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // Right column: weather data or loading indicator
            if let snap = snapshot {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: snap.symbolName)
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 28)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%.0f (%.0f)°F", snap.temperatureF, snap.apparentTemperatureF))
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        HStack(spacing: 8) {
                            Text(String(format: "UV %d", Int(snap.uvIndex)))
                            Text(String(format: "%.0f mph", snap.windSpeedMPH))
                            Text(precipText(snap))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } else if latitude != nil {
                // Location known but weather still loading
                ProgressView()
                    .frame(width: 44)
            }
        }
        .padding(.vertical, 6)
    }

    private func coordString(lat: Double, lon: Double) -> String {
        var s = String(format: "%.4f°,  %.4f°", lat, lon)
        if let alt = altitude {
            s += String(format: ",  %.0f m", alt)
        }
        return s
    }

    private func precipText(_ snap: PlaceWeatherSnapshot) -> String {
        if snap.precipitationMM < 0.05 {
            return String(format: "%.0f%%", snap.precipChance * 100)
        }
        return String(format: "%.1f mm", snap.precipitationMM)
    }
}

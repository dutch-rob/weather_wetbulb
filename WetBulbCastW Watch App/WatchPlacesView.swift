//
//  WatchPlacesView.swift
//  WetBulbCastW Watch App
//
//  The saved-places list (synced from the phone). Pick one to switch the
//  forecast to that location, or "Current Location" to go back.
//

import SwiftUI

struct WatchPlacesView: View {
    @ObservedObject var model: WatchWeatherModel
    @Environment(\.dismiss) private var dismiss

    private var places: [PlaceDTO] { WatchSyncReceiver.shared.payload?.places ?? [] }

    var body: some View {
        List {
            Button {
                model.select(nil); dismiss()
            } label: {
                rowLabel("Current Location", selected: model.selectedPlace == nil)
            }
            ForEach(places) { p in
                Button {
                    model.select(p); dismiss()
                } label: {
                    rowLabel(p.name, selected: model.selectedPlace?.id == p.id)
                }
            }
            if places.isEmpty {
                Text("No saved places yet. Add them in the iPhone app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Places")
    }

    @ViewBuilder private func rowLabel(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

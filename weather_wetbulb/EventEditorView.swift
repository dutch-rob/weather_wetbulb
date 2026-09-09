//
//  EventEditorView.swift
//  weather_wetbulb
//
//  Records what the heating or cooling equipment was doing, and when.
//
//  This is the manual half of the event story. Detection will later preselect
//  the same fields from the model's residuals, so the picker built here is the
//  one the confirmation flow reuses — the guess only changes what the wheels
//  start on, not what they are.
//
//  Backdating is the point, not an extra: equipment gets switched hours or days
//  before anyone opens the app, and an event filed at "now" would mislabel
//  every reading in between.
//

import SwiftUI
import SwiftData

/// What the equipment changed to, as one flat choice.
///
/// The store keeps two record types — CoolerEvent and HVACEvent — because the
/// evaporative cooler is switched independently of the thermostat. The user
/// does not care about that split: at any moment one thing is running, so the
/// picker offers one list and this decides where the row goes.
enum EquipmentChange: Int, CaseIterable, Identifiable {
    case off = 0
    case evaporativeCooler = 1
    case airConditioning = 2
    case heating = 3

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .off:               return "Nothing running"
        case .evaporativeCooler: return "Evaporative cooler"
        case .airConditioning:   return "Air conditioning"
        case .heating:           return "Heating"
        }
    }

    /// Only the thermostat has a setpoint; the swamp cooler is just on or off.
    var takesSetpoint: Bool {
        self == .airConditioning || self == .heating
    }

    /// Write this change into the store at `date`.
    func record(at date: Date, setpointC: Double?, context: ModelContext) {
        switch self {
        case .evaporativeCooler:
            context.insert(CoolerEvent(date: date, isOn: true, source: 0))
        case .off:
            // Either record type can express "off"; the timeline merges both
            // and takes whichever is latest, so one row is enough.
            context.insert(HVACEvent(date: date, mode: 0, targetTempC: nil, source: 0))
        case .airConditioning:
            context.insert(HVACEvent(date: date, mode: 2, targetTempC: setpointC, source: 0))
        case .heating:
            context.insert(HVACEvent(date: date, mode: 1, targetTempC: setpointC, source: 0))
        }
    }
}

struct EventEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false

    @State private var change: EquipmentChange = .airConditioning
    @State private var date = Date()
    @State private var hasSetpoint = false
    @State private var setpoint: Double = 22

    /// Setpoints are picked in whichever unit the rest of the app is showing,
    /// and converted on the way into the store, which is always Celsius.
    private var setpointRange: [Double] {
        useFahrenheit ? Array(stride(from: 50.0, through: 90.0, by: 1))
                      : Array(stride(from: 10.0, through: 32.0, by: 0.5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Changed to", selection: $change) {
                        ForEach(EquipmentChange.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    Text("What changed")
                }

                Section {
                    DatePicker("When", selection: $date,
                               in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.wheel)
                } header: {
                    Text("When it changed")
                } footer: {
                    Text("Set the time it actually happened, not now. Readings between this moment and the next event are attributed to it.")
                }

                if change.takesSetpoint {
                    Section {
                        Toggle("Setpoint known", isOn: $hasSetpoint)
                        if hasSetpoint {
                            Picker("Set to", selection: $setpoint) {
                                ForEach(setpointRange, id: \.self) { value in
                                    Text(formatted(value)).tag(value)
                                }
                            }
                            .pickerStyle(.wheel)
                        }
                    } header: {
                        Text("Thermostat")
                    } footer: {
                        Text("Optional. The setpoint changes how hard the system works without changing the mode, so recording it helps the model separate the two.")
                    }
                }
            }
            .navigationTitle("Add event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        useFahrenheit ? String(format: "%.0f °F", value)
                      : String(format: "%.1f °C", value)
    }

    private func save() {
        var celsius: Double?
        if change.takesSetpoint && hasSetpoint {
            celsius = useFahrenheit ? (setpoint - 32) * 5 / 9 : setpoint
        }
        change.record(at: date, setpointC: celsius, context: context)
        try? context.save()
        dismiss()
    }
}

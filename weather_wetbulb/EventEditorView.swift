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
import UIKit

/// A wheel date picker with a settable minute step.
///
/// SwiftUI's DatePicker offers no way to change the minute increment, and
/// single minutes are false precision here: nobody recalls switching the AC on
/// at 14:37, and spinning sixty positions to reach a time you are guessing at
/// is just friction.
struct SteppedDatePicker: UIViewRepresentable {
    @Binding var date: Date
    var minuteInterval: Int = 5
    var maximum: Date = Date()

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .wheels
        picker.minuteInterval = minuteInterval
        picker.maximumDate = maximum
        picker.addTarget(context.coordinator,
                         action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        picker.maximumDate = maximum
        if abs(picker.date.timeIntervalSince(date)) > 1 { picker.date = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SteppedDatePicker
        init(_ parent: SteppedDatePicker) { self.parent = parent }
        @objc func changed(_ picker: UIDatePicker) { parent.date = picker.date }
    }
}

/// What the equipment changed to, as one flat choice.
///
/// The store keeps two record types — CoolerEvent and HVACEvent — because the
/// evaporative cooler is switched independently of the thermostat. The user
/// does not care about that split: at any moment one thing is running, so the
/// picker offers one list and this decides where the row goes.
enum EquipmentChange: Int, CaseIterable, Identifiable {
    case unknown = -1
    case off = 0
    case vent = 4
    case evaporativeCooler = 1
    case airConditioning = 2
    case heating = 3

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .unknown:           return "Unknown"
        case .off:               return "Nothing running"
        case .vent:              return "Vent (cooler, no water)"
        case .evaporativeCooler: return "Evaporative cooler"
        case .airConditioning:   return "Air conditioning"
        case .heating:           return "Heating"
        }
    }

    /// Shown under the picker so the two unusual choices explain themselves.
    var explanation: String? {
        switch self {
        case .unknown:
            return "Readings from here until the next event are left out of the model entirely. Use this when you do not know what was running — a wrong label is worse than none."
        case .vent:
            return "The swamp cooler's fan with dry pads: no cooling, just outside air pulled through the house. The model treats it as extra infiltration rather than as cooling."
        default:
            return nil
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
        case .vent:
            context.insert(HVACEvent(date: date, mode: 3, targetTempC: nil, source: 0))
        case .unknown:
            context.insert(HVACEvent(date: date, mode: -1, targetTempC: nil, source: 0))
        }
    }
}

struct EventEditorView: View {
    /// The event being edited, if any. Nil means a new one.
    ///
    /// Editing replaces rather than mutates: a change of equipment can move the
    /// record between the cooler and thermostat tables, and replacing keeps one
    /// path instead of two that must agree.
    var editing: ExistingEvent?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false

    @State private var change: EquipmentChange = .airConditioning
    @State private var date = Date()
    @State private var hasSetpoint = false
    @State private var setpoint: Double = 22
    @State private var saveError: String?
    @State private var loaded = false

    /// A stored event handed to the editor, with whichever record it came from
    /// so it can be removed when replaced.
    struct ExistingEvent: Identifiable {
        var id: Date { date }
        var change: EquipmentChange
        var date: Date
        var setpointC: Double?
        var cooler: CoolerEvent?
        var hvac: HVACEvent?
    }

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
                    if let explanation = change.explanation {
                        Text(explanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What changed")
                }

                Section {
                    SteppedDatePicker(date: $date)
                        .frame(height: 180)
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
            .alert("Could not save", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onAppear(perform: loadExisting)
            .navigationTitle(editing == nil ? "Add event" : "Edit event")
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

    /// Fill the wheels from the event being edited, once.
    private func loadExisting() {
        guard !loaded, let editing else { loaded = true; return }
        loaded = true
        change = editing.change
        date = editing.date
        if let celsius = editing.setpointC {
            hasSetpoint = true
            setpoint = useFahrenheit ? (celsius * 9 / 5 + 32).rounded()
                                     : (celsius * 2).rounded() / 2
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
        // Replace rather than mutate, so a change of equipment type moves the
        // record to the right table without a second code path.
        if let editing {
            if let old = editing.cooler { context.delete(old) }
            if let old = editing.hvac { context.delete(old) }
        }
        change.record(at: date, setpointC: celsius, context: context)
        do {
            try context.save()
        } catch {
            // Never fail silently: an event that looks recorded but is not
            // mislabels every reading after it, and the mistake only surfaces
            // much later as a model that will not fit.
            saveError = error.localizedDescription
            return
        }
        dismiss()
    }
}

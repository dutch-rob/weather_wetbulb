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

    /// The HVACEvent mode this change is stored as, or nil when it is stored as
    /// a CoolerEvent instead.
    var hvacMode: Int? {
        switch self {
        case .evaporativeCooler: return nil
        case .unknown:           return -1
        case .off:               return 0
        case .heating:           return 1
        case .airConditioning:   return 2
        case .vent:              return 3
        }
    }

    /// Write this change into the store at `date`.
    func record(at date: Date, setpointC: Double?, context: ModelContext) {
        if let mode = hvacMode {
            context.insert(HVACEvent(date: date, mode: mode,
                                     targetTempC: takesSetpoint ? setpointC : nil, source: 0))
        } else {
            context.insert(CoolerEvent(date: date, isOn: true, source: 0))
        }
    }
}

struct EventEditorView: View {
    /// The event being edited, if any. Nil means a new one.
    var editing: ExistingEvent?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false

    @State private var change: EquipmentChange = .airConditioning
    @State private var day: Date = Calendar.current.startOfDay(for: Date())
    @State private var hour: Int = Calendar.current.component(.hour, from: Date())
    @State private var minute: Int = Calendar.current.component(.minute, from: Date()) / 5 * 5
    @State private var hasSetpoint = false
    @State private var setpoint: Double = 22
    @State private var saveError: String?
    @State private var loaded = false

    /// A stored event handed to the editor, with whichever record it came from.
    struct ExistingEvent: Identifiable {
        /// The stored record's own identity, so two events at the same moment
        /// can never be confused for one another.
        var id: PersistentIdentifier? { cooler?.persistentModelID ?? hvac?.persistentModelID }
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

    // MARK: - Time wheels

    /// Days offered, newest first: the last two months, stretched further back
    /// if the event being edited is older than that.
    private var dayOptions: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var earliest = cal.date(byAdding: .day, value: -60, to: today) ?? today
        if let editing { earliest = min(earliest, cal.startOfDay(for: editing.date)) }
        var days: [Date] = []
        var d = today
        while d >= earliest {
            days.append(d)
            guard let previous = cal.date(byAdding: .day, value: -1, to: d) else { break }
            d = previous
        }
        return days
    }

    /// Five-minute steps. An event recorded before the steps existed keeps its
    /// exact minute rather than being silently moved to the nearest step.
    private var minuteOptions: [Int] {
        var options = Array(stride(from: 0, to: 60, by: 5))
        if !options.contains(minute) { options.append(minute); options.sort() }
        return options
    }

    private var composedDate: Date? {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private var isInFuture: Bool {
        (composedDate ?? .distantPast) > Date()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return Self.dayFormatter.string(from: d)
    }

    /// Three SwiftUI wheels rather than a UIDatePicker.
    ///
    /// UIDatePicker's wheels turn into a keyboard number field when tapped, and
    /// offer no way to switch that off. Typing a time there was the one route
    /// that lost an event while it was being edited. Plain wheel pickers can
    /// only be spun, so that path no longer exists.
    private var timeWheels: some View {
        HStack(spacing: 0) {
            Picker("Day", selection: $day) {
                ForEach(dayOptions, id: \.self) { Text(dayLabel($0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            // Side-by-side wheels otherwise share one touch area, so dragging
            // one can spin its neighbour. Clipping to each frame separates them.
            .clipped()
            .contentShape(Rectangle())

            Picker("Hour", selection: $hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(width: 64)
            .clipped()
            .contentShape(Rectangle())

            Text(":").font(.title3).foregroundStyle(.secondary)

            Picker("Minute", selection: $minute) {
                ForEach(minuteOptions, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(width: 64)
            .clipped()
            .contentShape(Rectangle())
        }
        .labelsHidden()
        .frame(height: 170)
    }

    // MARK: - Body

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
                    timeWheels
                } header: {
                    Text("When it changed")
                } footer: {
                    if isInFuture {
                        Text("That time hasn't happened yet. Choose a time up to now.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Set the time it actually happened, not now. Readings between this moment and the next event are attributed to it.")
                    }
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
                        .disabled(isInFuture)
                }
            }
        }
    }

    // MARK: - Loading and saving

    /// Fill the wheels from the event being edited, once.
    private func loadExisting() {
        guard !loaded, let editing else { loaded = true; return }
        loaded = true
        let cal = Calendar.current
        change = editing.change
        day = cal.startOfDay(for: editing.date)
        hour = cal.component(.hour, from: editing.date)
        minute = cal.component(.minute, from: editing.date)
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
        guard let when = composedDate, when <= Date() else { return }
        var celsius: Double?
        if change.takesSetpoint && hasSetpoint {
            celsius = useFahrenheit ? (setpoint - 32) * 5 / 9 : setpoint
        }

        if let editing {
            if let record = editing.hvac, let mode = change.hvacMode {
                // Same table: change the record where it stands. Nothing is
                // deleted, so nothing can be lost.
                record.date = when
                record.mode = mode
                record.targetTempC = change.takesSetpoint ? celsius : nil
            } else if let record = editing.cooler, change == .evaporativeCooler {
                record.date = when
                record.isOn = true
            } else {
                // Moving between the cooler and thermostat tables. Insert the
                // replacement BEFORE deleting the original, so the two happen
                // in one save or not at all.
                change.record(at: when, setpointC: celsius, context: context)
                if let old = editing.cooler { context.delete(old) }
                if let old = editing.hvac { context.delete(old) }
            }
        } else {
            change.record(at: when, setpointC: celsius, context: context)
        }

        do {
            try context.save()
        } catch {
            // Undo everything this save staged. Left pending, a deletion would
            // quietly go through with the NEXT successful save — which is how
            // an edited event could vanish without any error at the time.
            context.rollback()
            saveError = error.localizedDescription
            return
        }
        dismiss()
    }
}

//
//  EventsView.swift
//  weather_wetbulb
//
//  Every heating or cooling event the model is told about, logged or guessed.
//
//  Its own screen rather than the foot of the model screen, so the events can
//  be reviewed and corrected without waiting for a fit — and recording what the
//  equipment is doing is most useful before the readings arrive, not after.
//  The model screen refits each time it opens, so a change made here is in the
//  next fit without anything having to notify it.
//

import SwiftUI
import SwiftData

struct EventsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false

    @Query(sort: \CoolerEvent.date, order: .reverse) private var coolerEvents: [CoolerEvent]
    @Query(sort: \HVACEvent.date, order: .reverse) private var hvacEvents: [HVACEvent]

    @State private var addingEvent = false
    @State private var editingEvent: EventEditorView.ExistingEvent?

    var body: some View {
        NavigationStack {
            List {
                eventSection
            }
            .navigationTitle("Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $addingEvent) {
            EventEditorView()
        }
        .sheet(item: $editingEvent) { existing in
            EventEditorView(editing: existing)
        }
    }

    private var eventSection: some View {
        Section {
            Button {
                addingEvent = true
            } label: {
                Label("Add event", systemImage: "plus.circle")
            }


            if timeline.isEmpty {
                Text("Nothing recorded, so the fit assumes nothing has ever run.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timeline) { entry in
                    Button {
                        editingEvent = existing(from: entry)
                    } label: {
                        eventRow(entry)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteEvents)
            }
        } header: {
            Text("Newest first")
        } footer: {
            Text("Tap an event to correct it. Everything before the first event counts as nothing running, so an event-free stretch needs no marking. Unlabelled time AFTER an event is attributed to that event — an unrecorded change flattens the passive terms.")
        }
    }

    private func eventRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.title)
                            Spacer()
                            Text(entry.inferred ? "guessed" : "logged")
                                .font(.caption)
                                .foregroundStyle(entry.inferred ? .orange : .secondary)
                        }
            Text(ModelReportView.stamp(entry.date))
                .font(.caption).foregroundStyle(.secondary)
            if let setpoint = entry.setpoint {
                Text(setpointText(setpoint))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Translate a listed row back into what the editor needs.
    private func existing(from entry: Entry) -> EventEditorView.ExistingEvent {
        let change: EquipmentChange
        if let cooler = entry.cooler {
            change = cooler.isOn ? .evaporativeCooler : .off
        } else {
            change = EquipmentChange(rawValue: entry.hvac?.mode ?? 0) ?? .off
        }
        return EventEditorView.ExistingEvent(
            change: change, date: entry.date, setpointC: entry.setpoint,
            cooler: entry.cooler, hvac: entry.hvac)
    }

    private func setpointText(_ celsius: Double) -> String {
        useFahrenheit ? String(format: "set to %.0f °F", celsius * 9 / 5 + 32)
                      : String(format: "set to %.1f °C", celsius)
    }

    /// Remove events. Deleting is how a mistyped one is corrected: re-add it
    /// with the right time rather than editing in place, which would have to
    /// know which of the two record types it came from.
    private func deleteEvents(at offsets: IndexSet) {
        for index in offsets {
            let entry = timeline[index]
            if let cooler = entry.cooler { context.delete(cooler) }
            if let hvac = entry.hvac { context.delete(hvac) }
        }
        try? context.save()
    }

    // MARK: - Event timeline

    private struct Entry: Identifiable {
        /// The stored record's own identity. This was a fresh UUID on every
        /// render, so each redraw looked to SwiftUI like every row being
        /// removed and re-added — discarding a half-open swipe-to-delete, which
        /// is why it flicked in and out.
        let id: PersistentIdentifier
        let date: Date
        let title: String
        let setpoint: Double?
        let inferred: Bool
        var cooler: CoolerEvent?
        var hvac: HVACEvent?
    }

    /// Both event kinds merged, newest first.
    private var timeline: [Entry] {
        var all: [Entry] = coolerEvents.map {
            Entry(id: $0.persistentModelID, date: $0.date,
                  title: $0.isOn ? "Evaporative cooler on" : "Evaporative cooler off",
                  setpoint: nil, inferred: $0.source == 1, cooler: $0)
        }
        all += hvacEvents.map {
            let title: String
            switch $0.mode {
            case -1: title = "Unknown — excluded from the model"
            case 1:  title = "Heating on"
            case 2:  title = "Air conditioning on"
            case 3:  title = "Vent (cooler, no water)"
            default: title = "Nothing running"
            }
            return Entry(id: $0.persistentModelID, date: $0.date, title: title,
                         setpoint: $0.targetTempC, inferred: $0.source == 1, hvac: $0)
        }
        return all.sorted { $0.date > $1.date }
    }
}

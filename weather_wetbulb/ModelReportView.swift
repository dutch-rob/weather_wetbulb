//
//  ModelReportView.swift
//  weather_wetbulb
//
//  What the indoor model currently believes, and what it was told.
//
//  The screen exists because a fitted model is otherwise opaque: a forecast
//  line gives no way to tell a good fit from one that is quietly missing half
//  its inputs. So this shows the coefficients, how well they scored on held-out
//  data, which variables actually had data behind them, and every heating or
//  cooling event the fit was given.
//
//  One rule throughout: a coefficient that could not be estimated is shown as
//  "not estimable", never as 0.000. A zero looks like a measured finding of no
//  effect, when it really means nothing was observed.
//

import SwiftUI
import SwiftData

struct ModelReportView: View {
    /// WeatherKit series to align the station readings against.
    let series: [ForecastPoint]

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CoolerEvent.date, order: .reverse) private var coolerEvents: [CoolerEvent]
    @Query(sort: \HVACEvent.date, order: .reverse) private var hvacEvents: [HVACEvent]

    @State private var report: Report?
    @State private var building = true
    @State private var addingEvent = false
    @State private var editingEvent: EventEditorView.ExistingEvent?
    @State private var exportFile: URL?

    var body: some View {
        NavigationStack {
            Group {
                if building {
                    ProgressView("Fitting…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Events stay reachable even with no model. Logging one
                        // is most useful before the readings arrive, not after,
                        // and a full-screen placeholder would block the only
                        // way to record what the equipment is doing.
                        if let report {
                            fitSection(report)
                            equipmentSection(report)
                            coefficientSection("Temperature  (°C per hour)",
                                               report.model.temperatureLabels,
                                               report.model.temperature)
                            coefficientSection("Dew point  (°C per hour)",
                                               report.model.dewPointLabels,
                                               report.model.dewPoint)
                            sourceSection(report)
                            coverageSection(report)
                        } else {
                            unavailable
                        }
                        eventSection
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await build() }
        .sheet(isPresented: $addingEvent, onDismiss: { Task { await build() } }) {
            EventEditorView()
        }
        .sheet(item: $editingEvent, onDismiss: { Task { await build() } }) { existing in
            EventEditorView(editing: existing)
        }
    }

    // MARK: - Sections

    private func fitSection(_ r: Report) -> some View {
        Section {
            row("Observations", "\(r.model.observationCount) fitted, \(r.observations.count) built")
            if let first = r.observations.first?.date, let last = r.observations.last?.date {
                row("Span", "\(Self.stamp(first)) → \(Self.stamp(last))")
            }
            row("Wind direction as", r.model.encoding == .harmonic
                ? "sine/cosine pair" : "8-point cyclic spline")
            row("Held-out error, temp", String(format: "%.3f °C/h", r.model.score.temperatureRMSE))
            row("Held-out error, dew pt", String(format: "%.3f °C/h", r.model.score.dewPointRMSE))
            row("Combined", String(format: "%.3f", r.model.score.combined))
            if let constant = r.timeConstantHours {
                row("Passive time constant", String(format: "%.1f h", constant))
            }
            if !r.coilNote.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AC coil temperature")
                    Text(r.coilNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let bearing = r.exposureBearing {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Most sun-exposed side")
                    Text(String(format: "%.0f° — %@", bearing, Self.compassName(bearing)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !r.coolerNote.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cooler saturation")
                    Text(r.coolerNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Fit")
        } footer: {
            Text("Error is measured on later observations the fit never saw. Combined is scaled by how much each quantity varied, so 1.0 means no better than predicting the average.")
        }
    }

    private func equipmentSection(_ r: Report) -> some View {
        Section {
            ForEach(Self.equipment, id: \.state) { item in
                let count = r.observationCount(for: item.state)
                HStack {
                    Text(item.name)
                    Spacer()
                    if count == 0 {
                        Text("not estimable")
                            .foregroundStyle(.secondary)
                    } else if let value = r.equipmentCoefficient(item.state) {
                        Text(String(format: "%+.3f °C/h", value))
                            .monospacedDigit()
                    }
                }
                if count == 0 {
                    Text("No observations with this running, so its effect cannot be separated from everything else.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(count) observations")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Heating and cooling")
        } footer: {
            Text("The evaporative cooler's effect is expressed against the outdoor wet-bulb temperature, which is the floor it can cool towards. AC and heating are flat rates.")
        }
    }

    private func coefficientSection(_ title: String,
                                    _ labels: [String],
                                    _ values: [Double]) -> some View {
        Section(title) {
            ForEach(Array(zip(labels, values).enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0).font(.callout)
                    Spacer()
                    Text(String(format: "%+.4f", pair.1))
                        .monospacedDigit()
                        .foregroundStyle(abs(pair.1) < 1e-9 ? .secondary : .primary)
                }
            }
        }
    }

    private func sourceSection(_ r: Report) -> some View {
        Section {
            ForEach(OutdoorVariable.allCases, id: \.self) { v in
                row(Self.variableName(v),
                    r.model.plan[v] == .weatherKit ? "WeatherKit" : "Station")
            }
        } header: {
            Text("Chosen source")
        } footer: {
            Text("Picked per variable by whichever scored better on held-out data. A variable with no station history falls back to WeatherKit regardless of what is shown.")
        }
    }

    private func coverageSection(_ r: Report) -> some View {
        Section {
            ForEach(r.coverage, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.count == 0 ? "no data" : "\(item.count)/\(r.observations.count)")
                        .foregroundStyle(item.count == 0 ? .orange : .secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Station data behind the fit")
        } footer: {
            Text("A variable with no data contributes nothing: its coefficient stays at zero because there was never anything to fit.")
        }
    }

    private var eventSection: some View {
        Section {
            Button {
                addingEvent = true
            } label: {
                Label("Add event", systemImage: "plus.circle")
            }

            if let file = exportFile {
                ShareLink(item: file) {
                    Label("Export model and data", systemImage: "square.and.arrow.up")
                }
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
            Text("Events, newest first")
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
            Text(Self.stamp(entry.date))
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
        Task { await build() }
    }

    private var unavailable: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("No model yet", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Text("The model needs a stretch of station readings close enough together to measure a rate of change. Readings arrive about every 18 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Building

    private func build() async {
        building = true
        defer { building = false }
        let readings = IndoorFeedStore.history(source: .vevorStation, context: context)
        let observations = IndoorObservationBuilder.build(
            readings: readings, weather: series,
            coolerEvents: coolerEvents, hvacEvents: hvacEvents)
        let (train, test) = IndoorModelEstimator.split(observations)
        guard let selection = IndoorModelEstimator.selectModel(train: train, test: test) else {
            report = nil
            exportFile = writeExport()
            return
        }
        report = Report(model: selection.model, observations: observations,
                        coilNote: selection.coilNote,
                        coolerNote: selection.coolerNote,
                        exposureBearing: selection.exposureBearing)
        // Rewrite the bundle here, not on appear. Writing it once when the
        // screen opened meant that adding an event refreshed the report but
        // left Export sharing the snapshot taken beforehand — silently missing
        // the very event just recorded.
        exportFile = writeExport()
    }

    // MARK: - Report

    struct Report {
        let model: IndoorModel
        let observations: [IndoorObservation]
        /// How the coil temperature was arrived at, in words.
        var coilNote: String = ""
        /// The same for the cooler's saturation effectiveness.
        var coolerNote: String = ""
        /// Bearing the house appears most exposed to, when one was fitted.
        var exposureBearing: Double?

        /// Hours for the passive response to close most of an indoor-outdoor
        /// gap. Only meaningful when conduction came out positive.
        var timeConstantHours: Double? {
            guard model.temperature.count > 1 else { return nil }
            let conduction = model.temperature[1]
            guard conduction > 1e-6 else { return nil }
            return 1 / conduction
        }

        func observationCount(for state: HVACState) -> Int {
            observations.filter { $0.hvac == state }.count
        }

        func equipmentCoefficient(_ state: HVACState) -> Double? {
            guard let i = IndoorModel.equipmentIndex(state, in: model.temperature.count),
                  model.temperature.indices.contains(i) else { return nil }
            return model.temperature[i]
        }

        var coverage: [(name: String, count: Int)] {
            var out: [(String, Int)] = []
            for v in OutdoorVariable.allCases {
                let n = observations.filter { $0.station.value(v) != nil }.count
                out.append((ModelReportView.variableName(v), n))
            }
            out.append(("solar", observations.filter { $0.solar > 0 }.count))
            return out
        }
    }

    // MARK: - Export

    /// Write everything the fit used, plus what it produced, for sharing.
    ///
    /// The whole bundle rather than just the events: a fit done elsewhere from
    /// different inputs cannot be compared with this one. With the readings,
    /// the WeatherKit series and the resulting coefficients all present, an
    /// offline refit either reproduces `model` or reveals a bug.
    private func writeExport() -> URL? {
        ModelExport.build(readings: IndoorFeedStore.history(source: .vevorStation,
                                                            context: context),
                          weather: series,
                          coolerEvents: coolerEvents,
                          hvacEvents: hvacEvents,
                          model: report?.model).write()
    }

    // MARK: - Event timeline

    private struct Entry: Identifiable {
        let id = UUID()
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
            Entry(date: $0.date,
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
            return Entry(date: $0.date, title: title,
                         setpoint: $0.targetTempC, inferred: $0.source == 1, hvac: $0)
        }
        return all.sorted { $0.date > $1.date }
    }

    // MARK: - Helpers

    private static let equipment: [(state: HVACState, name: String)] = [
        (.evaporativeCooler, "Evaporative cooler"),
        (.vent, "Vent (cooler, no water)"),
        (.airConditioning, "Air conditioning"),
        (.heating, "Heating"),
    ]

    static func variableName(_ v: OutdoorVariable) -> String {
        switch v {
        case .temperature:   return "temperature"
        case .humidity:      return "humidity"
        case .windSpeed:     return "wind speed"
        case .windGust:      return "wind gust"
        case .windDirection: return "wind direction"
        case .rainfall:      return "rainfall"
        case .pressure:      return "pressure"
        }
    }

    /// Nearest compass point, so the fitted bearing can be checked against the
    /// building at a glance.
    static func compassName(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return points[Int((angle / 22.5).rounded()) % points.count]
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f.string(from: date)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

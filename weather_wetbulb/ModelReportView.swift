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
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CoolerEvent.date, order: .reverse) private var coolerEvents: [CoolerEvent]
    @Query(sort: \HVACEvent.date, order: .reverse) private var hvacEvents: [HVACEvent]

    @State private var report: Report?
    @State private var building = true

    var body: some View {
        NavigationStack {
            Group {
                if building {
                    ProgressView("Fitting…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report {
                    List {
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
                        eventSection
                    }
                } else {
                    unavailable
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
            if timeline.isEmpty {
                Text("No events recorded. The fit assumes nothing was running.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timeline) { entry in
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
                            Text(String(format: "set to %.1f °C", setpoint))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Events, newest first")
        } footer: {
            Text("Unlabelled time is treated as nothing running. That is an assumption: an unrecorded hour of cooling is attributed to the passive terms instead, which flattens them.")
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Not enough data yet",
            systemImage: "chart.xyaxis.line",
            description: Text("The model needs a stretch of station readings close enough together to measure a rate of change. Readings arrive about every 18 minutes."))
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
            return
        }
        report = Report(model: selection.model, observations: observations)
    }

    // MARK: - Report

    struct Report {
        let model: IndoorModel
        let observations: [IndoorObservation]

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

    // MARK: - Event timeline

    private struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let title: String
        let setpoint: Double?
        let inferred: Bool
    }

    /// Both event kinds merged, newest first.
    private var timeline: [Entry] {
        var all: [Entry] = coolerEvents.map {
            Entry(date: $0.date,
                  title: $0.isOn ? "Evaporative cooler on" : "Evaporative cooler off",
                  setpoint: nil, inferred: $0.source == 1)
        }
        all += hvacEvents.map {
            let title: String
            switch $0.mode {
            case 1:  title = "Heating on"
            case 2:  title = "Air conditioning on"
            default: title = "Thermostat off"
            }
            return Entry(date: $0.date, title: title,
                         setpoint: $0.targetTempC, inferred: $0.source == 1)
        }
        return all.sorted { $0.date > $1.date }
    }

    // MARK: - Helpers

    private static let equipment: [(state: HVACState, name: String)] = [
        (.evaporativeCooler, "Evaporative cooler"),
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

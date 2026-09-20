//
//  IndoorForecastView.swift
//  weather_wetbulb
//
//  What the house will do over the next twelve hours, under three scenarios.
//
//  The first is the house left alone. The other two are laid out on sliders
//  under the graph: each has two pointers, and where a pointer sits on the
//  x-axis is when that equipment starts. Tapping a pointer opens what it is
//  set to. So "start the cooler at four, and turn it off at seven" is a drag
//  and a tap, and its line appears against the same axis as the others.
//
//  Always lines, never areas: three filled scenarios over three series would
//  be unreadable, whatever the graph style says elsewhere.
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation

struct IndoorForecastView: View {
    /// The weather already loaded for the place on screen.
    var series: [ForecastPoint]
    /// That place, to tell whether it is the monitored home.
    var location: CLLocation? = nil
    @ObservedObject var places: PlacesViewModel
    var nowTick: Date = .now
    /// Back to the graph, for the button beside the title.
    var onShowGraph: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Query(sort: \CoolerEvent.date, order: .reverse) private var coolerEvents: [CoolerEvent]
    @Query(sort: \HVACEvent.date, order: .reverse) private var hvacEvents: [HVACEvent]

    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = true
    @AppStorage(SettingsKey.use12HourClock) private var use12Hour = false
    @AppStorage(SettingsKey.chartStyle) private var chartStyle: ChartStyle = .filled
    @AppStorage(SettingsKey.graphPalette) private var palette: GraphPalette = .vivid
    @AppStorage(GraphKey.temp) private var graphTemp = true
    @AppStorage(GraphKey.wetBulb) private var graphWetBulb = true
    @AppStorage(GraphKey.dewPoint) private var graphDewPoint = true

    /// The home's own forecast, fetched only when the home is not the place on
    /// screen — the series passed in then describes somewhere else.
    @StateObject private var homeWeather = WeatherService()

    @State private var model: IndoorModel?
    @State private var start: IndoorForecast.Start?
    @State private var blocker: ModelReportView.Blocker?
    @State private var preparing = true
    @State private var scenarios: [IndoorForecast.Scenario] = []
    @State private var editing: PointerTarget?

    /// Which pointer a menu is open for.
    private struct PointerTarget: Identifiable, Equatable {
        let scenario: Int
        let second: Bool
        var id: String { "\(scenario)-\(second)" }
    }

    private var home: Place? { places.monitoredHome }

    /// Places this close together are the same site.
    private static let sameSiteRadius: CLLocationDistance = 2_000

    private var needsOwnWeather: Bool {
        guard let home else { return false }
        guard let shown = location else { return true }
        return shown.distance(from: home.clLocation) > Self.sameSiteRadius
    }

    /// The forecast the house is run against.
    private var weather: [ForecastPoint] { needsOwnWeather ? homeWeather.seriesFull : series }
    private var horizonEnd: Date { (start?.date ?? nowTick).addingTimeInterval(IndoorForecast.horizon) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if preparing {
                Spacer()
                ProgressView("Preparing the forecast…")
                Spacer()
            } else if let blocker {
                Spacer()
                unavailable(blocker)
                Spacer()
            } else if let model, let start {
                content(model: model, start: start)
            } else {
                Spacer()
                unavailableText("No forecast yet",
                                "The indoor model needs station readings and an outdoor forecast for your home.")
                Spacer()
            }
        }
        .task {
            if needsOwnWeather, let home, homeWeather.seriesFull.isEmpty {
                await homeWeather.loadFor(location: home.clLocation)
            }
            await prepare()
        }
        .onChange(of: weather.count) { _, _ in Task { await prepare() } }
        .sheet(item: $editing) { target in
            pointerEditor(target)
                .presentationDetents([.medium])
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("indoor forecast")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 78)
                HStack {
                    if let onShowGraph { Button("graph") { onShowGraph() } }
                    Spacer()
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
        }
    }

    // MARK: - The graph and its sliders

    @ViewBuilder
    private func content(model: IndoorModel, start: IndoorForecast.Start) -> some View {
        let runs = scenarios.map { scenario in
            (scenario: scenario,
             points: IndoorForecast.run(model: model, from: start, scenario: scenario,
                                        weather: weather, location: home?.clLocation) ?? [])
        }
        GeometryReader { geo in
            VStack(spacing: 8) {
                legend
                chart(runs)
                    .frame(height: max(160, geo.size.height * 0.46))
                VStack(spacing: 10) {
                    ForEach(scenarios.filter { $0.id > 0 }) { scenario in
                        scenarioSlider(scenario)
                    }
                }
                .padding(.horizontal, 12)
                Text("Outdoor conditions come from WeatherKit's forecast: the station cannot report the future.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
    }

    private func chart(_ runs: [(scenario: IndoorForecast.Scenario, points: [IndoorForecast.Point])]) -> some View {
        Chart {
            ForEach(runs, id: \.scenario.id) { run in
                ForEach(run.points) { point in
                    if graphTemp {
                        LineMark(x: .value("Time", point.date),
                                 y: .value("Temp", point.temperature(fahrenheit: useFahrenheit)),
                                 series: .value("s", "dry-\(run.scenario.id)"))
                            .foregroundStyle(color(.dry))
                            .lineStyle(Self.stroke(for: run.scenario.id))
                            .interpolationMethod(.linear)
                    }
                    if graphWetBulb {
                        LineMark(x: .value("Time", point.date),
                                 y: .value("Wet", point.wetBulb(fahrenheit: useFahrenheit)),
                                 series: .value("s", "wet-\(run.scenario.id)"))
                            .foregroundStyle(color(.wet))
                            .lineStyle(Self.stroke(for: run.scenario.id))
                            .interpolationMethod(.linear)
                    }
                    if graphDewPoint {
                        LineMark(x: .value("Time", point.date),
                                 y: .value("Dew", point.dewPoint(fahrenheit: useFahrenheit)),
                                 series: .value("s", "dew-\(run.scenario.id)"))
                            .foregroundStyle(color(.dew))
                            .lineStyle(Self.stroke(for: run.scenario.id))
                            .interpolationMethod(.linear)
                    }
                }
            }
            // Where each scenario's equipment starts, on the graph itself.
            ForEach(scenarios.flatMap(\.changes), id: \.id) { change in
                RuleMark(x: .value("Change", change.date))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: (start?.date ?? nowTick)...horizonEnd)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.2))
                AxisTick().foregroundStyle(.primary.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(clockHourLabel(Calendar.current.component(.hour, from: date), use12: use12Hour))
                            .font(.caption)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.2))
                AxisTick().foregroundStyle(.primary.opacity(0.5))
                AxisValueLabel().font(.caption)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text(useFahrenheit ? "°F" : "°C").font(.caption2).foregroundStyle(.secondary)
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Legend

    private enum Series { case dry, wet, dew }

    /// The colors the outdoor graphs use, under whichever style is set. Only
    /// the line style separates the scenarios.
    private func color(_ series: Series) -> Color {
        let filled = chartStyle == .filled
        switch series {
        case .dry: return filled ? palette.green : palette.blue
        case .wet: return filled ? palette.blue : palette.green
        case .dew: return palette.red
        }
    }

    static func stroke(for scenario: Int) -> StrokeStyle {
        switch scenario {
        case 1:  return StrokeStyle(lineWidth: 2, dash: [2, 3])      // dotted
        case 2:  return StrokeStyle(lineWidth: 2, dash: [7, 4])      // dashed
        default: return StrokeStyle(lineWidth: 2)                    // drawn
        }
    }

    private var legend: some View {
        VStack(spacing: 3) {
            HStack(spacing: 14) {
                if graphTemp { legendKey(color(.dry), "Temp") }
                if graphWetBulb { legendKey(color(.wet), "Wet Bulb") }
                if graphDewPoint { legendKey(color(.dew), "Dew Pt") }
            }
            HStack(spacing: 14) {
                ForEach(scenarios) { scenario in
                    HStack(spacing: 5) {
                        DashKey(style: Self.stroke(for: scenario.id))
                        Text(scenario.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legendKey(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A short length of line drawn in a scenario's own dash pattern.
    private struct DashKey: View {
        let style: StrokeStyle
        var body: some View {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1.5))
                p.addLine(to: CGPoint(x: 18, y: 1.5))
            }
            .stroke(Color.secondary, style: style)
            .frame(width: 18, height: 3)
        }
    }

    // MARK: - Sliders

    private func scenarioSlider(_ scenario: IndoorForecast.Scenario) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DashKey(style: Self.stroke(for: scenario.id))
                Text(summary(scenario)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            EventSlider(
                start: start?.date ?? nowTick,
                horizon: IndoorForecast.horizon,
                first: binding(for: scenario.id, second: false),
                second: binding(for: scenario.id, second: true),
                onTap: { second in editing = PointerTarget(scenario: scenario.id, second: second) })
                .frame(height: 34)
        }
    }

    private func summary(_ scenario: IndoorForecast.Scenario) -> String {
        let clock = DateFormatter()
        clock.locale = .current
        clock.setLocalizedDateFormatFromTemplate(use12Hour ? "h:mm a" : "HH:mm")
        let parts = scenario.changes.map { change in
            "\(clock.string(from: change.date)) \(name(change.state))"
                + (change.setpointC.map { " \(setpointText($0))" } ?? "")
        }
        return parts.isEmpty ? "nothing running" : parts.joined(separator: " → ")
    }

    private func binding(for id: Int, second: Bool) -> Binding<IndoorForecast.Change?> {
        Binding(
            get: {
                guard let scenario = scenarios.first(where: { $0.id == id }) else { return nil }
                return second ? scenario.second : scenario.first
            },
            set: { value in
                guard let index = scenarios.firstIndex(where: { $0.id == id }) else { return }
                if second { scenarios[index].second = value } else { scenarios[index].first = value }
            })
    }

    // MARK: - The menu behind a pointer

    @ViewBuilder
    private func pointerEditor(_ target: PointerTarget) -> some View {
        let binding = binding(for: target.scenario, second: target.second)
        NavigationStack {
            Form {
                Section {
                    if let change = binding.wrappedValue {
                        LabeledContent("Starts at", value: timeText(change.date))
                        Picker("Equipment", selection: Binding(
                            get: { EquipmentChange(rawValue: change.state.rawValue) ?? .off },
                            set: { newValue in
                                var updated = change
                                updated.state = HVACState(rawValue: newValue.rawValue) ?? .off
                                updated.setpointC = newValue.takesSetpoint
                                    ? (change.setpointC ?? Self.defaultSetpointC(fahrenheit: useFahrenheit))
                                    : nil
                                binding.wrappedValue = updated
                            })) {
                            ForEach(Self.choices) { choice in
                                Text(choice.name).tag(choice)
                            }
                        }
                        if let setpoint = change.setpointC {
                            Picker("Set to", selection: Binding(
                                get: { displaySetpoint(setpoint) },
                                set: { newValue in
                                    var updated = change
                                    updated.setpointC = useFahrenheit ? (newValue - 32) * 5 / 9 : newValue
                                    binding.wrappedValue = updated
                                })) {
                                ForEach(setpointChoices, id: \.self) { value in
                                    Text(String(format: useFahrenheit ? "%.0f °F" : "%.1f °C", value)).tag(value)
                                }
                            }
                        }
                    } else {
                        Text("No event: the scenario carries on with whatever was running before.")
                            .foregroundStyle(.secondary)
                        Button("Add an event here") {
                            binding.wrappedValue = IndoorForecast.Change(
                                date: (start?.date ?? nowTick).addingTimeInterval(IndoorForecast.horizon / 2),
                                state: .off, setpointC: nil)
                        }
                    }
                } header: {
                    Text(target.second ? "Second change" : "First change")
                } footer: {
                    Text("Drag the pointer along the axis to change the time. A pointer parked at the right-hand end is no event at all.")
                }
                if target.second, binding.wrappedValue != nil {
                    Section {
                        Button("Remove this event", role: .destructive) { binding.wrappedValue = nil }
                    }
                }
            }
            .navigationTitle("Scenario \(target.scenario + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil } }
            }
        }
    }

    static let choices: [EquipmentChange] = [.off, .evaporativeCooler, .vent, .airConditioning, .heating]

    /// What a thermostat starts at when one is needed: a round number in
    /// whichever unit is on screen.
    static func defaultSetpointC(fahrenheit: Bool) -> Double { fahrenheit ? (75 - 32) * 5 / 9 : 24 }
    /// The same default in the unit on screen, for the pickers that work in it.
    static func defaultSetpointDisplayed(fahrenheit: Bool) -> Double { fahrenheit ? 75 : 24 }

    private var setpointChoices: [Double] {
        useFahrenheit ? stride(from: 60.0, through: 90.0, by: 1).map { $0 }
                      : stride(from: 15.0, through: 32.0, by: 0.5).map { $0 }
    }
    private func displaySetpoint(_ celsius: Double) -> Double {
        let shown = useFahrenheit ? (celsius * 9 / 5 + 32).rounded() : (celsius * 2).rounded() / 2
        return setpointChoices.min(by: { abs($0 - shown) < abs($1 - shown) }) ?? shown
    }
    private func setpointText(_ celsius: Double) -> String {
        useFahrenheit ? String(format: "%.0f °F", celsius * 9 / 5 + 32)
                      : String(format: "%.1f °C", celsius)
    }
    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(use12Hour ? "h:mm a" : "HH:mm")
        return f.string(from: date)
    }
    private func name(_ state: HVACState) -> String {
        switch state {
        case .off:               return "nothing running"
        case .evaporativeCooler: return "cooler"
        case .vent:              return "vent"
        case .airConditioning:   return "AC"
        case .heating:           return "heating"
        case .unknown:           return "unknown"
        }
    }

    // MARK: - Unavailable

    private func unavailable(_ blocker: ModelReportView.Blocker) -> some View {
        switch blocker {
        case .noHome:
            return unavailableText("No home marked",
                                   "The forecast describes one house: the place marked as your monitored home.")
        case .noAltitude(let name):
            return unavailableText("No altitude for \(name)",
                                   "Set it in the place editor, where Look up can fill it in.")
        case .noReadings:
            return unavailableText("No station readings yet",
                                   "Readings from the weather station app arrive about every 18 minutes.")
        case .severalStations(let names):
            return unavailableText("Readings from more than one station",
                                   "Stored readings come from \(names.count): \(names.joined(separator: ", ")).")
        }
    }

    private func unavailableText(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Label(title, systemImage: "house").font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Preparing

    private func prepare() async {
        preparing = model == nil
        let resolution = StationReadingStore.resolveSource(context: context)
        var readings: [IndoorReading] = []
        if case .single(let station) = resolution {
            readings = StationReadingStore.history(sourceID: station, context: context)
        }
        blocker = ModelReportView.blocker(home: home, resolution: resolution)
        guard blocker == nil, let home else { preparing = false; return }

        let observations = IndoorObservationBuilder.build(
            readings: readings, weather: weather,
            coolerEvents: coolerEvents, hvacEvents: hvacEvents,
            location: home.clLocation)
        let (train, test) = IndoorModelEstimator.split(observations)
        let saved = IndoorModelEstimator.savedStructure()
        // The structure the model screen settled is reused here: refitting it
        // is milliseconds, and a search on a graph screen would be a surprise.
        let fitted: IndoorModel? = await Task.detached(priority: .userInitiated) {
            if let saved, let quick = IndoorModelEstimator.fit(structure: saved, train: train, test: test) {
                return quick
            }
            return IndoorModelEstimator.selectModel(train: train, test: test)?.model
        }.value
        model = fitted
        start = IndoorForecast.start(observations: observations, readings: readings, now: .now)
        if scenarios.isEmpty, let start {
            scenarios = Self.defaultScenarios(start: start.date, fahrenheit: useFahrenheit)
        }
        preparing = false
    }

    /// Nothing running; the cooler from now; the AC from now. The second
    /// pointer of each starts parked at the right-hand end, meaning no change.
    static func defaultScenarios(start: Date, fahrenheit: Bool) -> [IndoorForecast.Scenario] {
        [IndoorForecast.Scenario(id: 0, name: "nothing running", first: nil, second: nil),
         IndoorForecast.Scenario(id: 1, name: "cooler",
                                 first: IndoorForecast.Change(date: start, state: .evaporativeCooler,
                                                              setpointC: nil),
                                 second: nil),
         IndoorForecast.Scenario(id: 2, name: "air conditioning",
                                 first: IndoorForecast.Change(date: start, state: .airConditioning,
                                                              setpointC: defaultSetpointC(fahrenheit: fahrenheit)),
                                 second: nil)]
    }
}

// MARK: - The two-pointer slider

/// A slider whose track is the graph's own x-axis: where a pointer sits is when
/// its event happens. The second pointer parked at the right-hand end means the
/// scenario has no second event.
struct EventSlider: View {
    var start: Date
    var horizon: TimeInterval
    @Binding var first: IndoorForecast.Change?
    @Binding var second: IndoorForecast.Change?
    var onTap: (_ second: Bool) -> Void

    /// Within this much of the right-hand end, the second pointer counts as
    /// parked: no event.
    private static let parkedFraction = 0.97

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let firstFraction = fraction(first?.date) ?? 0
            let secondFraction = fraction(second?.date) ?? 1
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)
                // The stretch during which the first event's equipment runs.
                if first != nil {
                    Capsule().fill(Color.accentColor.opacity(0.28))
                        .frame(width: max(0, (secondFraction - firstFraction)) * width, height: 4)
                        .offset(x: firstFraction * width)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                thumb(at: firstFraction, width: width, filled: true)
                    .gesture(drag(width: width, second: false))
                    .onTapGesture { onTap(false) }
                thumb(at: secondFraction, width: width, filled: second != nil)
                    .gesture(drag(width: width, second: true))
                    .onTapGesture { onTap(true) }
            }
        }
    }

    private func thumb(at fraction: Double, width: CGFloat, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color(.systemBackground))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 22, height: 22)
            .offset(x: min(max(fraction * width - 11, -11), width - 11))
            .contentShape(Circle().inset(by: -8))
    }

    private func fraction(_ date: Date?) -> Double? {
        guard let date else { return nil }
        return min(max(date.timeIntervalSince(start) / horizon, 0), 1)
    }

    private func drag(width: CGFloat, second: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let fraction = min(max(Double(value.location.x / max(width, 1)), 0), 1)
                let when = start.addingTimeInterval(fraction * horizon)
                if second {
                    if fraction >= Self.parkedFraction {
                        self.second = nil                       // parked: no event
                    } else if var change = self.second {
                        change.date = max(when, first?.date ?? start)
                        self.second = change
                    } else {
                        // Dragged in from the end: the natural second event is
                        // turning the equipment off again.
                        self.second = IndoorForecast.Change(date: max(when, first?.date ?? start),
                                                            state: .off, setpointC: nil)
                    }
                } else if var change = self.first {
                    change.date = min(when, self.second?.date ?? start.addingTimeInterval(horizon))
                    self.first = change
                } else {
                    self.first = IndoorForecast.Change(date: when, state: .evaporativeCooler, setpointC: nil)
                }
            }
    }
}

import SwiftUI
import Charts
import CoreLocation
import Combine
import SwiftData

// MARK: - ForecastPoint

struct ForecastPoint: Identifiable {
    let id = UUID()
    let date: Date
    let symbolName: String
    let isDaylight: Bool
    let uvIndex: Double
    let temperatureF: Double
    let temperatureC: Double
    let apparentTemperatureF: Double
    let apparentTemperatureC: Double
    let wetBulbF: Double
    let wetBulbC: Double
    let dewPointF: Double
    let dewPointC: Double
    let precipProbability: Double   // 0…1
    let precipitationMM: Double
    let windSpeedMPH: Double
    let windSpeedKPH: Double
    let cloudCover: Double          // 0…1
    let cloudCoverLow: Double       // 0…1
    let cloudCoverMedium: Double    // 0…1
    let cloudCoverHigh: Double      // 0…1
    let humidity: Double            // 0…1
    let stationPressurePa: Double
    // Personalized "feels like" — populated by FeelsLikeRegression once enough
    // ratings exist. Nil means regression not yet active; consumers fall back
    // to apparentTemperature.
    var myFeelsLikeC: Double?
    var myFeelsLikeF: Double?

    var displayMyFeelsLikeC: Double { myFeelsLikeC ?? apparentTemperatureC }
    var displayMyFeelsLikeF: Double { myFeelsLikeF ?? apparentTemperatureF }

    mutating func applyPrediction(state: RegressionState?, scenario: Scenario) {
        guard let state else {
            myFeelsLikeC = nil; myFeelsLikeF = nil; return
        }
        let c = state.predict(ForecastFeatureSource(p: self, scenario: scenario))
        myFeelsLikeC = c
        myFeelsLikeF = TempUnit.cToF(c)
    }
}

// MARK: - Shared components

struct ForecastLoadingView: View {
    var progress: LoadProgress
    var nowTick: Date
    var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading forecast…")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(LoadStep.allCases) { step in
                    HStack(spacing: 8) {
                        stepIcon(for: step)
                        Text(step.rawValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if case .inProgress(let t) = (progress.steps[step] ?? .pending),
                           nowTick.timeIntervalSince(t) > 2 {
                            Text("(working…)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func stepIcon(for step: LoadStep) -> some View {
        switch progress.steps[step] ?? .pending {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .inProgress(let t):
            if nowTick.timeIntervalSince(t) > 2 {
                ProgressView().frame(width: 14, height: 14)
            } else {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            }
        case .failure:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

struct ChartLegendRow: View {
    let entries: [(color: Color, label: String, isArea: Bool)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(entries, id: \.label) { e in
                HStack(spacing: 4) {
                    if e.isArea {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(e.color.opacity(0.4))
                            .frame(width: 18, height: 8)
                    } else {
                        Rectangle()
                            .fill(e.color)
                            .frame(width: 18, height: 2)
                    }
                    Text(e.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WeatherAttributionLink: View {
    let info: WeatherAttributionInfo
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Link(destination: info.legalPageURL) {
            AsyncImage(
                url: colorScheme == .dark ? info.darkLogoURL : info.lightLogoURL
            ) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Text("Apple Weather").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var weather = WeatherService()
    @StateObject private var places = PlacesViewModel()
    @State private var selectedPlace: Place? = nil
    @State private var nowTick: Date = .now
    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var showPlaces   = false
    @State private var showRate     = false
    @State private var showSettings = false
    // Tab indices: 0 = table phantom, 1 = 24h (real), 2 = 10d (real),
    //              3 = table (real), 4 = 24h phantom  — for circular wrap.
    @State private var selectedTab = 1
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true
    @AppStorage("scenarioActivity") private var scenarioActivity: Int = 1
    @AppStorage("scenarioDress")    private var scenarioDress:    Int = 0
    @AppStorage("scenarioSun")      private var scenarioSun:      Int = 0
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \Rating.timestamp) private var ratings: [Rating]
    @State private var regressionState: RegressionState? = RegressionStateStore.load()

    private var scenario: Scenario {
        Scenario(activity: scenarioActivity, dress: scenarioDress, sun: scenarioSun)
    }

    /// Features currently in the model.  Used to decide which scenario
    /// adjusters to show — only those that actually influence the
    /// prediction are exposed to the user.  Empty when no model is fit yet.
    private var activeFeatures: Set<Feature> {
        Set(regressionState?.selectedFeatures ?? [])
    }

    private func personalised(_ series: [ForecastPoint]) -> [ForecastPoint] {
        guard regressionState != nil else { return series }
        let s = regressionState
        let sc = scenario
        return series.map { p in
            var copy = p
            copy.applyPrediction(state: s, scenario: sc)
            return copy
        }
    }

    private var displayTitle: String {
        if let name = selectedPlace?.name { return name }
        return weather.placeDescription.isEmpty ? "Loading…" : weather.placeDescription
    }

    var body: some View {
        VStack(spacing: 0) {
            // Line 1: fixed place name – taps open the places sheet
            Button { showPlaces = true } label: {
                Text(displayTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal)
            }
            .background(.bar)

            Divider()

            // 5-tab layout for circular (wrap-around) swiping:
            //   0 = table phantom  →  real tab is 3
            //   1 = 24h (real, default)
            //   2 = 10d (real)
            //   3 = table (real)
            //   4 = 24h phantom  →  real tab is 1
            // Phantoms show identical content; onChange teleports to the real
            // tab instantly (no animation) so the user never notices the jump.
            TabView(selection: $selectedTab) {
                forecastTableTab.tag(0)
                hereTodayTab.tag(1)
                tenDayTab.tag(2)
                forecastTableTab.tag(3)
                hereTodayTab.tag(4)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .onChange(of: selectedTab) { _, tab in
                guard tab == 0 || tab == 4 else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { selectedTab = tab == 0 ? 3 : 1 }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ZStack {
                // Center area: Places + Rate Feels Like, side by side
                HStack(spacing: 24) {
                    Button { showPlaces = true } label: {
                        Label("Places", systemImage: "mappin.and.ellipse")
                            .padding(.vertical, 10)
                    }
                    Button { showRate = true } label: {
                        Label("Rate Feels Like", systemImage: "thermometer.medium")
                            .padding(.vertical, 10)
                    }
                    .disabled(weather.series24h.isEmpty)
                }

                HStack {
                    Spacer()

                    // Settings cog – bottom-right corner
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                    }
                }
            }
            .background(.bar)
        }
        .sheet(isPresented: $showPlaces) {
            NavigationStack {
                PlacesListView(
                    placesVM: places,
                    locationProvider: locationProvider,
                    currentWeather: weather,
                    onSelect: { place in
                        selectedPlace = place
                        showPlaces = false
                        Task { await loadWeather() }
                    }
                )
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showRate) {
            if let now = weather.series24h.first {
                RateFeelsLikeView(
                    snapshot: now,
                    placeID: selectedPlace?.id,
                    useFahrenheit: useFahrenheit
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .onReceive(locationProvider.$currentLocation.compactMap { $0 }) { loc in
            // Only fire on a location update when there is no data yet.
            // Prevents this from racing with pull-to-refresh or the
            // foreground auto-refresh and invalidating their loadGeneration.
            if selectedPlace == nil && weather.series24h.isEmpty {
                Task { await weather.loadFor(location: loc) }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // Auto-refresh when returning from background if data is ≥ 30 min old.
            if let fetched = weather.lastFetchedAt,
               Date().timeIntervalSince(fetched) > 1800,
               !weather.isRefreshing {
                Task { await loadWeather(preserveData: true) }
            }
        }
        .task {
            await loadWeather()
            places.refreshWeatherIfNeeded()
        }
        .onChange(of: ratings.count) { _, _ in refitRegression() }
        .onAppear { refitRegression() }
        .onReceive(progressTimer) { nowTick = $0 }
    }

    @ViewBuilder
    private func tabLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(.bar)
        Divider()
    }

    private func refitRegression() {
        let new = FeelsLikeRegression.fit(ratings: ratings)
        regressionState = new
        RegressionStateStore.save(new)
    }

    private func loadWeather(preserveData: Bool = false) async {
        if let place = selectedPlace {
            await weather.loadFor(location: place.clLocation, preserveData: preserveData)
        } else if let loc = locationProvider.currentLocation {
            await weather.loadFor(location: loc, preserveData: preserveData)
        } else {
            locationProvider.requestLocation()
        }
    }

    // MARK: Tab content (used for both real and phantom tabs)

    private var hereTodayTab: some View {
        VStack(spacing: 0) {
            tabLabel("24 hour forecast")
            HereTodayView(
                series: weather.isRefreshing ? [] : personalised(weather.series24h),
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true) },
                activeFeatures: activeFeatures
            )
        }
    }

    private var tenDayTab: some View {
        VStack(spacing: 0) {
            tabLabel("10 day forecast")
            TenDayView(
                series: weather.isRefreshing ? [] : personalised(weather.series10d),
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true) },
                activeFeatures: activeFeatures
            )
        }
    }

    private var forecastTableTab: some View {
        VStack(spacing: 0) {
            tabLabel("table")
            ForecastTableView(
                weatherService: weather,
                nowTick: nowTick,
                onRefresh: { await loadWeather(preserveData: true) },
                personalise: { self.personalised($0) },
                activeFeatures: activeFeatures
            )
        }
    }
}

// MARK: - HereTodayView

struct HereTodayView: View {
    var series: [ForecastPoint]
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Features currently in the regression model. Used to decide which
    /// scenario adjusters to show. Empty = no model, no chips shown.
    var activeFeatures: Set<Feature> = []

    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    private var dateDomain: ClosedRange<Date>? {
        guard let first = series.first?.date, let last = series.last?.date else { return nil }
        return first...last
    }

    private static let hourFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH"
        return df
    }()

    private func hourLabel(for date: Date) -> String {
        HereTodayView.hourFormatter.string(from: date)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ScrollView {
                if series.isEmpty {
                    ForecastLoadingView(progress: progress, nowTick: nowTick, errorMessage: errorMessage)
                        .padding()
                        .frame(minHeight: h)
                } else {
                    VStack(spacing: 8) {
                        ScenarioStrip(activeFeatures: activeFeatures)
                        temperatureChart(height: h * 0.55)
                        precipWindChart(height: h * 0.36)
                        if let attribution {
                            WeatherAttributionLink(info: attribution)
                        }
                    }
                    .padding(.horizontal)
                    .frame(minHeight: h)
                }
            }
            .refreshable { await onRefresh?() }
        }
    }

    @ViewBuilder
    private func temperatureChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Legend without units — units are shown on the y-axis instead.
            ChartLegendRow(entries: [
                (.purple, "MyFeelsLike", false),
                (.blue,   "Temp",        false),
                (.green,  "Wet Bulb",    false),
                (.red,    "Dew Pt",      false)
            ])
            .padding(.leading, 36)   // start near the y-axis line, not the y-axis labels

            Chart(series) { p in
                LineMark(x: .value("Time", p.date),
                         y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                         series: .value("S", "A"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                         series: .value("S", "B"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                         series: .value("S", "C"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("MyFeelsLike", useFahrenheit ? p.displayMyFeelsLikeF : p.displayMyFeelsLikeC),
                         series: .value("S", "D"))
                    .foregroundStyle(.purple).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 4.0))
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            // Unit annotation just below the topmost y-axis number, in-plot
            // (so the chart area does not need to shrink to make room).
            .overlay(alignment: .topLeading) {
                Text(useFahrenheit ? "°F" : "°C")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 14)
            }
            .frame(height: height - 20)
        }
    }

    @ViewBuilder
    private func precipWindChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.blue, "Precip %",                               true),
                (.red,  useFahrenheit ? "Wind mph" : "Wind kph",  false)
            ])
            .padding(.leading, 36)

            Chart(series) { p in
                AreaMark(x: .value("Time", p.date),
                         y: .value("Precip %", p.precipProbability * 100))
                    .foregroundStyle(Color.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                    .symbol(Circle()).symbolSize(0)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: true) {
                        Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)
        }
    }
}

// MARK: - TenDayView

struct TenDayView: View {
    var series: [ForecastPoint]
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Features currently in the regression model. Used to decide which
    /// scenario adjusters to show. Empty = no model, no chips shown.
    var activeFeatures: Set<Feature> = []

    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    private var dateDomain: ClosedRange<Date>? {
        guard let first = series.first?.date, let last = series.last?.date else { return nil }
        return first...last
    }

    private var startMidnight: Date? {
        guard let first = series.first?.date else { return nil }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: first)
        return first > midnight ? cal.date(byAdding: .day, value: 1, to: midnight) : midnight
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE"
        return df
    }()

    private static let dayAbbreviations = [
        "Mon": "Mo", "Tue": "Tu", "Wed": "We",
        "Thu": "Th", "Fri": "Fr", "Sat": "Sa", "Sun": "Su"
    ]

    private func dayLabel(for date: Date) -> String {
        guard let start = startMidnight, date >= start,
              Calendar.current.component(.hour, from: date) == 0 else { return "" }
        let key = TenDayView.dayFormatter.string(from: date)
        return TenDayView.dayAbbreviations[key] ?? String(key.prefix(2))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ScrollView {
                if series.isEmpty {
                    ForecastLoadingView(progress: progress, nowTick: nowTick, errorMessage: errorMessage)
                        .padding()
                        .frame(minHeight: h)
                } else {
                    VStack(spacing: 8) {
                        ScenarioStrip(activeFeatures: activeFeatures)
                        temperatureChart(height: h * 0.55)
                        precipWindChart(height: h * 0.36)
                        if let attribution {
                            WeatherAttributionLink(info: attribution)
                        }
                    }
                    .padding(.horizontal)
                    .frame(minHeight: h)
                }
            }
            .refreshable { await onRefresh?() }
        }
    }

    @ViewBuilder
    private func temperatureChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Legend without units — units are shown on the y-axis instead.
            ChartLegendRow(entries: [
                (.purple, "MyFeelsLike", false),
                (.blue,   "Temp",        false),
                (.green,  "Wet Bulb",    false),
                (.red,    "Dew Pt",      false)
            ])
            .padding(.leading, 36)

            Chart(series) { p in
                LineMark(x: .value("Time", p.date),
                         y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                         series: .value("S", "A"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                         series: .value("S", "B"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                         series: .value("S", "C"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", p.date),
                         y: .value("MyFeelsLike", useFahrenheit ? p.displayMyFeelsLikeF : p.displayMyFeelsLikeC),
                         series: .value("S", "D"))
                    .foregroundStyle(.purple).interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 4.0))
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            // Unit annotation just below the topmost y-axis number.
            .overlay(alignment: .topLeading) {
                Text(useFahrenheit ? "°F" : "°C")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 14)
            }
            .frame(height: height - 20)
        }
    }

    @ViewBuilder
    private func precipWindChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.blue, "Precip %",                              true),
                (.red,  useFahrenheit ? "Wind mph" : "Wind kph", false)
            ])
            .padding(.leading, 36)

            Chart(series) { p in
                AreaMark(x: .value("Time", p.date),
                         y: .value("Precip %", p.precipProbability * 100))
                    .foregroundStyle(Color.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH))
                    .foregroundStyle(.red).interpolationMethod(.linear)
                    .symbol(Circle()).symbolSize(0)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel().font(.caption)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
                            .font(.caption)
                    }
                }
            }
            .ifLet(dateDomain) { view, domain in view.chartXScale(domain: domain) }
            .frame(height: height - 20)
        }
    }
}

// MARK: - View extension

private extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let v = value { transform(self, v) } else { self }
    }
}

#Preview {
    ContentView()
}

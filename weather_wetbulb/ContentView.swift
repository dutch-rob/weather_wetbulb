import SwiftUI
import Charts
import CoreLocation
import Combine
import SwiftData

// MARK: - ForecastPoint

struct ForecastPoint: Identifiable {
    /// Where this point sits relative to "now":
    ///   .historic — observed/analysed past hour (full field set)
    ///   .current  — Apple's nowcast; lacks precip & cloud-by-altitude
    ///   .forecast — future hourly forecast (full field set)
    enum Kind { case historic, current, forecast }

    var id = UUID()
    var kind: Kind = .forecast
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
    let windGustMPH: Double
    let windGustKPH: Double
    let cloudCover: Double          // 0…1
    let cloudCoverLow: Double       // 0…1
    let cloudCoverMedium: Double    // 0…1
    let cloudCoverHigh: Double      // 0…1
    let humidity: Double            // 0…1
    let stationPressurePa: Double
    /// Personalised "feels like" score (0…1000) — populated by the regression
    /// once enough user ratings exist. Nil = no model yet.
    var myFeelsLikeScore: Double?
    /// Visual opacity of the personalised colour at this point:
    ///   1.0 = forecast firmly within training distribution
    ///   0.0 = extrapolation (don't trust the model here)
    /// Used by the chart background and the table cell to fade the colour
    /// where the model becomes unreliable.
    var myFeelsLikeOpacity: Double = 0.0

    mutating func applyPrediction(state: RegressionState?, scenario: Scenario) {
        guard let state else {
            myFeelsLikeScore = nil
            myFeelsLikeOpacity = 0
            return
        }
        let src = ForecastFeatureSource(p: self, scenario: scenario)
        myFeelsLikeScore   = state.predict(src)
        myFeelsLikeOpacity = state.predictionOpacity(src)
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
    @Environment(\.modelContext) private var modelContext
    /// One-shot wipe flag: when transitioning to the 0–1000 colour-score
    /// system, all previously-collected ratings (and the stored regression
    /// state, which was trained against feelsLikeC) are discarded so the
    /// fresh score-based model can be built from new data.
    @AppStorage("didWipeForScoreV1") private var didWipeForScoreV1: Bool = false

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

    private func personalised(_ point: ForecastPoint?) -> ForecastPoint? {
        guard let point else { return nil }
        return personalised([point]).first
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
        .onAppear {
            if !didWipeForScoreV1 {
                for r in ratings { modelContext.delete(r) }
                try? modelContext.save()
                RegressionStateStore.save(nil)
                regressionState = nil
                didWipeForScoreV1 = true
            }
            refitRegression()
        }
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
                current: weather.isRefreshing ? nil : personalised(weather.current),
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
                historic: weather.isRefreshing ? [] : personalised(weather.historic24h),
                current: weather.isRefreshing ? nil : personalised(weather.current),
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
    /// Apple's current-conditions nowcast, drawn as prominent "now" dots in a
    /// small gap to the left of the forecast curves.
    var current: ForecastPoint? = nil
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Features currently in the regression model. Used to decide which
    /// scenario adjusters to show. Empty = no model, no chips shown.
    var activeFeatures: Set<Feature> = []

    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    /// Domain begins ~1 h before "now" so the forecast curves sit slightly to
    /// the right, leaving a gap on the left for the prominent current dots.
    private var dateDomain: ClosedRange<Date>? {
        guard let last = series.last?.date else { return nil }
        let lo: Date
        if let c = current?.date {
            lo = c.addingTimeInterval(-3600)
        } else if let first = series.first?.date {
            lo = first
        } else {
            return nil
        }
        return lo...last
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

            Chart {
                ForEach(series) { p in
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
                    // Official apparent temperature from WeatherKit — always drawn,
                    // solid, same thickness as the other lines. The personalised
                    // model is shown as a chart background colour instead of a line.
                    LineMark(x: .value("Time", p.date),
                             y: .value("Apparent",
                                       useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC),
                             series: .value("S", "D"))
                        .foregroundStyle(.purple).interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                // Prominent "now" dots in the gap left of the forecast curves.
                if let c = current {
                    PointMark(x: .value("Time", c.date),
                              y: .value("Temp", useFahrenheit ? c.temperatureF : c.temperatureC))
                        .foregroundStyle(.blue).symbolSize(110)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Wet Bulb", useFahrenheit ? c.wetBulbF : c.wetBulbC))
                        .foregroundStyle(.green).symbolSize(110)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Dew Point", useFahrenheit ? c.dewPointF : c.dewPointC))
                        .foregroundStyle(.red).symbolSize(110)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Apparent",
                                        useFahrenheit ? c.apparentTemperatureF : c.apparentTemperatureC))
                        .foregroundStyle(.purple).symbolSize(110)
                }
            }
            .chartBackground { proxy in
                let stops = myFeelsLikeBackgroundStops(series, domain: dateDomain)
                if !stops.isEmpty {
                    GeometryReader { geo in
                        let frame = geo[proxy.plotAreaFrame]
                        LinearGradient(
                            gradient: Gradient(stops: stops),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
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
                (.blue,             "Precip %",                                true),
                (.red,              useFahrenheit ? "Wind mph" : "Wind kph",   false),
                (.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph",   false)
            ])
            .padding(.leading, 36)

            Chart {
                ForEach(series) { p in
                    AreaMark(x: .value("Time", p.date),
                             y: .value("Precip %", p.precipProbability * 100))
                        .foregroundStyle(Color.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                    LineMark(x: .value("Time", p.date),
                             y: .value("Gust", useFahrenheit ? p.windGustMPH : p.windGustKPH),
                             series: .value("S", "G"))
                        .foregroundStyle(.red.opacity(0.45)).interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .symbol(Circle()).symbolSize(0)
                    LineMark(x: .value("Time", p.date),
                             y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH),
                             series: .value("S", "W"))
                        .foregroundStyle(.red).interpolationMethod(.linear)
                        .symbol(Circle()).symbolSize(0)
                }
                // Prominent "now" wind/gust dots (current has no precipitation).
                if let c = current {
                    PointMark(x: .value("Time", c.date),
                              y: .value("Gust", useFahrenheit ? c.windGustMPH : c.windGustKPH))
                        .foregroundStyle(.red.opacity(0.45)).symbolSize(90)
                    PointMark(x: .value("Time", c.date),
                              y: .value("Wind", useFahrenheit ? c.windSpeedMPH : c.windSpeedKPH))
                        .foregroundStyle(.red).symbolSize(90)
                }
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
    /// Observed past ~24 h, drawn dashed to the left of the forecast.
    var historic: [ForecastPoint] = []
    /// "now" boundary point joining the dashed history to the solid forecast.
    var current: ForecastPoint? = nil
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil
    var attribution: WeatherAttributionInfo? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Features currently in the regression model. Used to decide which
    /// scenario adjusters to show. Empty = no model, no chips shown.
    var activeFeatures: Set<Feature> = []

    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    /// Historic + "now", used for the dashed past line.
    private var historicPlus: [ForecastPoint] {
        historic + (current.map { [$0] } ?? [])
    }
    /// "now" + forecast, used for the solid future line (joins at "now").
    private var forecastPlus: [ForecastPoint] {
        (current.map { [$0] } ?? []) + series
    }
    /// All plotted points oldest→newest, for the MyFeelsLike colour background.
    private var allPoints: [ForecastPoint] {
        historic + (current.map { [$0] } ?? []) + series
    }

    private var earliestDate: Date? {
        historic.first?.date ?? current?.date ?? series.first?.date
    }

    private var dateDomain: ClosedRange<Date>? {
        guard let lo = earliestDate, let last = series.last?.date else { return nil }
        return lo...last
    }

    private var startMidnight: Date? {
        guard let first = earliestDate else { return nil }
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

    /// The four temperature lines (temp/wet-bulb/dew/apparent) over a set of
    /// points. `suffix` keeps the historic and forecast series distinct so they
    /// are not connected across the "now" boundary; `dash` nil = solid.
    @ChartContentBuilder
    private func tempLines(_ pts: [ForecastPoint], suffix: String, dash: [CGFloat]?) -> some ChartContent {
        ForEach(pts) { p in
            LineMark(x: .value("Time", p.date),
                     y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                     series: .value("S", "A" + suffix))
                .foregroundStyle(.blue).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: dash ?? []))
            LineMark(x: .value("Time", p.date),
                     y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                     series: .value("S", "B" + suffix))
                .foregroundStyle(.green).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: dash ?? []))
            LineMark(x: .value("Time", p.date),
                     y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                     series: .value("S", "C" + suffix))
                .foregroundStyle(.red).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: dash ?? []))
            LineMark(x: .value("Time", p.date),
                     y: .value("Apparent",
                               useFahrenheit ? p.apparentTemperatureF : p.apparentTemperatureC),
                     series: .value("S", "D" + suffix))
                .foregroundStyle(.purple).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: dash ?? []))
        }
    }

    /// Gust (always dashed) and wind lines over a set of points. `windDash`
    /// makes the wind line dashed for the historic pass, solid for the forecast.
    @ChartContentBuilder
    private func windLines(_ pts: [ForecastPoint], suffix: String, windDash: [CGFloat]?) -> some ChartContent {
        ForEach(pts) { p in
            LineMark(x: .value("Time", p.date),
                     y: .value("Gust", useFahrenheit ? p.windGustMPH : p.windGustKPH),
                     series: .value("S", "G" + suffix))
                .foregroundStyle(.red.opacity(0.45)).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                .symbol(Circle()).symbolSize(0)
            LineMark(x: .value("Time", p.date),
                     y: .value("Wind", useFahrenheit ? p.windSpeedMPH : p.windSpeedKPH),
                     series: .value("S", "W" + suffix))
                .foregroundStyle(.red).interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: windDash ?? []))
                .symbol(Circle()).symbolSize(0)
        }
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

            Chart {
                // Dashed past (historic → now), solid future (now → forecast);
                // the two share the "now" point so the lines join.
                tempLines(historicPlus, suffix: "h", dash: [4, 3])
                tempLines(forecastPlus, suffix: "",  dash: nil)
            }
            .chartBackground { proxy in
                let stops = myFeelsLikeBackgroundStops(allPoints, domain: dateDomain)
                if !stops.isEmpty {
                    GeometryReader { geo in
                        let frame = geo[proxy.plotAreaFrame]
                        LinearGradient(
                            gradient: Gradient(stops: stops),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
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
                (.blue,             "Precip %",                                true),
                (.red,              useFahrenheit ? "Wind mph" : "Wind kph",   false),
                (.red.opacity(0.5), useFahrenheit ? "Gust mph" : "Gust kph",   false)
            ])
            .padding(.leading, 36)

            Chart {
                // Precipitation as one continuous area across history + forecast
                // ("now" is skipped — CurrentWeather has no precip).
                ForEach(historic + series) { p in
                    AreaMark(x: .value("Time", p.date),
                             y: .value("Precip %", p.precipProbability * 100))
                        .foregroundStyle(Color.blue.opacity(0.3).gradient).interpolationMethod(.linear)
                }
                // Wind/gust: dashed past, solid future, joined at "now".
                windLines(historicPlus, suffix: "h", windDash: [4, 3])
                windLines(forecastPlus, suffix: "",  windDash: nil)
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

// MARK: - Personalised colour background for the temperature chart

/// Maximum alpha applied to the model-prediction background in temperature
/// charts. Keeps the chart's foreground lines readable.
private let chartBackgroundMaxAlpha: Double = 0.55

/// Build the horizontal gradient stops representing the model's predicted
/// score at each point. Each stop is placed by its **time** position within
/// `domain` (so it aligns with the curves even when the domain extends past
/// the first/last point, e.g. the 24h graph's left gap); each stop's alpha is
/// the model's own opacity (= leverage fade) capped by chartBackgroundMaxAlpha.
///
/// Returns an empty array when no point has a score (no model fitted).
private func myFeelsLikeBackgroundStops(
    _ series: [ForecastPoint],
    domain: ClosedRange<Date>?
) -> [Gradient.Stop] {
    guard series.count > 1 else { return [] }
    guard series.contains(where: { $0.myFeelsLikeScore != nil }) else { return [] }
    // Fall back to the series' own span when no explicit domain is given.
    let lo = domain?.lowerBound ?? series.first!.date
    let hi = domain?.upperBound ?? series.last!.date
    let span = hi.timeIntervalSince(lo)
    guard span > 0 else { return [] }
    return series.compactMap { p -> Gradient.Stop? in
        guard let score = p.myFeelsLikeScore else { return nil }
        let alpha = max(0, min(1, p.myFeelsLikeOpacity)) * chartBackgroundMaxAlpha
        let color = ColorScale.color(forScore: score).opacity(alpha)
        let loc = max(0, min(1, p.date.timeIntervalSince(lo) / span))
        return Gradient.Stop(color: color, location: CGFloat(loc))
    }
}

// MARK: - Solid-run tagging for the MyFeelsLike chart line (legacy, unused)

#if false
private struct TaggedPoint: Identifiable {
    var id: UUID { base.id }
    let base: ForecastPoint
    let solidRunID: Int?
}

/// Assigns each contiguous run of w==0 points a unique integer run ID.
private func tagSolidRuns(_ pts: [ForecastPoint]) -> [TaggedPoint] {
    var out: [TaggedPoint] = []
    var runID = 0
    var prevWasBlended = true
    for p in pts {
        if p.myFeelsLikeApparentWeight == 0 {
            if prevWasBlended { runID += 1 }   // new run starts
            out.append(TaggedPoint(base: p, solidRunID: runID))
            prevWasBlended = false
        } else {
            out.append(TaggedPoint(base: p, solidRunID: nil))
            prevWasBlended = true
        }
    }
    return out
}
#endif

// MARK: - Indoor (evaporative cooler) controls — currently disabled

#if false
struct IndoorControlsView: View {
    @Binding var insulation: Double
    @AppStorage("fanEnabled") private var fanEnabled: Bool = false
    @AppStorage("fanWindKPH") private var fanWindKPH: Double = 10
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("House insulation").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(insulation.rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $insulation, in: 0...100, step: 1)
                Text("0 = indoor ≈ outdoor air   ·   100 = cools to wet-bulb")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $fanEnabled) {
                Text("Fan").font(.subheadline.weight(.semibold))
            }

            if fanEnabled {
                let unit  = useFahrenheit ? "mph" : "kph"
                let shown = useFahrenheit ? fanWindKPH / 1.609344 : fanWindKPH
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Fan air speed").font(.caption)
                        Spacer()
                        Text(String(format: "%.0f %@", shown, unit))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $fanWindKPH, in: 0...40, step: 1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}
#endif

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

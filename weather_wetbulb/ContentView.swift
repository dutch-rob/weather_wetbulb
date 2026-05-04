import SwiftUI
import Charts
import CoreLocation
import Combine

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
    @State private var showPlaces = false
    @State private var showInfo   = false
    @State private var selectedTab = 0
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true

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

            // Line 2 (tab subtitle) + content swipe as one unit
            TabView(selection: $selectedTab) {
                VStack(spacing: 0) {
                    tabLabel("24 hour forecast")
                    if weather.isRefreshing {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    HereTodayView(
                        series: weather.series24h,
                        progress: weather.loadProgress,
                        nowTick: nowTick,
                        errorMessage: weather.lastErrorMessage,
                        attribution: weather.attribution,
                        onRefresh: { await loadWeather(preserveData: true) }
                    )
                }
                .tag(0)

                VStack(spacing: 0) {
                    tabLabel("10 day forecast")
                    if weather.isRefreshing {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    TenDayView(
                        series: weather.series10d,
                        progress: weather.loadProgress,
                        nowTick: nowTick,
                        errorMessage: weather.lastErrorMessage,
                        attribution: weather.attribution,
                        onRefresh: { await loadWeather(preserveData: true) }
                    )
                }
                .tag(1)

                VStack(spacing: 0) {
                    tabLabel("table")
                    if weather.isRefreshing {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    ForecastTableView(
                        weatherService: weather,
                        nowTick: nowTick,
                        onRefresh: { await loadWeather(preserveData: true) }
                    )
                }
                .tag(2)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        }
        .safeAreaInset(edge: .bottom) {
            ZStack {
                // Places button – centred
                Button { showPlaces = true } label: {
                    Label("Places", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }

                HStack {
                    // Unit toggle – bottom-left corner
                    Button { useFahrenheit.toggle() } label: {
                        Text(useFahrenheit ? "°F" : "°C")
                            .font(.title3)
                            .fontWeight(.medium)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                    }

                    Spacer()

                    // Info button – bottom-right corner
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
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
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                InfoView()
            }
            .presentationDetents([.large])
        }
        .onReceive(locationProvider.$currentLocation.compactMap { $0 }) { loc in
            if selectedPlace == nil { Task { await weather.loadFor(location: loc) } }
        }
        .task {
            await loadWeather()
            places.refreshWeatherIfNeeded()
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

    private func loadWeather(preserveData: Bool = false) async {
        if let place = selectedPlace {
            await weather.loadFor(location: place.clLocation, preserveData: preserveData)
        } else if let loc = locationProvider.currentLocation {
            await weather.loadFor(location: loc, preserveData: preserveData)
        } else {
            locationProvider.requestLocation()
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
            ChartLegendRow(entries: [
                (.blue,  useFahrenheit ? "Temp °F"     : "Temp °C",     false),
                (.green, useFahrenheit ? "Wet Bulb °F" : "Wet Bulb °C", false),
                (.red,   useFahrenheit ? "Dew Pt °F"   : "Dew Pt °C",   false)
            ])
            .padding(.leading, 8)

            Chart(series) { p in
                LineMark(x: .value("Time", p.date),
                         y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                         series: .value("S", "A"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                         series: .value("S", "B"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                         series: .value("S", "C"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
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

    @ViewBuilder
    private func precipWindChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ChartLegendRow(entries: [
                (.blue, "Precip %",                               true),
                (.red,  useFahrenheit ? "Wind mph" : "Wind kph",  false)
            ])
            .padding(.leading, 8)

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
            ChartLegendRow(entries: [
                (.blue,  useFahrenheit ? "Temp °F"     : "Temp °C",     false),
                (.green, useFahrenheit ? "Wet Bulb °F" : "Wet Bulb °C", false),
                (.red,   useFahrenheit ? "Dew Pt °F"   : "Dew Pt °C",   false)
            ])
            .padding(.leading, 8)

            Chart(series) { p in
                LineMark(x: .value("Time", p.date),
                         y: .value("Temp", useFahrenheit ? p.temperatureF : p.temperatureC),
                         series: .value("S", "A"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Wet Bulb", useFahrenheit ? p.wetBulbF : p.wetBulbC),
                         series: .value("S", "B"))
                    .foregroundStyle(.green).interpolationMethod(.linear)
                LineMark(x: .value("Time", p.date),
                         y: .value("Dew Point", useFahrenheit ? p.dewPointF : p.dewPointC),
                         series: .value("S", "C"))
                    .foregroundStyle(.red).interpolationMethod(.linear)
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
            .padding(.leading, 8)

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

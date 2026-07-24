import SwiftUI
import CoreLocation
import Combine

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var weather = WeatherService()
    @StateObject private var places = PlacesViewModel()
    @State private var selectedPlace: Place? = nil
    @State private var nowTick: Date = .now
    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var showPlaces = false
    @State private var showSettings = false
    // Tab indices: 0 = table phantom, 1 = 24h (real), 2 = 10d (real),
    //              3 = table (real), 4 = 24h phantom  — for circular wrap.
    @State private var selectedTab = 1
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.chartStyle) private var chartStyleRaw = ChartStyle.filled.rawValue
    @AppStorage(SettingsKey.showTable) private var showTable = true
    @AppStorage(SettingsKey.useFoldTimeline) private var useFoldTimeline = false
    @AppStorage(SettingsKey.indoorTrackingEnabled) private var indoorTracking = false
    @Environment(\.scenePhase) private var scenePhase
    private let indoorTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()

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

            if useFoldTimeline {
                foldTab
            } else if showTable {
                // 5-tab wrap-around: 0 = table phantom → 3, 1 = 24h (default),
                // 2 = 10d, 3 = table, 4 = 24h phantom → 1. Phantoms show
                // identical content; onChange teleports to the real tab with no
                // animation so the jump is invisible.
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
            } else {
                // No table: 4-tab wrap-around between just 24h and 10d.
                //   0 = 10d phantom → 2, 1 = 24h (default), 2 = 10d, 3 = 24h phantom → 1
                TabView(selection: $selectedTab) {
                    tenDayTab.tag(0)
                    hereTodayTab.tag(1)
                    tenDayTab.tag(2)
                    hereTodayTab.tag(3)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .onChange(of: selectedTab) { _, tab in
                    guard tab == 0 || tab == 3 else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { selectedTab = tab == 0 ? 2 : 1 }
                }
            }
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

                    // Settings button – bottom-right corner
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
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .presentationDetents([.large])
        }
        .onReceive(locationProvider.$currentLocation.compactMap { $0 }) { loc in
            // Only fire on a location update when there is no data yet.
            // Prevents this from racing with pull-to-refresh or the
            // foreground auto-refresh and invalidating their loadGeneration.
            if selectedPlace == nil && weather.series24h.isEmpty {
                Task { await weather.loadFor(location: loc) }
            }
            // Remember where "home" is for indoor sampling (only while at the
            // current location and tracking is on).
            if indoorTracking && selectedPlace == nil {
                IndoorSamplingCoordinator.shared.updateHomeLocation(loc)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            pushToWatch()
            Task { await IndoorSamplingCoordinator.shared.sampleIfDue() }
            // Auto-refresh when returning from background if data is ≥ 30 min old.
            if let fetched = weather.lastFetchedAt,
               Date().timeIntervalSince(fetched) > 1800,
               !weather.isRefreshing {
                Task { await loadWeather(preserveData: true) }
            }
        }
        // Keep the watch in sync whenever the settings or places change.
        .onChange(of: useFahrenheit) { _, _ in pushToWatch() }
        .onChange(of: chartStyleRaw) { _, _ in pushToWatch() }
        .onChange(of: places.places) { _, _ in pushToWatch() }
        .task {
            PhoneWatchSync.shared.start()
            pushToWatch()
            if indoorTracking {
                HomeKitService.shared.start()                       // begin discovery early
                IndoorSamplingCoordinator.shared.scheduleBackgroundSample()
                await IndoorSamplingCoordinator.shared.sampleIfDue()
            }
            await loadWeather()
            places.refreshWeatherIfNeeded()
        }
        .onReceive(progressTimer) { nowTick = $0 }
        .onReceive(indoorTimer) { _ in
            Task { await IndoorSamplingCoordinator.shared.sampleIfDue() }
        }
    }

    /// Push the current display settings + saved places to the watch.
    private func pushToWatch() {
        let dtos = places.places.map {
            PlaceDTO(id: $0.id, name: $0.name,
                     latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
        }
        PhoneWatchSync.shared.update(useFahrenheit: useFahrenheit,
                                     chartStyle: chartStyleRaw,
                                     places: dtos)
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

    private func loadWeather(preserveData: Bool = false, useFreshLocation: Bool = false) async {
        if let place = selectedPlace {
            await weather.loadFor(location: place.clLocation, preserveData: preserveData)
        } else {
            let loc = useFreshLocation
                ? await locationProvider.requestFreshLocation()
                : locationProvider.currentLocation
            if let loc {
                await weather.loadFor(location: loc, preserveData: preserveData)
            } else {
                locationProvider.requestLocation()
            }
        }
    }

    // MARK: Tab content (used for both real and phantom tabs)

    private var hereTodayTab: some View {
        VStack(spacing: 0) {
            tabLabel("24 hour forecast")
            HereTodayView(
                series: weather.isRefreshing ? [] : weather.series24h,
                current: weather.isRefreshing ? nil : weather.current,
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) }
            )
        }
    }

    private var tenDayTab: some View {
        VStack(spacing: 0) {
            tabLabel("10 day forecast")
            TenDayView(
                series: weather.isRefreshing ? [] : weather.series10d,
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) }
            )
        }
    }

    private var forecastTableTab: some View {
        VStack(spacing: 0) {
            tabLabel("table")
            ForecastTableView(
                weatherService: weather,
                nowTick: nowTick,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) }
            )
        }
    }

    private var foldTab: some View {
        VStack(spacing: 0) {
            tabLabel("timeline · swipe to zoom")
            FoldTimelineView(
                series: weather.isRefreshing ? [] : weather.series10d,
                current: weather.isRefreshing ? nil : weather.current,
                progressLoad: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) }
            )
        }
    }
}

#Preview {
    ContentView()
}

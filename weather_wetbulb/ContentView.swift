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
    @State private var showWhatsNew = false
    @AppStorage(SettingsKey.lastSeenVersion) private var lastSeenVersion = ""
    @AppStorage(SettingsKey.isUpgradeUser) private var isUpgradeUser = false
    /// Which screen is showing (vertical swipe walks these).
    @State private var screen: ForecastScreen = .today
    /// Left edge of the visible window, as an offset from "now". Shared by both
    /// graph screens so panning survives a screen switch.
    @State private var startOffset: TimeInterval = 0
    @State private var panBase: TimeInterval? = nil
    /// Locked once a drag has clearly chosen an axis, so a diagonal swipe
    /// doesn't both pan and switch screens.
    @State private var dragAxis: DragAxis? = nil

    private enum DragAxis { case horizontal, vertical }
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.chartStyle) private var chartStyleRaw = ChartStyle.filled.rawValue
    @AppStorage(SettingsKey.showTable) private var showTable = true
    @AppStorage(SettingsKey.useFoldTimeline) private var useFoldTimeline = false
    @Environment(\.scenePhase) private var scenePhase

    private var displayTitle: String {
        if let name = selectedPlace?.name { return name }
        return weather.placeDescription.isEmpty ? "Loading…" : weather.placeDescription
    }

    var body: some View {
        VStack(spacing: 0) {
            // Line 1: place name (taps open the places sheet) with a refresh
            // button on the right. Refresh lives here because the vertical
            // swipe that used to pull-to-refresh now switches screens.
            ZStack {
                Button { showPlaces = true } label: {
                    Text(displayTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal)
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await loadWeather(preserveData: true, useFreshLocation: true) }
                    } label: {
                        if weather.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(weather.isRefreshing)
                    .padding(.horizontal)
                    .accessibilityLabel("Refresh forecast")
                }
            }
            .background(.bar)

            Divider()

            if useFoldTimeline {
                foldTab
            } else {
                GeometryReader { geo in
                    ZStack {
                        switch screen {
                        case .today:  hereTodayTab
                        case .tenDay: tenDayTab
                        case .table:  forecastTableTab
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    // The table owns its own vertical scrolling, so it opts out
                    // of this gesture and switches screens on over-scroll instead.
                    .gesture(screen == .table ? nil : graphDrag(size: geo.size))
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
        // Shown once per version, on the first open after installing/updating.
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(isUpgrade: isUpgradeUser) {
                lastSeenVersion = appVersionString
                showWhatsNew = false
            }
            .interactiveDismissDisabled()
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
            pushToWatch()
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
            if lastSeenVersion != appVersionString { showWhatsNew = true }
            PhoneWatchSync.shared.start()
            pushToWatch()
            await loadWeather()
            places.refreshWeatherIfNeeded()
        }
        .onReceive(progressTimer) { nowTick = $0 }
    }


    // MARK: - Paged-mode gestures

    /// Horizontal drag pans the time window; vertical drag switches screens.
    /// The axis is decided once per drag so a diagonal doesn't do both.
    private func graphDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if dragAxis == nil {
                    dragAxis = abs(v.translation.width) >= abs(v.translation.height)
                        ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                if panBase == nil { panBase = startOffset }
                // Dragging a full screen width pans by one window span.
                let span = screen.span
                let dt = -Double(v.translation.width) / Double(max(1, size.width)) * span
                startOffset = clampedOffset((panBase ?? startOffset) + dt)
            }
            .onEnded { v in
                defer { dragAxis = nil; panBase = nil }
                if dragAxis == .vertical {
                    let dy = v.translation.height
                    guard abs(dy) > 40 else { return }
                    // Swipe up = next screen, swipe down = previous.
                    withAnimation(.easeInOut(duration: 0.25)) {
                        screen = screen.advanced(by: dy < 0 ? 1 : -1, includeTable: showTable)
                        startOffset = clampedOffset(startOffset)
                    }
                }
            }
    }

    private func clampedOffset(_ o: TimeInterval) -> TimeInterval {
        TimelineScroll.clampStartOffset(o, span: screen.span, now: nowTick,
                                        dataLo: weather.seriesFull.first?.date,
                                        dataHi: weather.seriesFull.last?.date)
    }

    /// Left edge of the visible window.
    private var windowStart: Date { nowTick.addingTimeInterval(startOffset) }

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

    /// The full -10d…+10d series the graph screens pan over (falls back to the
    /// plain forecast until history has been merged in).
    private var panSeries: [ForecastPoint] {
        weather.seriesFull.isEmpty ? weather.series10d : weather.seriesFull
    }

    /// Screen title, with the window's date once the user has scrolled off "now".
    private func windowLabel(_ s: ForecastScreen) -> String {
        let drift = abs(windowStart.timeIntervalSince(nowTick))
        guard drift > 3600 else { return s.title }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEd MMM")
        return "\(s.title) · \(f.string(from: windowStart))"
    }

    private var hereTodayTab: some View {
        VStack(spacing: 0) {
            tabLabel(windowLabel(.today))
            HereTodayView(
                allSeries: weather.isRefreshing ? [] : panSeries,
                windowStart: windowStart,
                windowSpan: ForecastScreen.today.span,
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
            tabLabel(windowLabel(.tenDay))
            TenDayView(
                allSeries: weather.isRefreshing ? [] : panSeries,
                windowStart: windowStart,
                windowSpan: ForecastScreen.tenDay.span,
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
            tabLabel(ForecastScreen.table.title)
            ForecastTableView(
                weatherService: weather,
                nowTick: nowTick,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) },
                onSwitchScreen: { step in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        screen = screen.advanced(by: step, includeTable: showTable)
                        startOffset = clampedOffset(startOffset)
                    }
                }
            )
        }
    }

    private var foldTab: some View {
        VStack(spacing: 0) {
            tabLabel("timeline · swipe ↔ to scroll, ↕ to zoom")
            FoldTimelineView(
                series: weather.isRefreshing ? [] : panSeries,
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

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
    @State private var showInfo = false
    @State private var showWhatsNew = false
    @AppStorage(SettingsKey.lastSeenVersion) private var lastSeenVersion = ""
    @AppStorage(SettingsKey.isUpgradeUser) private var isUpgradeUser = false
    @AppStorage(SettingsKey.lastSeenBuild) private var lastSeenBuild = ""

    /// The build currently running, identified by when it was linked.
    private var buildStamp: String {
        BuildInfo.date.map { String(Int($0.timeIntervalSince1970)) } ?? ""
    }
    /// Which screen is showing (vertical swipe walks these).
    @State private var screen: ForecastScreen = .today
    /// Left edge of the visible window, as an offset from "now". Shared by both
    /// graph screens so panning survives a screen switch.
    ///
    @State private var startOffset: TimeInterval = 0
    @State private var panBase: TimeInterval? = nil
    /// Locked once a drag has clearly chosen an axis, so a diagonal swipe
    /// doesn't both pan and switch screens.
    @State private var dragAxis: DragAxis? = nil
    /// How far the screen has been dragged vertically, so the screens move with
    /// the finger instead of jumping at the end of the gesture.
    @State private var dragY: CGFloat = 0
    /// With the fold timeline on, whether the table is showing instead.
    @State private var foldShowsTable = false
    /// The moment showing at the top of the table, so switching between the
    /// table and a graph keeps the same place in time.
    @State private var tableTopDate: Date? = nil
    /// Model report sheet, reachable from the graph screen's left button.
    @State private var showModelReport = false
    /// Which graph to come back to from the table.
    @State private var lastGraph: ForecastScreen = .today

    private enum DragAxis { case horizontal, vertical }
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
            // Line 1: place name (taps open the places sheet) with a refresh
            // button on the right. Refresh lives here because the vertical
            // swipe that used to pull-to-refresh now switches screens.
            //
            // Side by side, never stacked. These were layered in a ZStack with
            // the place button spanning the full width underneath, so any tap
            // that missed the small refresh icon by a few points fell through
            // and opened Places instead of refreshing.
            HStack(spacing: 0) {
                // Same width as the refresh button, so the title stays centred.
                Color.clear.frame(width: 44, height: 44)
                Button { showPlaces = true } label: {
                    Text(displayTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                Button {
                    Task { await loadWeather(preserveData: true, useFreshLocation: true) }
                } label: {
                    Group {
                        if weather.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    // A full 44-point target, the minimum Apple recommends.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(weather.isRefreshing)
                .accessibilityLabel("Refresh forecast")
            }
            .padding(.horizontal, 4)
            .background(.bar)

            Divider()

            if useFoldTimeline {
                if showTable && foldShowsTable {
                    forecastTableTab
                } else {
                    foldTab
                }
            } else {
                GeometryReader { geo in
                    let hgt = geo.size.height
                    ZStack {
                        // The screen being dragged towards, parked just off the
                        // edge so it slides in with the finger.
                        if dragY != 0 {
                            screenView(screen.advanced(by: dragY < 0 ? 1 : -1,
                                                       includeTable: false))
                                .offset(y: dragY < 0 ? hgt + dragY : -hgt + dragY)
                        }
                        screenView(screen).offset(y: dragY)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
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

                    // About, just left of Settings
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .padding(.vertical, 10)
                    }
                    .accessibilityLabel("About WetBulbCast")

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
        .sheet(isPresented: $showInfo) {
            NavigationStack { InfoView() }
        }
        // Shown once per version, on the first open after installing/updating.
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(isUpgrade: isUpgradeUser) {
                lastSeenVersion = appVersionString
                lastSeenBuild = buildStamp
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
            // Released builds: once per version. Development builds also show it
            // after every install from Xcode, where the version number rarely
            // changes between builds — the executable's link time does.
            var show = lastSeenVersion != appVersionString
            #if DEBUG
            if !buildStamp.isEmpty && lastSeenBuild != buildStamp { show = true }
            #endif
            if show { showWhatsNew = true }
            PhoneWatchSync.shared.start()
            pushToWatch()
            if indoorTracking {
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
                if dragAxis == .vertical {
                    dragY = v.translation.height
                    return
                }
                if panBase == nil { panBase = startOffset }
                // Dragging a full screen width pans by one window span.
                let span = screen.span
                let dt = -Double(v.translation.width) / Double(max(1, size.width)) * span
                startOffset = clampedOffset((panBase ?? startOffset) + dt)
            }
            .onEnded { v in
                let axis = dragAxis
                dragAxis = nil; panBase = nil
                guard axis == .vertical else { return }
                let dy = v.translation.height
                let step = dy < 0 ? 1 : -1
                // Carry the screen the rest of the way if the swipe was
                // decisive, otherwise let it fall back.
                if abs(dy) > 60 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragY = dy < 0 ? -size.height : size.height
                    } completion: {
                        screen = screen.advanced(by: step, includeTable: false)
                        startOffset = clampedOffset(startOffset)
                        dragY = 0
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragY = 0 }
                }
            }
    }

    @ViewBuilder
    private func screenView(_ s: ForecastScreen) -> some View {
        switch s {
        case .today:  hereTodayTab
        case .tenDay: tenDayTab
        case .table:  forecastTableTab
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

    /// Title with buttons to the screens the user is not on. Gestures alone are
    /// impractical for reaching a screen now that the graphs scroll ten days.
    private func headerBar(_ title: String,
                           left: (String, () -> Void)? = nil,
                           right: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 78)
                HStack {
                    if let left { Button(left.0) { left.1() } }
                    Spacer()
                    if let right { Button(right.0) { right.1() } }
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
        }
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
            headerBar(windowLabel(.today),
                      left: ("10-day", { goToScreen(.tenDay) }),
                      right: showTable ? ("table", { goToTable() }) : nil)
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
            headerBar(windowLabel(.tenDay),
                      left: ("24h", { goToScreen(.today) }),
                      right: showTable ? ("table", { goToTable() }) : nil)
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

    /// The table's header doubles as navigation.
    private var tableHeader: some View {
        useFoldTimeline
            ? headerBar(ForecastScreen.table.title,
                        left: ("graph", { leaveTable(to: nil) }))
            : headerBar(ForecastScreen.table.title,
                        left: ("24h", { leaveTable(to: .today) }),
                        right: ("10-day", { leaveTable(to: .tenDay) }))
    }

    /// Entering the table: line it up with the moment the graph is showing.
    private func goToTable() {
        tableTopDate = windowStart
        lastGraph = screen
        withAnimation(.easeInOut(duration: 0.25)) {
            if useFoldTimeline { foldShowsTable = true } else { screen = .table }
        }
    }

    /// Leaving the table: start the graph at the table's top visible row, so the
    /// two screens stay on the same moment in time.
    private func leaveTable(to target: ForecastScreen?) {
        let dest = target ?? lastGraph
        if let d = tableTopDate {
            // Clamp against the span of the screen we are going TO. Using the
            // table's own ten-day span would pin any future date back to "now",
            // because a ten-day window cannot start later than that.
            let span = useFoldTimeline ? ForecastScreen.today.span : dest.span
            startOffset = TimelineScroll.clampStartOffset(
                d.timeIntervalSince(nowTick), span: span, now: nowTick,
                dataLo: weather.seriesFull.first?.date,
                dataHi: weather.seriesFull.last?.date)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            if useFoldTimeline { foldShowsTable = false } else { screen = dest }
        }
    }

    private func goToScreen(_ s: ForecastScreen) {
        withAnimation(.easeInOut(duration: 0.25)) {
            screen = s
            startOffset = clampedOffset(startOffset)
        }
    }

    private var forecastTableTab: some View {
        VStack(spacing: 0) {
            tableHeader
            ForecastTableView(
                weatherService: weather,
                nowTick: nowTick,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) },
                onSwitchScreen: { _ in leaveTable(to: nil) },
                topDate: $tableTopDate
            )
        }
    }

    private var foldTab: some View {
        VStack(spacing: 0) {
            headerBar("graph",
                      left: ("model", { showModelReport = true }),
                      right: showTable ? ("table", { goToTable() }) : nil)
            FoldTimelineView(
                series: weather.isRefreshing ? [] : panSeries,
                startOffset: $startOffset,
                current: weather.isRefreshing ? nil : weather.current,
                progressLoad: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) }
            )
        }
        .sheet(isPresented: $showModelReport) {
            // The same location the forecast series was fetched for, so the
            // sun geometry and the weather describe one place.
            ModelReportView(series: weather.seriesFull,
                            location: selectedPlace?.clLocation ?? locationProvider.currentLocation)
        }
    }
}

#Preview {
    ContentView()
}

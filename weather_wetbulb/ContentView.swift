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
    @State private var showEvents = false
    /// The indoor forecast, reached by a vertical swipe from the zoom graph.
    /// The indoor forecast, reached by a vertical swipe from the zoom graph.
    /// The UI tests open it directly, having no way to swipe their way in
    /// before the first frame.
    @State private var foldShowsIndoor = ProcessInfo.processInfo.environment["FORECAST_PREVIEW"] != nil
    /// Which graph to come back to from the table.
    @State private var lastGraph: ForecastScreen = .today

    private enum DragAxis { case horizontal, vertical }
    @AppStorage("useFahrenheit") private var useFahrenheit: Bool = true
    @AppStorage(SettingsKey.chartStyle) private var chartStyleRaw = ChartStyle.filled.rawValue
    @AppStorage(SettingsKey.showTable) private var showTable = true
    @AppStorage(SettingsKey.useFoldTimeline) private var useFoldTimeline = false
    @AppStorage(SettingsKey.indoorTrackingEnabled) private var indoorTracking = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let indoorTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()

    private var displayTitle: String {
        // The indoor forecast is always about the monitored home, whichever
        // place the graphs happen to be showing, so the title has to say so.
        if foldShowsIndoor, let home = places.monitoredHome?.name { return home }
        if let name = selectedPlace?.name { return name }
        return weather.placeDescription.isEmpty ? "Loading…" : weather.placeDescription
    }

    // MARK: - Folding device

    /// How the device is folded and how flat it lies.
    @StateObject private var posture = DevicePosture()
    /// The panel itself, safe areas included. The crease is its middle, and
    /// half its height is the part of a propped-open device you can see.
    @State private var metrics = WindowMetrics()
    /// Where the split pane starts inside that panel.
    @State private var splitOriginX: CGFloat = 0

    private enum LayoutMode { case pager, splitPane }

    /// Shortest side that still belongs to a tablet rather than an open phone.
    ///
    /// Measured on the short side rather than the width, because the width
    /// changes with orientation and the device does not: an unfolded iPhone Duo
    /// is 669 x 951 pt, so in landscape it is 951 pt wide and sails past any
    /// width test. Its short side is 669 pt whichever way it is held, against
    /// 744 pt for the smallest iPad, so the gap holds in both orientations.
    private static let tabletMinShortSide: CGFloat = 700

    /// Which layout the panel gets. Size class cannot decide this on its own:
    /// an unfolded foldable reports regular in *both* dimensions exactly as an
    /// iPad does, while being barely half its width.
    private var layoutMode: LayoutMode {
        // Propped on a table there is one visible half, and it shows one
        // screen. Not negotiable by measurement: halving the height makes the
        // visible part wider than it is tall, which would otherwise read as
        // room for two panes.
        if isTabletopPose { return .pager }
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return .pager }
        let size = metrics.size
        guard size.width > 0, size.height > 0 else { return .pager }
        // An iPad keeps the single-screen layout it ships with today.
        guard min(size.width, size.height) < Self.tabletMinShortSide else { return .pager }
        // Only split across the crease. Open like a book the fold is vertical
        // and the panels sit side by side, which is the pose the split is for.
        // Turned upright the panels are above and below each other, so a
        // left/right split would straddle the fold.
        return size.width > size.height ? .splitPane : .pager
    }

    /// Debug only: `-UITestPose tabletop` forces the propped-open layout.
    /// A simulator's hinge pose is set by hand in the Simulator app and
    /// cannot be driven from simctl, so without this the pose cannot be
    /// reached from a script at all.
    private static let forcedTabletop: Bool = {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "UITestPose") == "tabletop"
        #else
        return false
        #endif
    }()

    /// Propped open on a surface with the fold running across, so the half
    /// facing you is the top one. Only this pose: open flat, or held with the
    /// fold upright, and the usual layouts apply.
    private var isTabletopPose: Bool {
        if Self.forcedTabletop { return true }
        return posture.isTabletop
            && metrics.size.height > metrics.size.width      // panels above and below
            && min(metrics.size.width, metrics.size.height) < Self.tabletMinShortSide
    }

    /// The big inner screen, where the status corner sits above the content
    /// rather than beside it.
    private var onInnerDisplay: Bool { min(metrics.size.width, metrics.size.height) > 600 }

    /// Beside the graph the table is permanent, which is also what hides the
    /// buttons that would navigate to it.
    private var tableAlongside: Bool { layoutMode == .splitPane }
    private var tableIsReachable: Bool { showTable && !tableAlongside }

    /// Width the left pane needs so the divider lands on the crease.
    private var creaseLeftWidth: CGFloat {
        guard metrics.size.width > 0 else { return 0 }
        return max(0, metrics.size.width / 2 - splitOriginX)
    }

    /// How far a graph may spread into the strip the system reserves at the
    /// trailing side. Only the graph does: the buttons stay inside the safe
    /// area, because on the folded screen that strip is where the camera is,
    /// and a button sliding under the camera is worse than a narrow graph.
    private var graphInsetBonus: (leading: CGFloat, trailing: CGFloat) {
        (max(0, metrics.safeInsets.left), max(0, metrics.safeInsets.right))
    }

    /// Whether the place-name row can be lifted into the band the system keeps
    /// for the clock, which buys the graph that row's height.
    ///
    /// Only where that band has a clear stretch wide enough to hold a row. An
    /// ordinary phone reports a status bar the full width of the screen, so
    /// there is no clear stretch and nothing is lifted; the folded and
    /// unfolded screens here report a corner, and the rest of the band is
    /// empty.
    private var liftHeaderIntoStatusBand: Bool {
        let band = metrics.statusFrame
        guard band.height >= 30, band.width > 0, metrics.size.width > 0 else { return false }
        let free = metrics.statusAtTopTrailing
            ? band.minX
            : metrics.size.width - band.maxX
        return free >= 180
    }

    /// Keeps the lifted row off the clock itself.
    private var liftedHeaderPadding: (leading: CGFloat, trailing: CGFloat) {
        guard liftHeaderIntoStatusBand else { return (0, 0) }
        let band = metrics.statusFrame
        return metrics.statusAtTopTrailing
            ? (0, max(0, metrics.size.width - band.minX))
            : (max(0, band.maxX), 0)
    }

    /// How far the graphs may spread into the side strips the system reserves,
    /// when there is one screen rather than two. Split in two, the right pane
    /// already takes the trailing strip and this would double it.
    private var graphBleed: (leading: CGFloat, trailing: CGFloat) {
        layoutMode == .pager ? graphInsetBonus : (0, 0)
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
            // Lifted into the clock's band, this row has to keep off the clock
            // itself; left where it is, it spans the width as before.
            .padding(.leading, liftedHeaderPadding.leading)
            .padding(.trailing, liftedHeaderPadding.trailing)
            .background(liftHeaderIntoStatusBand ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))

            if !liftHeaderIntoStatusBand { Divider() }

            if layoutMode == .splitPane { splitPaneLayout } else { phoneContentPane }
        }
        // Start at the top of the screen rather than below the clock: the
        // place name goes up into the band beside it, and everything under it
        // comes up by that row's height.
        .ignoresSafeArea(edges: liftHeaderIntoStatusBand ? .top : [])
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
        // Propped on a table, the lower half lies flat facing the ceiling;
        // everything worth reading belongs in the half tilted toward you,
        // pinned to the top of the panel rather than floating in the middle.
        //
        // The button bar is inside this cap, not outside it: capping the
        // content alone would leave the bar at the foot of the whole panel,
        // which both puts the controls in the half you cannot see and pushes
        // the graph past the fold by the bar's own height.
        .frame(maxHeight: isTabletopPose ? metrics.size.height / 2 : nil, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // Zero-sized host for the hinge interaction, which is UIKit-only.
            HingeReader { angle, status, partlyOpen in
                posture.apply(angle: angle, status: status, partlyOpen: partlyOpen)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .task { posture.start() }
        // The whole panel, status corner and all — read from the window, since
        // a SwiftUI background reports what is left after the safe area and
        // ignoresSafeArea() does not change that.
        //
        // Full-size, not zero-size: a view with no dimensions never gets a
        // layout pass, so it reports the window it was born in and keeps
        // reporting it. Unfolding then leaves the split sized to half the
        // *outer* screen, a quarter of the way across the panel.
        .background {
            WindowMetricsReader { metrics = $0 }
                .allowsHitTesting(false)
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
            // The UI tests drive the indoor forecast, which this sheet would
            // sit in front of; FORECAST_PREVIEW is their switch.
            if show, ProcessInfo.processInfo.environment["FORECAST_PREVIEW"] == nil { showWhatsNew = true }
            PhoneWatchSync.shared.start()
            pushToWatch()
            if indoorTracking {
                IndoorSamplingCoordinator.shared.scheduleBackgroundSample()
                // Not awaited: this reads the station's archive from iCloud and
                // can take several seconds, during which the graph would have
                // nothing to draw. Nothing on screen waits for indoor data, and
                // the graph is what the person opened the app to see.
                Task { await IndoorSamplingCoordinator.shared.sampleIfDue() }
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
    /// The indoor forecast, with the same vertical swipe to get back.
    private var indoorForecastTab: some View {
        IndoorForecastView(series: weather.seriesFull,
                           location: selectedPlace?.clLocation ?? locationProvider.currentLocation,
                           places: places,
                           nowTick: nowTick,
                           onShowGraph: { withAnimation(.easeInOut(duration: 0.25)) { foldShowsIndoor = false } })
            // Swiping back out again. It has to yield to the sliders, which
            // carry a high-priority gesture of their own, or a drag meant for a
            // pointer would leave the screen instead of moving the event.
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.height) > 60,
                      abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.25)) { foldShowsIndoor = false }
            })
    }

    /// One screen at a time, swiped between: a phone, the outer screen of a
    /// folded device, or an open one held with the fold running across.
    @ViewBuilder
    private var phoneContentPane: some View {
        if useFoldTimeline {
            if showTable && foldShowsTable {
                forecastTableTab
            } else if foldShowsIndoor {
                indoorForecastTab
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

    /// Open like a book: the table on the half that folds away, the graph on
    /// the half that carries the outer screen.
    ///
    /// Even halves, because the halves are physical. Putting the graph on the
    /// panel that was already showing it means opening the device reads as the
    /// other half turning transparent, rather than as the layout rearranging
    /// itself under your hands.
    private var splitPaneLayout: some View {
        HStack(spacing: 0) {
            forecastTableTab
                // Air at the screen edge and at the fold, where the outer
                // columns were running into both. The pane's width is fixed to
                // the crease, so insetting the table moves nothing else.
                .padding(.leading, 8)
                .padding(.trailing, 10)
                // Fixed, not capped: a cap only stops the pane growing past
                // the crease, and the stack hands it less than that anyway,
                // which leaves the graph starting before the fold even when the
                // crease itself was worked out correctly.
                .frame(width: creaseLeftWidth > 0 ? creaseLeftWidth : nil)
            Divider()
            phoneContentPane
                .frame(maxWidth: .infinity)
                // Out to the panel edge, under the clock. This pane's left edge
                // is pinned to the crease, so the width is gained on the right
                // rather than shifting the pane sideways.
                .padding(.trailing, -graphInsetBonus.trailing)
        }
        // The crease is the middle of the panel, and this reports where the
        // split begins inside it. Reconstructing the panel width from safe-area
        // insets was guesswork and landed the divider left of the fold.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minX
        } action: { splitOriginX = $0 }
    }

    private func headerBar(_ title: String,
                           left: (String, () -> Void)? = nil,
                           nextToLeft: (String, () -> Void)? = nil,
                           right: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity)
                    // Symmetric, so the title stays centred whichever side is fuller.
                    .padding(.horizontal, nextToLeft == nil ? 78 : 130)
                HStack {
                    HStack(spacing: 16) {
                        if let left { Button(left.0) { left.1() } }
                        if let nextToLeft { Button(nextToLeft.0) { nextToLeft.1() } }
                    }
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
                      right: tableIsReachable ? ("table", { goToTable() }) : nil)
            HereTodayView(
                allSeries: weather.isRefreshing ? [] : panSeries,
                windowStart: windowStart,
                windowSpan: ForecastScreen.today.span,
                current: weather.isRefreshing ? nil : weather.current,
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) },
                // Propped open, the visible half is wider than it is tall
                // whatever the size class reports for the panel as a whole.
                statusCorner: metrics.statusFrame,
                forceLandscapeLayout: isTabletopPose
            )
            // Out to the panel edges, under the clock and past the camera.
            // Only the graph goes there: the header and the button bar stay
            // inside the safe area, where nothing is carved out of them.
            .padding(.leading, -graphBleed.leading)
            .padding(.trailing, -graphBleed.trailing)
        }
    }

    private var tenDayTab: some View {
        VStack(spacing: 0) {
            headerBar(windowLabel(.tenDay),
                      left: ("24h", { goToScreen(.today) }),
                      right: tableIsReachable ? ("table", { goToTable() }) : nil)
            TenDayView(
                allSeries: weather.isRefreshing ? [] : panSeries,
                windowStart: windowStart,
                windowSpan: ForecastScreen.tenDay.span,
                progress: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) },
                // Propped open, the visible half is wider than it is tall
                // whatever the size class reports for the panel as a whole.
                statusCorner: metrics.statusFrame,
                forceLandscapeLayout: isTabletopPose
            )
            // Out to the panel edges, under the clock and past the camera.
            // Only the graph goes there: the header and the button bar stay
            // inside the safe area, where nothing is carved out of them.
            .padding(.leading, -graphBleed.leading)
            .padding(.trailing, -graphBleed.trailing)
        }
    }

    /// The table's header doubles as navigation.
    private var tableHeader: some View {
        // Beside the graph the table is simply there, in its own half: nothing
        // navigates to it and nothing leaves it, so the buttons that would are
        // left off and the title stands alone.
        if tableAlongside {
            headerBar(ForecastScreen.table.title)
        } else if useFoldTimeline {
            headerBar(ForecastScreen.table.title,
                      left: ("graph", { leaveTable(to: nil) }))
        } else {
            headerBar(ForecastScreen.table.title,
                      left: ("24h", { leaveTable(to: .today) }),
                      right: ("10-day", { leaveTable(to: .tenDay) }))
        }
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

    @ViewBuilder
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
                      nextToLeft: ("events", { showEvents = true }),
                      right: tableIsReachable ? ("table", { goToTable() }) : nil)
            FoldTimelineView(
                series: weather.isRefreshing ? [] : panSeries,
                startOffset: $startOffset,
                current: weather.isRefreshing ? nil : weather.current,
                progressLoad: weather.loadProgress,
                nowTick: nowTick,
                errorMessage: weather.lastErrorMessage,
                attribution: weather.attribution,
                onRefresh: { await loadWeather(preserveData: true, useFreshLocation: true) },
                onVerticalSwipe: { withAnimation(.easeInOut(duration: 0.25)) { foldShowsIndoor = true } }
            )
        }
        .sheet(isPresented: $showModelReport) {
            // The place on screen, so the model screen can reuse its weather
            // when it is the monitored home rather than fetching it again.
            ModelReportView(series: weather.seriesFull,
                            location: selectedPlace?.clLocation ?? locationProvider.currentLocation,
                            places: places)
        }
        .sheet(isPresented: $showEvents) {
            EventsView()
        }
    }
}

#Preview {
    ContentView()
}

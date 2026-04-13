//
//  ContentView.swift
//  weather_wetbulb
//
//  Created by Rob Boer on 3/23/26.
//

import SwiftUI
import Charts
import WeatherKit
import CoreLocation
import Combine

struct ForecastPoint: Identifiable {
    let id = UUID()
    let date: Date
    let temperatureF: Double
    let wetBulbF: Double
    let dewPointF: Double
    let precipProbability: Double // 0...1
    let windSpeedMPH: Double

    // Additional fields for table compatibility; computed or defaulted where not provided
    var apparentTemperatureF: Double { temperatureF } // placeholder if not available
    var precipAmountMM: Double { 0.0 } // placeholder if not available
}

struct ForecastSeries {
    let points: [ForecastPoint]
}

struct ContentView: View {
    @State private var selectedPlace: String = "Irvine"
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var weather = WeatherService()
    @State private var navigateToTable: Bool = false
    
    @State private var nowTick: Date = .now
    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ZStack {
                TabView {
                    HereTodayView(
                        title: weather.placeDescription.isEmpty ? selectedPlace : weather.placeDescription,
                        series24h: weather.series24h,
                        progress: weather.loadProgress,
                        nowTick: nowTick,
                        errorMessage: weather.lastErrorMessage
                    )
                        .tabItem {
                            Label("Today", systemImage: "sun.max")
                        }

                    TenDayView(series10d: weather.series10d)
                        .tabItem {
                            Label("10-Day", systemImage: "calendar")
                        }

                    Text("Another Screen")
                        .tabItem {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                }
                .tabViewStyle(PageTabViewStyle())
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Button("New York") { selectedPlace = "New York" }
                            Button("Soest") { selectedPlace = "Soest" }
                            Button("Yucca Valley") { selectedPlace = "Yucca Valley" }
                            Button("Irvine") { selectedPlace = "Irvine" }
                        } label: {
                            Label("places", systemImage: "mappin.and.ellipse")
                        }
                    }

                    ToolbarItem(placement: .bottomBar) {
                        NavigationLink {
                            TenDayView(series10d: weather.series10d)
                        } label: {
                            Text("10day")
                        }
                    }

                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            if let loc = locationProvider.currentLocation {
                                Task { await weather.loadFor(location: loc) }
                            } else {
                                locationProvider.requestLocation()
                            }
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                    }
                }

                // Hidden NavigationLink to trigger programmatic navigation on swipe
                NavigationLink("", isActive: $navigateToTable) {
                    ForecastTableView(weatherService: weather)
                }
                .hidden()
            }
            .gesture(
                DragGesture().onEnded { value in
                    if value.translation.width > 80 && abs(value.translation.height) < 40 {
                        navigateToTable = true
                    }
                }
            )
        }
        .onReceive(locationProvider.$currentLocation.compactMap { $0 }) { loc in
            Task { await weather.loadFor(location: loc) }
        }
        .task {
            if let loc = locationProvider.currentLocation {
                await weather.loadFor(location: loc)
            } else {
                locationProvider.requestLocation()
            }
        }
        .onReceive(progressTimer) { tick in
            nowTick = tick
        }
    }
}

struct HereTodayView: View {
    var title: String = "Today"
    var series24h: ForecastSeries
    var progress: LoadProgress = LoadProgress()
    var nowTick: Date = .now
    var errorMessage: String? = nil

    private var dateDomain: ClosedRange<Date>? {
        guard let first = series24h.points.first?.date, let last = series24h.points.last?.date else { return nil }
        return first...last
    }
//ForecastTableView
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title: street and place placeholder using selected title
//                Text(title)
//                    .font(.title)
//                    .fontWeight(.semibold)
//                    .frame(maxWidth: .infinity, alignment: .leading)

                if series24h.points.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading forecast…")
                            .foregroundStyle(.secondary)
                            .font(.callout)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(LoadStep.allCases) { step in
                                HStack(spacing: 8) {
                                    // Icon depending on state
                                    switch progress.steps[step] ?? .pending {
                                    case .success:
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    case .inProgress(let startedAt):
                                        if nowTick.timeIntervalSince(startedAt) > 2 {
                                            ProgressView().frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: "hourglass").foregroundStyle(.secondary)
                                        }
                                    case .failure:
                                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                    case .pending:
                                        Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                                    }
                                    Text(step.rawValue)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)

                                    if case .inProgress(let startedAt) = (progress.steps[step] ?? .pending), nowTick.timeIntervalSince(startedAt) > 2 {
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
                } else {
                    // Removed inline domain closure usage, using dateDomain property instead
                    
                    // Top chart: temperatures (blue actual, green wet bulb, red dew point)
                    Chart(series24h.points) { p in
                        PointMark(
                            x: .value("Time", p.date),
                            y: .value("Temp (°F)", p.temperatureF)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.linear)

                        PointMark(
                            x: .value("Time", p.date),
                            y: .value("Wet Bulb (°F)", p.wetBulbF)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.linear)

                        PointMark(
                            x: .value("Time", p.date),
                            y: .value("Dew Point (°F)", p.dewPointF)
                        )
                        .foregroundStyle(.red)
                        .interpolationMethod(.linear)
                    }
                    .chartLegend(position: .top)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .ifLet(dateDomain) { view, domain in
                        view.chartXScale(domain: domain)
                    }
                    .frame(height: 300)

                    // Bottom chart: precipitation probability (blue) and wind speed (red)
                    Chart {
                        ForEach(series24h.points) { p in
                            let precip = p.precipProbability
                            let time = p.date
                            let wind = p.windSpeedMPH

                            AreaMark(
                                x: .value("Time", time),
                                y: .value("Precip Prob", precip * 100)
                            )
                            .foregroundStyle(Color.blue.opacity(0.3).gradient)
                            .interpolationMethod(.linear)

                            LineMark(
                                x: .value("Time", time),
                                y: .value("Wind (mph)", wind)
                            )
                            .foregroundStyle(.red)
                            .interpolationMethod(.linear)
                            .symbol(Circle())
                            .symbolSize(0)
                        }
                    }
                    .ifLet(dateDomain) { view, domain in
                        view.chartXScale(domain: domain)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
//                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel() // default for left axis
                        }
                    }
                    .frame(height: 150)
                    
//                    Text("Points: \(series.points.count)  First: \(series.points.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "-")")
//                        .font(.footnote)
//                        .foregroundStyle(.secondary)
//                    Text("first-last temp: \(String(describing: series.points.first?.temperatureF)) - \(String(describing: series.points.first?.temperatureF))")
//                        .font(.footnote)
//                        .foregroundStyle(.secondary)
//                    ForEach(series.points) {p in
//                        Text("date - temp: \(String(describing: p.date)) - \(String(describing: p.temperatureF))")
//                            .font(.footnote)
//                            .foregroundStyle(.secondary)
//                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
    }
}

struct TenDayView: View {
    var series10d: ForecastSeries
    
    var body: some View {
        VStack {
            Text("10-Day Forecast")
                .font(.largeTitle)
                .padding()
            Spacer()
            // Top chart: temperatures (blue actual, green wet bulb, red dew point)
            Chart(series10d.points) { p in
                PointMark(
                    x: .value("Time", p.date),
                    y: .value("Temp (°F)", p.temperatureF)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.linear)

                PointMark(
                    x: .value("Time", p.date),
                    y: .value("Wet Bulb (°F)", p.wetBulbF)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.linear)

                PointMark(
                    x: .value("Time", p.date),
                    y: .value("Dew Point (°F)", p.dewPointF)
                )
                .foregroundStyle(.red)
                .interpolationMethod(.linear)
            }
            .chartLegend(position: .top)
            .chartYScale(domain: .automatic(includesZero: false))
//            .ifLet(dateDomain) { view, domain in
//                view.chartXScale(domain: domain)
//            }
            .frame(height: 300)

            // Bottom chart: precipitation probability (blue) and wind speed (red)
            Chart {
                ForEach(series10d.points) { p in
                    let precip = p.precipProbability
                    let time = p.date
                    let wind = p.windSpeedMPH

                    AreaMark(
                        x: .value("Time", time),
                        y: .value("Precip Prob", precip * 100)
                    )
                    .foregroundStyle(Color.blue.opacity(0.3).gradient)
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("Time", time),
                        y: .value("Wind (mph)", wind)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.linear)
                    .symbol(Circle())
                    .symbolSize(0)
                }
            }
//            .ifLet(dateDomain) { view, domain in
//                view.chartXScale(domain: domain)
//            }
            .chartYScale(domain: .automatic(includesZero: false))
//                    .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel() // default for left axis
                }
            }
            .frame(height: 150)

        }
        .navigationTitle("10-Day")
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let v = value {
            transform(self, v)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}

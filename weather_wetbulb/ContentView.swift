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
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var weather = WeatherService()
    @StateObject private var places = PlacesViewModel()
    @State private var selectedPlace: Place? = nil

    @State private var nowTick: Date = .now
    private let progressTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var showEditPlaces: Bool = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                TabView {
                    HereTodayView(
                        title: weather.placeDescription.isEmpty ? (selectedPlace?.name ?? "") : weather.placeDescription,
                        series24h: weather.series24h,
                        progress: weather.loadProgress,
                        nowTick: nowTick,
                        errorMessage: weather.lastErrorMessage,
                        onRefresh: {
                            if let place = selectedPlace {
                                let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                                await weather.loadFor(location: loc)
                            } else if let loc = locationProvider.currentLocation {
                                await weather.loadFor(location: loc)
                            } else {
                                locationProvider.requestLocation()
                            }
                        }
                    )
                        .tabItem {
                            Label("Today", systemImage: "sun.max")
                        }

                    TenDayView(title: weather.placeDescription, series10d: weather.series10d)
                        .tabItem {
                            Label("10-Day", systemImage: "calendar")
                        }

                    ForecastTableView(weatherService: weather)
                        .tabItem {
                            Label("Table", systemImage: "table")
                        }
//                    Text("Another Screen")
//                        .tabItem {
//                            Label("More", systemImage: "ellipsis.circle")
//                        }
                }
                .tabViewStyle(PageTabViewStyle())
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Button("Here") {
                                if let loc = locationProvider.currentLocation {
                                    Task { await weather.loadFor(location: loc) }
                                } else {
                                    locationProvider.requestLocation()
                                }
                            }
                            ForEach(places.places) { place in
                                Button(place.name) {
                                    selectedPlace = place
                                    let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                                    Task { await weather.loadFor(location: loc) }
                                }
                            }
                            Divider()
                            Button("Edit places") { showEditPlaces = true }
                        } label: {
                            Label("Other place", systemImage: "mappin.and.ellipse")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showEditPlaces) {
            NavigationStack { EditPlacesView(viewModel: places) }
        }
        .onReceive(locationProvider.$currentLocation.compactMap { $0 }) { loc in
            if selectedPlace == nil { Task { await weather.loadFor(location: loc) } }
        }
        .task {
            if let place = selectedPlace {
                let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                await weather.loadFor(location: loc)
            } else if let loc = locationProvider.currentLocation {
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
    var onRefresh: (() async -> Void)? = nil

    private var dateDomain: ClosedRange<Date>? {
        guard let first = series24h.points.first?.date, let last = series24h.points.last?.date else { return nil }
        return first...last
    }

    private func hourLabel(for date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH"
        return df.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !title.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("24 hour forecast")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

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
                        LineMark(
                            x: .value("Time", p.date),
                            y: .value("Temp (°F)", p.temperatureF),
                            series: .value("temperature", "A")
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Time", p.date),
                            y: .value("Wet Bulb (°F)", p.wetBulbF),
                            series: .value("wet_bulb", "B")
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Time", p.date),
                            y: .value("Dew Point (°F)", p.dewPointF),
                            series: .value("dew_point", "C")
                        )
                        .foregroundStyle(.red)
                        .interpolationMethod(.linear)
                    }
                    .chartLegend(position: .top)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel().font(.body)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(centered: true) {
                                Text(value.as(Date.self).map { hourLabel(for: $0) } ?? "")
                                    .font(.body)
                            }
                        }
                    }
                    .ifLet(dateDomain) { view, domain in
                        view.chartXScale(domain: domain)
                    }
                    .frame(height: 420)

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
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel().font(.body)
                        }
                    }
                    .frame(height: 220)
                    
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
        .refreshable {
            await onRefresh?()
        }
        .navigationTitle(title)
    }
}

struct TenDayView: View {
    var title: String = ""
    var series10d: ForecastSeries
    
    private var startMidnight: Date? {
        guard let first = series10d.points.first?.date else { return nil }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: first)
        if first > midnight { return cal.date(byAdding: .day, value: 1, to: midnight) }
        return midnight
    }

    private func dayLabel(for date: Date) -> String {
        guard let start = startMidnight, date >= start,
              Calendar.current.component(.hour, from: date) == 0 else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        let key = fmt.string(from: date)
        let map = ["Mon":"Mo","Tue":"Tu","Wed":"We","Thu":"Th","Fri":"Fr","Sat":"Sa","Sun":"Su"]
        return map[key] ?? String(key.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("10 day forecast")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Chart(series10d.points) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Temp (°F)", p.temperatureF),
                    series: .value("temperature", "A")
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Wet Bulb (°F)", p.wetBulbF),
                    series: .value("wet_bulb", "B")
                )
                .foregroundStyle(.green)
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Dew Point (°F)", p.dewPointF),
                    series: .value("dew_point", "C")
                )
                .foregroundStyle(.red)
                .interpolationMethod(.linear)
            }
            .chartLegend(position: .top)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel().font(.body)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        Text(value.as(Date.self).map { dayLabel(for: $0) } ?? "")
                            .font(.body)
                    }
                }
            }
            .frame(height: 420)

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
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel().font(.body)
                }
            }
            .frame(height: 220)
        }
        .padding(.horizontal, 24) // Slightly narrower than Today view
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


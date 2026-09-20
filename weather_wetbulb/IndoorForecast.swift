//
//  IndoorForecast.swift
//  weather_wetbulb
//
//  Running the indoor model forward: what the house will do over the next
//  twelve hours, under a scenario the person lays out.
//
//  Two things make this different from the fitting the model screen does.
//
//  The outdoor conditions come entirely from WeatherKit, because the station
//  cannot report the future. Where the fit preferred the station for a
//  variable, the forecast still has to use WeatherKit, and the screen says so.
//
//  The house's slow parts are carried forward as state. They start where the
//  readings left them and then follow the forecast rather than the house, so a
//  scenario that cools the room also cools its mass, and the mass pushes back
//  for hours afterwards — which is the whole point of having it.
//

import Foundation
import CoreLocation

nonisolated enum IndoorForecast {

    /// How long the forecast runs, and how finely it is stepped.
    static let horizon: TimeInterval = 12 * 3600
    static let step: TimeInterval = 15 * 60

    // MARK: - Scenarios

    /// One change of equipment inside a scenario: what starts running, when.
    struct Change: Equatable, Identifiable {
        var id = UUID()
        var date: Date
        var state: HVACState
        /// Thermostat setting, for the states that have one.
        var setpointC: Double?
    }

    /// A line on the graph: the house left alone, or with equipment started at
    /// times the person chooses.
    struct Scenario: Identifiable, Equatable {
        var id: Int
        var name: String
        /// Up to two changes. Nil means the scenario has no change in that
        /// slot — for the second, that its pointer is parked at the right edge.
        var first: Change?
        var second: Change?

        var changes: [Change] {
            [first, second].compactMap { $0 }.sorted { $0.date < $1.date }
        }

        /// What is running at `date`: nothing, until a change says otherwise.
        func state(at date: Date) -> (state: HVACState, setpointC: Double?) {
            var current: (HVACState, Double?) = (.off, nil)
            for change in changes where change.date <= date {
                current = (change.state, change.setpointC)
            }
            return current
        }
    }

    /// Where the house is when the forecast starts.
    struct Start: Equatable {
        var date: Date
        var temperatureC: Double
        var dewPointC: Double
        var lags: ThermalLags
        /// Station pressure, for the wet bulb. The station measures it; indoors
        /// and outdoors differ by nothing that matters at this altitude.
        var pressureHPa: Double?
    }

    /// One forecast reading.
    struct Point: Identifiable, Equatable {
        let date: Date
        let temperatureC: Double
        let dewPointC: Double
        let wetBulbC: Double
        var id: Date { date }

        func temperature(fahrenheit: Bool) -> Double { fahrenheit ? temperatureC * 9 / 5 + 32 : temperatureC }
        func dewPoint(fahrenheit: Bool) -> Double { fahrenheit ? dewPointC * 9 / 5 + 32 : dewPointC }
        func wetBulb(fahrenheit: Bool) -> Double { fahrenheit ? wetBulbC * 9 / 5 + 32 : wetBulbC }
    }

    // MARK: - Running the model forward

    /// Forecast one scenario.
    ///
    /// Returns nil when the model cannot be stepped — no outdoor forecast to
    /// run on, most likely — rather than drawing a line that means nothing.
    static func run(model: IndoorModel,
                    from start: Start,
                    scenario: Scenario,
                    weather: [ForecastPoint],
                    location: CLLocation?,
                    horizon: TimeInterval = horizon,
                    step: TimeInterval = step) -> [Point]? {
        let series = weather.sorted { $0.date < $1.date }
        guard let last = series.last, last.date > start.date else { return nil }

        var temperature = start.temperatureC
        var dewPoint = start.dewPointC
        var lags = start.lags
        var points = [Point(date: start.date, temperatureC: temperature, dewPointC: dewPoint,
                            wetBulbC: wetBulb(temperature, dewPoint, start.pressureHPa))]

        var moment = start.date
        let end = min(start.date.addingTimeInterval(horizon), last.date)
        while moment < end {
            let length = min(step, end.timeIntervalSince(moment))
            guard let outdoor = conditions(at: moment, in: series) else { break }
            let equipment = scenario.state(at: moment)
            let probe = IndoorObservation(
                date: moment, dt: length,
                indoorTempC: temperature, indoorDewPointC: dewPoint,
                nextIndoorTempC: temperature, nextIndoorDewPointC: dewPoint,
                // Both sides are WeatherKit: the station cannot report the
                // future, so whichever source the fit preferred, the forecast
                // has only this one.
                weatherKit: outdoor.values, station: outdoor.values,
                solar: solar(at: moment, point: outdoor.point, location: location),
                solarVertical: vertical(at: moment, point: outdoor.point, location: location),
                solarAzimuthDeg: location.map {
                    SolarGeometry.position(date: moment,
                                           latitude: $0.coordinate.latitude,
                                           longitude: $0.coordinate.longitude).azimuthDegrees
                } ?? nil,
                daylight: IndoorObservationBuilder.daylight(at: moment, weatherKit: outdoor.point,
                                                            location: location),
                setpointC: equipment.setpointC,
                lags: lags,
                hvac: equipment.state)
            guard let next = model.step(from: probe, dt: length) else { break }
            temperature = next.temperatureC
            dewPoint = next.dewPointC
            lags = next.lags
            moment = moment.addingTimeInterval(length)
            points.append(Point(date: moment, temperatureC: temperature, dewPointC: dewPoint,
                                wetBulbC: wetBulb(temperature, dewPoint,
                                                  outdoor.values.stationPressureHPa ?? start.pressureHPa)))
        }
        return points.count > 1 ? points : nil
    }

    // MARK: - Outdoor conditions, interpolated

    static func conditions(at date: Date,
                           in series: [ForecastPoint]) -> (values: OutdoorValues, point: ForecastPoint?)? {
        guard let first = series.first, let last = series.last else { return nil }
        var low = first, high = last, fraction = 0.0
        if date <= first.date { low = first; high = first }
        else if date >= last.date { low = last; high = last }
        else {
            var a = 0, b = series.count - 1
            while b - a > 1 {
                let middle = (a + b) / 2
                if series[middle].date <= date { a = middle } else { b = middle }
            }
            low = series[a]; high = series[b]
            let span = high.date.timeIntervalSince(low.date)
            fraction = span > 0 ? date.timeIntervalSince(low.date) / span : 0
        }
        func between(_ x: Double, _ y: Double) -> Double { x + (y - x) * fraction }
        let values = OutdoorValues(
            temperatureC: between(low.temperatureC, high.temperatureC),
            humidity: between(low.humidity, high.humidity) * 100,
            windSpeedMS: between(low.windSpeedKPH, high.windSpeedKPH) / 3.6,
            windGustMS: between(low.windGustKPH, high.windGustKPH) / 3.6,
            windDirectionDeg: WindDirectionEncoding.lerpAngle(low.windDirectionDegrees,
                                                              high.windDirectionDegrees, fraction),
            rainfallMM: between(low.precipitationMM, high.precipitationMM) * step / 3600,
            stationPressureHPa: between(low.stationPressurePa, high.stationPressurePa) / 100)
        return (values, fraction < 0.5 ? low : high)
    }

    /// Sun on the roof, the way the observation builder derives it when the
    /// station's light sensor has nothing to say — which is always, here.
    static func solar(at date: Date, point: ForecastPoint?, location: CLLocation?) -> Double {
        guard let point, point.isDaylight else { return 0 }
        let clear = min(max(1 - point.cloudCover, 0), 1)
        guard let location else { return clear }
        return clear * SolarGeometry.clearSkyFactor(date: date,
                                                    latitude: location.coordinate.latitude,
                                                    longitude: location.coordinate.longitude)
    }

    static func vertical(at date: Date, point: ForecastPoint?, location: CLLocation?) -> Double {
        guard let location else { return 0 }
        let sun = SolarGeometry.position(date: date,
                                         latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude)
        return sun.vertical * (point.map { min(max(1 - $0.cloudCover, 0), 1) } ?? 1)
    }

    /// Indoor wet bulb from the pair the model forecasts.
    static func wetBulb(_ temperatureC: Double, _ dewPointC: Double, _ pressureHPa: Double?) -> Double {
        let humidity = relativeHumidity(temperatureC: temperatureC, dewPointC: dewPointC)
        return IndoorPsychrometrics.wetBulbC(temperatureC: temperatureC,
                                             relativeHumidity: humidity,
                                             pressureHPa: pressureHPa) ?? temperatureC
    }

    /// Relative humidity implied by a temperature and dew point, in percent.
    static func relativeHumidity(temperatureC: Double, dewPointC: Double) -> Double {
        let a = 17.62, b = 243.12
        let ratio = exp(a * dewPointC / (b + dewPointC) - a * temperatureC / (b + temperatureC))
        return min(max(ratio * 100, 1), 100)
    }

    // MARK: - Where the house is now

    /// The state a forecast starts from: the most recent reading, with the lag
    /// state the observations carry, advanced to now.
    static func start(observations: [IndoorObservation],
                      readings: [IndoorReading],
                      now: Date = .now) -> Start? {
        let rows = readings.filter(\.hasIndoorTarget).sorted { $0.date < $1.date }
        guard let latest = rows.last,
              let temperature = latest.indoorTempC, let humidity = latest.indoorHumidity,
              let dewPoint = IndoorPsychrometrics.dewPointC(temperatureC: temperature,
                                                            relativeHumidity: humidity)
        else { return nil }
        // The lags belong to the last observation built; carry them across the
        // gap between that reading and now, driven by what the house was doing.
        var lags = observations.last?.lags ?? ThermalLags.starting(
            indoorTempC: temperature, outdoorTempC: latest.outdoorTempC, indoorDewPointC: dewPoint)
        if let anchor = observations.last?.date, now > anchor {
            lags = lags.advanced(indoorTempC: temperature, outdoorTempC: latest.outdoorTempC,
                                 indoorDewPointC: dewPoint, dt: now.timeIntervalSince(anchor))
        }
        return Start(date: now, temperatureC: temperature, dewPointC: dewPoint, lags: lags,
                     pressureHPa: latest.stationPressureHPa)
    }
}

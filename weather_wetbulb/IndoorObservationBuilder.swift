//
//  IndoorObservationBuilder.swift
//  weather_wetbulb
//
//  Turns stored station readings into the observation rows the model fits on,
//  by pairing each reading with the next one and attaching both candidate sets
//  of outdoor conditions.
//
//  The station series has holes. The Mac mini that talks to the console is not
//  always on — it was off for about two hours while it moved house — so
//  consecutive stored rows are sometimes hours apart. That matters more than it
//  looks: the model learns from the RATE of indoor change, and a rate computed
//  across an unobserved gap is not a slow rate, it is an average over hours of
//  unknown behaviour. A handful of those rows will drag the fitted coefficients
//  badly. So pairs that straddle a gap are dropped rather than stretched.
//
//  Intervals containing a known HVAC transition are dropped too: half of such
//  an interval had the cooler on and half did not, so neither label is true and
//  the row would teach the model that cooling is weaker than it is.
//

import Foundation

enum IndoorObservationBuilder {

    /// Longest interval that still counts as consecutive.
    ///
    /// The station reports every ~18 minutes, so twice that leaves room for one
    /// dropped report without letting a genuine outage through.
    static let maxPairInterval: TimeInterval = 40 * 60

    /// Shortest interval worth using. Two readings a minute apart carry almost
    /// no change but full sensor quantisation noise, so the implied rate is
    /// mostly noise amplified by the small divisor.
    static let minPairInterval: TimeInterval = 5 * 60

    /// Full sun in kLux, used to normalise the station's light sensor to 0…1 so
    /// one solar coefficient fits whichever source supplied it.
    static let fullSunKLux: Double = 100

    // MARK: - Building

    /// Build observations from stored readings and a WeatherKit series.
    ///
    /// - Parameters:
    ///   - readings: station rows, any order; sorted internally.
    ///   - weather: WeatherKit points covering the same span, hourly.
    ///   - coolerEvents / hvacEvents: known state changes, used both to label
    ///     each interval and to drop intervals a change falls inside.
    static func build(readings: [IndoorReading],
                      weather: [ForecastPoint],
                      coolerEvents: [CoolerEvent] = [],
                      hvacEvents: [HVACEvent] = []) -> [IndoorObservation] {

        let rows = readings
            .filter(\.hasIndoorTarget)
            .sorted { $0.date < $1.date }
        guard rows.count >= 2 else { return [] }

        let series = weather.sorted { $0.date < $1.date }
        let timeline = HVACTimeline(coolerEvents: coolerEvents, hvacEvents: hvacEvents)

        var out: [IndoorObservation] = []
        for (a, b) in zip(rows, rows.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard dt >= minPairInterval, dt <= maxPairInterval else { continue }

            guard let tA = a.indoorTempC, let hA = a.indoorHumidity,
                  let dA = IndoorPsychrometrics.dewPointC(temperatureC: tA, relativeHumidity: hA),
                  let tB = b.indoorTempC, let hB = b.indoorHumidity,
                  let dB = IndoorPsychrometrics.dewPointC(temperatureC: tB, relativeHumidity: hB)
            else { continue }

            // A state change inside the interval makes both labels wrong.
            guard !timeline.hasTransition(between: a.date, and: b.date) else { continue }

            var wk = weatherKitValues(at: a.date, in: series)
            // WeatherKit reports an hourly amount, so scale it to this interval.
            if let hourly = wk.values.rainfallMM {
                wk.values.rainfallMM = hourly * dt / 3600
            }
            var stationOut = stationValues(a)
            // The station's counter is cumulative, so the rain that fell during
            // this interval is the increase across it. Clamped at zero because
            // the console resets the counter, which would otherwise show as a
            // large negative downpour.
            stationOut.rainfallMM = rainIncrement(from: a, to: b)

            out.append(IndoorObservation(
                date: a.date,
                dt: dt,
                indoorTempC: tA,
                indoorDewPointC: dA,
                nextIndoorTempC: tB,
                nextIndoorDewPointC: dB,
                weatherKit: wk.values,
                station: stationOut,
                solar: solar(station: a, weatherKit: wk.point),
                hvac: timeline.state(at: a.date)))
        }
        return out
    }

    /// Rain that fell between two readings, from the cumulative counter.
    static func rainIncrement(from a: IndoorReading, to b: IndoorReading) -> Double? {
        guard let start = a.rainfallMM, let end = b.rainfallMM else { return nil }
        return max(0, end - start)
    }

    // MARK: - Sources

    static func stationValues(_ r: IndoorReading) -> OutdoorValues {
        OutdoorValues(temperatureC: r.outdoorTempC,
                      humidity: r.outdoorHumidity,
                      windSpeedMS: r.windSpeedMS,
                      windGustMS: r.windGustMS,
                      windDirectionDeg: r.windDirectionDeg,
                      rainfallMM: r.rainfallMM,
                      stationPressureHPa: r.stationPressureHPa)
    }

    /// WeatherKit conditions at `date`, interpolated between the bracketing
    /// hourly points.
    static func weatherKitValues(at date: Date,
                                 in series: [ForecastPoint]) -> (values: OutdoorValues, point: ForecastPoint?) {
        guard let (before, after, fraction) = bracket(date, in: series) else {
            return (OutdoorValues(), nil)
        }
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }

        let values = OutdoorValues(
            temperatureC: lerp(before.temperatureC, after.temperatureC),
            // ForecastPoint humidity is 0…1; the station publishes percent, and
            // the model must not see the same quantity on two scales.
            humidity: lerp(before.humidity, after.humidity) * 100,
            windSpeedMS: lerp(before.windSpeedKPH, after.windSpeedKPH) / 3.6,
            windGustMS: lerp(before.windGustKPH, after.windGustKPH) / 3.6,
            windDirectionDeg: lerpAngle(before.windDirectionDegrees,
                                        after.windDirectionDegrees, fraction),
            rainfallMM: lerp(before.precipitationMM, after.precipitationMM),
            // Already reduced to the site's actual pressure, so it means the
            // same thing as the station's reading.
            stationPressureHPa: lerp(before.stationPressurePa, after.stationPressurePa) / 100)
        return (values, fraction < 0.5 ? before : after)
    }

    /// Interpolate a compass bearing.
    ///
    /// Bearings wrap, so plain interpolation is wrong at the seam: halfway
    /// between 350 and 10 is north, but averaging the numbers gives 180 —
    /// exactly the opposite direction. Interpolating the unit vectors instead
    /// crosses the seam correctly.
    static func lerpAngle(_ a: Double?, _ b: Double?, _ fraction: Double) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        let ra = a * .pi / 180, rb = b * .pi / 180
        let x = cos(ra) + (cos(rb) - cos(ra)) * fraction
        let y = sin(ra) + (sin(rb) - sin(ra)) * fraction
        // Both vectors cancelling means the two bearings are opposite and the
        // midpoint is genuinely undefined; keep the earlier one rather than
        // inventing a direction from rounding noise.
        guard x * x + y * y > 1e-12 else { return a }
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The two points surrounding `date` plus how far between them it sits.
    /// Returns the single nearest point (fraction 0) when `date` lies outside
    /// the series, so an observation at the edge still gets values.
    private static func bracket(_ date: Date,
                                in series: [ForecastPoint]) -> (ForecastPoint, ForecastPoint, Double)? {
        guard let first = series.first, let last = series.last else { return nil }
        if date <= first.date { return (first, first, 0) }
        if date >= last.date { return (last, last, 0) }

        var low = 0, high = series.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if series[mid].date <= date { low = mid } else { high = mid }
        }
        let a = series[low], b = series[high]
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return (a, a, 0) }
        let fraction = date.timeIntervalSince(a.date) / span
        return (a, b, min(max(fraction, 0), 1))
    }

    /// Solar gain proxy on a 0…1 scale.
    ///
    /// The station's light sensor is preferred, because it measures the light
    /// actually arriving at this house — reduced by nearby trees, buildings or
    /// terrain that a forecast averaged over a wide area cannot know about.
    /// WeatherKit cloud cover is the fallback, gated by daylight so a clear
    /// night reads as zero rather than as full sun.
    static func solar(station: IndoorReading, weatherKit: ForecastPoint?) -> Double {
        // Only trust a NON-ZERO station reading. The Vevor's light channel
        // reports a constant 0 — the same dead channel as its UV index — and a
        // present-but-zero value would otherwise win over the fallback and
        // silently delete the solar term. A working sensor reading a true zero
        // loses nothing: that means darkness, and the fallback returns 0 too,
        // since it is gated by daylight.
        if let klux = station.lightKLux, klux > 0 {
            return min(max(klux / fullSunKLux, 0), 1)
        }
        guard let p = weatherKit, p.isDaylight else { return 0 }
        return min(max(1 - p.cloudCover, 0), 1)
    }
}

// MARK: - HVAC timeline

/// Resolves what the heating/cooling equipment was doing at a moment, from the
/// logged events.
///
/// When nothing has ever been logged every interval is treated as `.off`. That
/// is an assumption, not knowledge: an unlabelled hour with the AC running will
/// be attributed to the passive terms and will flatten them slightly. It is
/// still the right default, because the alternative — discarding every
/// unlabelled row — would leave nothing to fit until the user has annotated
/// weeks of history.
struct HVACTimeline {
    private let changes: [(date: Date, state: HVACState)]

    init(coolerEvents: [CoolerEvent], hvacEvents: [HVACEvent]) {
        var all: [(Date, HVACState)] = []
        for e in coolerEvents {
            all.append((e.date, e.isOn ? .evaporativeCooler : .off))
        }
        for e in hvacEvents {
            let state: HVACState
            switch e.mode {
            case 1:  state = .heating
            case 2:  state = .airConditioning
            default: state = .off
            }
            all.append((e.date, state))
        }
        changes = all.sorted { $0.0 < $1.0 }.map { (date: $0.0, state: $0.1) }
    }

    /// State implied by the most recent event at or before `date`.
    func state(at date: Date) -> HVACState {
        var result: HVACState = .off
        for change in changes {
            if change.date <= date { result = change.state } else { break }
        }
        return result
    }

    /// Whether any logged change falls strictly inside the interval.
    func hasTransition(between start: Date, and end: Date) -> Bool {
        changes.contains { $0.date > start && $0.date < end }
    }
}

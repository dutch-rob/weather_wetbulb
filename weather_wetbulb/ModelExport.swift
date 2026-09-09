//
//  ModelExport.swift
//  weather_wetbulb
//
//  A complete snapshot of everything the indoor model was fitted from, plus
//  what it produced.
//
//  The point is reproducibility. Development work happens on a Mac that cannot
//  see the phone's store — iCloud syncs it between the user's devices, but no
//  Mac app opens it — so any fit done there used different inputs and could
//  never be compared with the app's. Exporting the inputs AND the resulting
//  coefficients turns that into something checkable: refit the bundle offline,
//  compare against `model`, and a mismatch means one of the two is wrong.
//
//  So this deliberately carries the WeatherKit series as well as the station
//  readings. Re-fetching the forecast later would not reproduce it: WeatherKit
//  revises its history, and the numbers behind a past fit are gone once the
//  fit is over.
//

import Foundation
import SwiftData

struct ModelExport: Codable {

    // MARK: - Inputs

    /// One stored station reading, as the model saw it.
    struct Reading: Codable {
        var date: Date
        var sourceID: String
        var indoorTempC: Double?
        var indoorHumidity: Double?
        var outdoorTempC: Double?
        var outdoorHumidity: Double?
        var windSpeedMS: Double?
        var windGustMS: Double?
        var windDirectionDeg: Double?
        var lightKLux: Double?
        /// Cumulative counter, exactly as published; differencing is the
        /// consumer's job, as it is in the app.
        var rainfallMM: Double?
        var stationPressureHPa: Double?

        init(_ r: IndoorReading) {
            date = r.date
            sourceID = r.sourceID
            indoorTempC = r.indoorTempC
            indoorHumidity = r.indoorHumidity
            outdoorTempC = r.outdoorTempC
            outdoorHumidity = r.outdoorHumidity
            windSpeedMS = r.windSpeedMS
            windGustMS = r.windGustMS
            windDirectionDeg = r.windDirectionDeg
            lightKLux = r.lightKLux
            rainfallMM = r.rainfallMM
            stationPressureHPa = r.stationPressureHPa
        }
    }

    /// The WeatherKit fields the aligner actually reads. Not the whole
    /// ForecastPoint: only what affects the fit, so the file stays small enough
    /// to share.
    struct Weather: Codable {
        var date: Date
        var temperatureC: Double
        /// 0…1, as WeatherKit reports it. The aligner scales to percent.
        var humidity: Double
        var windSpeedKPH: Double
        var windGustKPH: Double
        var windDirectionDegrees: Double?
        var precipitationMM: Double
        var stationPressurePa: Double
        var cloudCover: Double
        var isDaylight: Bool

        init(_ p: ForecastPoint) {
            date = p.date
            temperatureC = p.temperatureC
            humidity = p.humidity
            windSpeedKPH = p.windSpeedKPH
            windGustKPH = p.windGustKPH
            windDirectionDegrees = p.windDirectionDegrees
            precipitationMM = p.precipitationMM
            stationPressurePa = p.stationPressurePa
            cloudCover = p.cloudCover
            isDaylight = p.isDaylight
        }
    }

    struct Event: Codable {
        var date: Date
        /// "cooler" or "hvac" — which record type this came from.
        var kind: String
        /// HVAC only: -1 unknown, 0 off, 1 heating, 2 AC, 3 vent.
        var mode: Int?
        /// Cooler only.
        var isOn: Bool?
        var targetTempC: Double?
        /// 0 logged by hand, 1 inferred by the app.
        var source: Int
    }

    // MARK: - Output

    /// What the app fitted from these inputs, so an offline refit can be
    /// checked against it rather than merely admired.
    struct FittedModel: Codable {
        var encoding: String
        var sources: [String: String]
        var temperature: [Double]
        var dewPoint: [Double]
        var temperatureLabels: [String]
        var dewPointLabels: [String]
        var temperatureRMSE: Double
        var dewPointRMSE: Double
        var combined: Double
        var observationCount: Int
        var fittedAt: Date

        init(_ m: IndoorModel) {
            encoding = m.encoding.rawValue
            sources = Dictionary(uniqueKeysWithValues:
                OutdoorVariable.allCases.map { ($0.rawValue, m.plan[$0].rawValue) })
            temperature = m.temperature
            dewPoint = m.dewPoint
            temperatureLabels = m.temperatureLabels
            dewPointLabels = m.dewPointLabels
            temperatureRMSE = m.score.temperatureRMSE
            dewPointRMSE = m.score.dewPointRMSE
            combined = m.score.combined
            observationCount = m.observationCount
            fittedAt = m.fittedAt
        }
    }

    var exportedAt: Date
    /// e.g. "1.2 (7)".
    var appVersion: String
    /// Thresholds the aligner used, so an offline refit does not have to guess
    /// them or silently drift from the app's.
    var maxPairIntervalSeconds: Double
    var minPairIntervalSeconds: Double
    var testFraction: Double

    var readings: [Reading]
    var weather: [Weather]
    var events: [Event]
    var model: FittedModel?

    // MARK: - Building

    static func build(readings: [IndoorReading],
                      weather: [ForecastPoint],
                      coolerEvents: [CoolerEvent],
                      hvacEvents: [HVACEvent],
                      model: IndoorModel?) -> ModelExport {
        var events: [Event] = coolerEvents.map {
            Event(date: $0.date, kind: "cooler", mode: nil, isOn: $0.isOn,
                  targetTempC: nil, source: $0.source)
        }
        events += hvacEvents.map {
            Event(date: $0.date, kind: "hvac", mode: $0.mode, isOn: nil,
                  targetTempC: $0.targetTempC, source: $0.source)
        }
        events.sort { $0.date > $1.date }

        return ModelExport(
            exportedAt: Date(),
            appVersion: BuildInfo.versionString,
            maxPairIntervalSeconds: IndoorObservationBuilder.maxPairInterval,
            minPairIntervalSeconds: IndoorObservationBuilder.minPairInterval,
            testFraction: IndoorModelEstimator.testFraction,
            readings: readings.sorted { $0.date < $1.date }.map(Reading.init),
            weather: weather.sorted { $0.date < $1.date }.map(Weather.init),
            events: events,
            model: model.map(FittedModel.init))
    }

    /// Write to a temporary file for sharing. The name carries a timestamp so
    /// successive exports do not overwrite each other in Files or Downloads.
    func write() -> URL? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let url = URL.temporaryDirectory
            .appending(path: "wetbulbcast-model-\(stamp.string(from: exportedAt)).json")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

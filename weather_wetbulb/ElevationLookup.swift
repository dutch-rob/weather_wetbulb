//
//  ElevationLookup.swift
//  weather_wetbulb
//
//  Ground elevation for a coordinate, so a place's altitude does not have to be
//  typed in.
//
//  Why this is needed at all: a place is chosen by panning a map, which yields
//  a latitude and longitude and nothing else. Apple offers no way to ask how
//  high the ground is at an arbitrary point — CLLocation carries an altitude
//  only when it came from the device's own GPS, which describes where the phone
//  is, not the place being edited. Without a height, WeatherKit's sea-level
//  pressure is used unreduced, and wet bulb comes out around half a degree too
//  high for a house at 1000 m. That is the number this app exists to get right.
//
//  Two services, in this order:
//
//   1. USGS 3DEP (epqs.nationalmap.gov) — United States only, and worth asking
//      first because it models BARE EARTH at 1–10 m. The global sets are
//      surface models that include buildings and tree canopy: downtown Phoenix
//      reads 331.7 m from USGS against 364 m from SRTM, a 32 m difference that
//      is mostly rooftops.
//   2. Open Topo Data (api.opentopodata.org) — everywhere else, serving SRTM
//      and ASTER at roughly 30 m. SRTM stops at 60 degrees of latitude, so the
//      request asks for `srtm30m,aster30m`: that endpoint tries each dataset in
//      turn until one answers, and reports which one did.
//
//  Neither needs an API key. Open Topo Data's public instance allows about one
//  call a second and a thousand a day across all its users, which one tap per
//  place sits well inside; heavy use is meant to self-host.
//
//  Both services answer "no data here" in their own way, and neither is an
//  error worth alarming anyone about — the field stays editable by hand:
//   - USGS replies with the plain sentence "Invalid or missing input
//     parameters." instead of JSON, for anywhere outside the United States.
//   - Open Topo Data replies with `elevation: null` and `status: "OK"`, for a
//     point at sea or outside a dataset's bounds.
//

import Foundation

enum ElevationLookup {

    /// Which model answered, so the reading can be judged rather than trusted
    /// blindly. A 30 m surface model is fine for pressure, but it is not the
    /// height of a doorstep on a ridge.
    enum Source {
        case usgs
        case openTopoData(dataset: String)

        var label: String {
            switch self {
            case .usgs: return "USGS 3DEP"
            case .openTopoData(let dataset):
                switch dataset {
                case "srtm30m":  return "SRTM (30 m)"
                case "aster30m": return "ASTER (30 m)"
                default:         return dataset
                }
            }
        }

        /// True for the global surface models, which sit on top of buildings
        /// and trees rather than on the ground.
        var isSurfaceModel: Bool {
            if case .openTopoData = self { return true }
            return false
        }
    }

    struct Reading {
        let metres: Double
        let source: Source
    }

    enum Failure: LocalizedError {
        /// Both services answered, and neither has ground here.
        case noData
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noData:
                return "No elevation data for this spot. Type the altitude in yourself."
            case .network(let detail):
                return "Could not reach the elevation services. \(detail)"
            }
        }
    }

    /// Elevations outside this range are treated as no data rather than
    /// believed: rasters report large sentinels where they hold no value, and
    /// nowhere inhabited sits outside these bounds.
    static let plausibleMetres: ClosedRange<Double> = -500...9000

    // MARK: - Lookup

    /// Ground elevation for a coordinate, from whichever service has it.
    static func lookUp(latitude: Double, longitude: Double,
                       timeout: TimeInterval = 15) async throws -> Reading {
        var networkDetail: String?

        // 1. USGS first: bare earth, and far finer where it applies.
        do {
            let data = try await fetch(usgsURL(latitude: latitude, longitude: longitude),
                                       timeout: timeout)
            return Reading(metres: try parseUSGS(data), source: .usgs)
        } catch Failure.network(let detail) {
            networkDetail = detail          // try the global service anyway
        } catch {
            // No USGS coverage: expected outside the United States.
        }

        // 2. Global fallback.
        do {
            let data = try await fetch(openTopoDataURL(latitude: latitude, longitude: longitude),
                                       timeout: timeout)
            return try parseOpenTopoData(data)
        } catch Failure.network(let detail) {
            throw Failure.network(detail)
        } catch {
            if let networkDetail { throw Failure.network(networkDetail) }
            throw Failure.noData
        }
    }

    // MARK: - Requests

    static func usgsURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(string: "https://epqs.nationalmap.gov/v1/json")!
        components.queryItems = [
            // x is longitude and y is latitude — the reverse of how they are
            // usually written.
            URLQueryItem(name: "x", value: String(longitude)),
            URLQueryItem(name: "y", value: String(latitude)),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "includeDate", value: "false"),
        ]
        return components.url!
    }

    static func openTopoDataURL(latitude: Double, longitude: Double) -> URL {
        // Datasets are tried in the order given until one answers, which covers
        // SRTM's 60-degree latitude limit without a second request.
        var components = URLComponents(string: "https://api.opentopodata.org/v1/srtm30m,aster30m")!
        components.queryItems = [
            URLQueryItem(name: "locations", value: "\(latitude),\(longitude)")
        ]
        return components.url!
    }

    private static func fetch(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                throw Failure.network("The free service is busy — try again in a moment.")
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    /// Read a USGS reply. `value` arrives as a string.
    static func parseUSGS(_ data: Data) throws -> Double {
        guard let reply = try? JSONDecoder().decode(USGSReply.self, from: data),
              let metres = reply.metres,
              plausibleMetres.contains(metres)
        else {
            // Includes the plain-text "Invalid or missing input parameters."
            // returned for a point outside coverage.
            throw Failure.noData
        }
        return metres
    }

    /// Read an Open Topo Data reply, keeping the dataset that answered.
    static func parseOpenTopoData(_ data: Data) throws -> Reading {
        guard let reply = try? JSONDecoder().decode(OpenTopoDataReply.self, from: data),
              let result = reply.results.first,
              // null elevation means sea, or outside this dataset's bounds.
              let metres = result.elevation,
              plausibleMetres.contains(metres)
        else {
            throw Failure.noData
        }
        return Reading(metres: metres, source: .openTopoData(dataset: result.dataset ?? ""))
    }

    /// Tolerates the value quoted or bare: the service quotes it today, and a
    /// future version sending a number should not break the lookup.
    private struct USGSReply: Decodable {
        let metres: Double?
        private enum CodingKeys: String, CodingKey { case value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? c.decode(String.self, forKey: .value) {
                metres = Double(text)
            } else {
                metres = try? c.decode(Double.self, forKey: .value)
            }
        }
    }

    private struct OpenTopoDataReply: Decodable {
        struct Result: Decodable {
            let dataset: String?
            let elevation: Double?
        }
        let results: [Result]
    }
}

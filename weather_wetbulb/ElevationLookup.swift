//
//  ElevationLookup.swift
//  weather_wetbulb
//
//  Ground elevation for a coordinate, from the USGS Elevation Point Query
//  Service (https://epqs.nationalmap.gov).
//
//  Why this is needed at all: a place is chosen by panning a map, which yields
//  a latitude and longitude and nothing else. Apple offers no way to ask how
//  high the ground is at an arbitrary point — CLLocation carries an altitude
//  only when it came from the device's own GPS, which describes where the phone
//  is, not the place being edited. Without a height, WeatherKit's sea-level
//  pressure is used unreduced, and wet bulb comes out around half a degree too
//  high for a house at 1000 m. That is the number this app exists to get right.
//
//  Two things about the service shape the code:
//
//   - `value` arrives as a STRING ("331.673278809"), not a number.
//   - Outside its coverage the reply is not JSON at all, but the plain
//     sentence "Invalid or missing input parameters." So a decode failure is
//     the normal answer for anywhere outside the United States, and must read
//     as "no data here", not as a broken request.
//

import Foundation

enum ElevationLookup {

    enum Failure: LocalizedError {
        /// The service answered, but has no elevation for this point — which is
        /// the expected answer anywhere outside the United States.
        case noCoverage
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noCoverage:
                return "No USGS elevation for this place. Coverage is the United States; elsewhere, type the altitude in."
            case .network(let detail):
                return "Could not reach the USGS elevation service. \(detail)"
            }
        }
    }

    /// Elevations outside this range are treated as no data rather than
    /// believed. The service uses large negative sentinels where a raster has
    /// no value, and no inhabited place sits outside these bounds.
    static let plausibleMetres: ClosedRange<Double> = -500...9000

    /// Ground elevation in metres above sea level.
    static func metres(latitude: Double, longitude: Double,
                       timeout: TimeInterval = 15) async throws -> Double {
        var components = URLComponents(string: "https://epqs.nationalmap.gov/v1/json")!
        components.queryItems = [
            // x is longitude and y is latitude — the service takes them in that
            // order, which is the reverse of how they are usually written.
            URLQueryItem(name: "x", value: String(longitude)),
            URLQueryItem(name: "y", value: String(latitude)),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "includeDate", value: "false"),
        ]
        guard let url = components.url else { throw Failure.noCoverage }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = timeout

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        return try parse(data)
    }

    /// Read an elevation out of a reply body.
    ///
    /// Separate from the request so the two shapes the service actually returns
    /// can be tested without the network.
    static func parse(_ data: Data) throws -> Double {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let metres = reply.metres,
              plausibleMetres.contains(metres)
        else {
            // Includes the plain-text "Invalid or missing input parameters."
            // that comes back for a point outside coverage.
            throw Failure.noCoverage
        }
        return metres
    }

    /// The one field that matters, tolerating either a quoted or bare number:
    /// the service sends a string today, and a future version sending a number
    /// should not break the lookup.
    private struct Reply: Decodable {
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
}

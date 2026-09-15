//
//  StationCloudArchive.swift
//  weather_wetbulb
//
//  Reads the weather station's archive from CloudKit.
//
//  The station app writes one record per UTC day into a custom zone of the
//  private database, in this app's own container — the one it already declares
//  for sync, so no entitlement changes. This side only ever reads.
//
//  Reads go through the zone's change feed with a stored token, so after the
//  first full read only the days that changed come back, which in practice is
//  just today. The token is committed only once the rows are saved: a failed
//  save means the same days are fetched again rather than skipped.
//
//  Environment: a build run from Xcode reads CloudKit's Development environment
//  and a TestFlight or App Store build reads Production. The records exist only
//  in the environment the station app wrote them to.
//

import Foundation
import CloudKit

actor StationCloudArchive {
    static let containerIdentifier = "iCloud.robotex.weather-wetbulb"
    static let zoneName = "WeatherReadings"
    static let recordType = "DayReadings"
    private static let tokenKey = "stationArchive.changeToken"

    /// One day record, reduced to what this app reads.
    nonisolated struct DayRecord: Sendable, Equatable {
        /// "yyyy-MM-dd", UTC.
        let day: String
        /// The device's name, when the station app knew it.
        let station: String?
        /// Deflated JSON samples; see `StationDay.samples(fromPayload:)`.
        let payload: Data
    }

    nonisolated struct Changes: Sendable {
        /// Changed days, oldest first.
        let days: [DayRecord]
        /// True when the read began at the start of the archive rather than
        /// from a stored token, so `days` is everything the archive holds.
        let fromStart: Bool
    }

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var pendingToken: CKServerChangeToken?

    init() {
        database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Day records changed since the last committed read.
    ///
    /// An archive that does not exist — the station app has never written in
    /// this environment — reads as no days rather than as an error.
    func fetchChanges() async throws -> Changes {
        let token = storedToken()
        do {
            return try await read(since: token)
        } catch let error as CKError where error.code == .changeTokenExpired {
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            return try await read(since: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            pendingToken = nil
            return Changes(days: [], fromStart: token == nil)
        }
    }

    /// Remember how far the last fetch got. Call only after its rows are saved.
    func commit() {
        guard let pendingToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: pendingToken,
                                                           requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.tokenKey)
    }

    private func read(since start: CKServerChangeToken?) async throws -> Changes {
        var token = start
        var days: [DayRecord] = []
        while true {
            let batch = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for result in batch.modificationResultsByID.values {
                guard let record = try? result.get().record,
                      record.recordType == Self.recordType,
                      let payload = record["readings"] as? Data
                else { continue }
                let station = (record["station"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                days.append(DayRecord(day: record["day"] as? String ?? record.recordID.recordName,
                                      station: station, payload: payload))
            }
            token = batch.changeToken
            guard batch.moreComing else { break }
        }
        // Deleted day records are ignored: only the station app writes here,
        // and it never deletes, so keeping rows is the safer reading of one.
        pendingToken = token
        return Changes(days: days.sorted { $0.day < $1.day }, fromStart: start == nil)
    }

    private func storedToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

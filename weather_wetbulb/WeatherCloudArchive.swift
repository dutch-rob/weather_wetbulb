//
//  WeatherCloudArchive.swift
//  weather_wetbulb
//
//  The WeatherKit history, kept in CloudKit so it outlives the ten days
//  WeatherKit itself will serve and follows the user to another device.
//
//  Same shape as the station's archive: one record per UTC day in a custom zone
//  of the private database, read through the zone's change feed with a stored
//  token. The difference is that this app writes these records — the station
//  app never touches this zone — so it also creates the zone.
//
//  A finished day never changes, so it uploads once. Only today's record is
//  rewritten, and it is a couple of kilobytes.
//

import Foundation
import CloudKit

actor WeatherCloudArchive {
    static let zoneName = "WeatherHistory"
    static let recordType = "WeatherDay"
    private static let tokenKey = "weatherArchive.changeToken"
    private static let pushedKey = "weatherArchive.pushedCounts"

    nonisolated struct DayRecord: Sendable, Equatable {
        let day: String
        let place: String
        let latitude: Double
        let longitude: Double
        let hourCount: Int
        /// Deflated JSON array of `ForecastPoint`.
        let hours: Data

        var recordName: String { "\(place)|\(day)" }
    }

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var zoneReady = false
    private var pendingToken: CKServerChangeToken?

    init(containerIdentifier: String = StationCloudArchive.containerIdentifier) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Reading

    /// Days written by this or another device since the last committed read.
    func fetchChanges() async throws -> [DayRecord] {
        do {
            return try await read(since: storedToken())
        } catch let error as CKError where error.code == .changeTokenExpired {
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            return try await read(since: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            pendingToken = nil
            return []                       // nothing archived yet
        }
    }

    /// Remember how far the last read got. Call once its days are saved.
    func commit() {
        guard let pendingToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: pendingToken,
                                                           requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.tokenKey)
    }

    // MARK: - Writing

    /// Upload days whose hour count exceeds what CloudKit is known to hold.
    @discardableResult
    func save(_ days: [DayRecord]) async throws -> Int {
        var pushed = pushedCounts()
        let outstanding = days.filter { $0.hourCount > (pushed[$0.recordName] ?? -1) }
        guard !outstanding.isEmpty else { return 0 }
        try await ensureZone()

        var written = 0
        // In batches, so a long backfill does not build one enormous request.
        for batch in stride(from: 0, to: outstanding.count, by: 40).map({
            Array(outstanding[$0..<min($0 + 40, outstanding.count)])
        }) {
            let records = batch.map { day -> CKRecord in
                let record = CKRecord(recordType: Self.recordType,
                                      recordID: CKRecord.ID(recordName: day.recordName, zoneID: zoneID))
                record["day"] = day.day as CKRecordValue
                record["place"] = day.place as CKRecordValue
                record["latitude"] = day.latitude as CKRecordValue
                record["longitude"] = day.longitude as CKRecordValue
                record["count"] = day.hourCount as CKRecordValue
                record["hours"] = day.hours as CKRecordValue
                return record
            }
            // `.allKeys` overwrites without an etag: the local copy is the
            // source of truth for a day, and a later fetch only ever adds hours.
            let result = try await database.modifyRecords(saving: records, deleting: [],
                                                          savePolicy: .allKeys, atomically: false)
            for (id, outcome) in result.saveResults {
                guard case .success = outcome else { continue }
                pushed[id.recordName] = batch.first { $0.recordName == id.recordName }?.hourCount
                written += 1
            }
        }
        UserDefaults.standard.set(pushed, forKey: Self.pushedKey)
        return written
    }

    // MARK: - Internals

    private func read(since start: CKServerChangeToken?) async throws -> [DayRecord] {
        var token = start
        var days: [DayRecord] = []
        while true {
            let batch = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for result in batch.modificationResultsByID.values {
                guard let record = try? result.get().record,
                      record.recordType == Self.recordType,
                      let day = record["day"] as? String,
                      let place = record["place"] as? String,
                      let hours = record["hours"] as? Data
                else { continue }
                days.append(DayRecord(day: day, place: place,
                                      latitude: record["latitude"] as? Double ?? 0,
                                      longitude: record["longitude"] as? Double ?? 0,
                                      hourCount: record["count"] as? Int ?? 0,
                                      hours: hours))
            }
            token = batch.changeToken
            guard batch.moreComing else { break }
        }
        pendingToken = token
        return days
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    private func storedToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func pushedCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: Self.pushedKey) as? [String: Int]) ?? [:]
    }
}

import Foundation
import CloudKit
import OSLog

/// 0.7.0 — the CloudKit "heartbeat" behind the **Hub-offline banner**.
///
/// A Mac running as the always-on Reolens Hub periodically writes a
/// single `HubStatus` record to the user's *private* CloudKit database;
/// the user's other devices read it and, if the heartbeat has gone
/// stale, show "Hub offline — notifications paused". This rides the same
/// no-server pattern as `MotionEvent` — CloudKit-under-the-user's-own-
/// iCloud is "the server" (AGENTS.md §5). There is still no Reolens
/// backend.
///
/// One record per hub *device* (record name = a stable per-install
/// `hubDeviceID`), so repeated heartbeats replace it in place rather
/// than accumulating. Staleness is judged from the CloudKit server's
/// `modificationDate` — never the client-written `lastSeen` — so two
/// devices with skewed clocks still agree on "is the hub alive".
///
/// `HubStatus` is a **new CloudKit record type**: it works on Development
/// schema immediately but must be promoted to Production before a
/// release build can save it (see docs/TESTFLIGHT_NOTIFICATIONS.md and
/// AGENTS.md §7). Queryability requires the `recordName` index — part of
/// the same schema promotion.
public struct HubStatus: Sendable, Equatable, Identifiable {
    /// Stable per-install identifier for the hub Mac.
    public let hubDeviceID: String
    /// User-facing Mac name, e.g. "Mac mini".
    public let hubDeviceName: String
    /// Client-written timestamp of this heartbeat. Kept for display
    /// ("last seen 3m ago"); NOT used for the staleness decision.
    public let lastSeen: Date
    /// Reolens version of the hub, for diagnostics. Optional.
    public let appVersion: String?
    /// Whether the hub currently has the CloudKit publisher on. Lets a
    /// receiver distinguish a Hub that was turned off gracefully (neutral
    /// "role off") from one that crashed or lost power (red "offline").
    public let relayPublisherEnabled: Bool
    /// Server-assigned modification time, populated on decode from
    /// CloudKit. The staleness math uses this (skew-proof); nil when the
    /// value was built locally for writing.
    public let serverModifiedAt: Date?

    public var id: String { hubDeviceID }

    public init(
        hubDeviceID: String,
        hubDeviceName: String,
        lastSeen: Date,
        appVersion: String?,
        relayPublisherEnabled: Bool,
        serverModifiedAt: Date? = nil
    ) {
        self.hubDeviceID = hubDeviceID
        self.hubDeviceName = hubDeviceName
        self.lastSeen = lastSeen
        self.appVersion = appVersion
        self.relayPublisherEnabled = relayPublisherEnabled
        self.serverModifiedAt = serverModifiedAt
    }

    public static let recordType = "HubStatus"

    public enum RecordKey {
        public static let hubDeviceID = "hubDeviceID"
        public static let hubDeviceName = "hubDeviceName"
        public static let lastSeen = "lastSeen"
        public static let appVersion = "appVersion"
        public static let relayPublisherEnabled = "relayPublisherEnabled"
    }

    /// Build the replace-in-place `CKRecord`. Record name is the stable
    /// `hubDeviceID` so each heartbeat overwrites the prior one.
    public func toRecord(in zone: CKRecordZone.ID = .default) -> CKRecord {
        let recordID = CKRecord.ID(recordName: hubDeviceID, zoneID: zone)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[RecordKey.hubDeviceID] = hubDeviceID as NSString
        record[RecordKey.hubDeviceName] = hubDeviceName as NSString
        record[RecordKey.lastSeen] = lastSeen as NSDate
        if let appVersion, !appVersion.isEmpty {
            record[RecordKey.appVersion] = appVersion as NSString
        }
        record[RecordKey.relayPublisherEnabled] = (relayPublisherEnabled ? 1 : 0) as NSNumber
        return record
    }

    /// Decode a fetched record. Returns nil on a wrong type or a missing
    /// required field; captures the server `modificationDate` for the
    /// staleness comparison.
    public static func decode(record: CKRecord) -> HubStatus? {
        guard record.recordType == Self.recordType,
              let deviceID = record[RecordKey.hubDeviceID] as? String,
              let name = record[RecordKey.hubDeviceName] as? String,
              let lastSeen = record[RecordKey.lastSeen] as? Date
        else { return nil }
        let version = (record[RecordKey.appVersion] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let relayOn = ((record[RecordKey.relayPublisherEnabled] as? Int) ?? 0) != 0
        return HubStatus(
            hubDeviceID: deviceID,
            hubDeviceName: name,
            lastSeen: lastSeen,
            appVersion: version,
            relayPublisherEnabled: relayOn,
            serverModifiedAt: record.modificationDate
        )
    }
}

/// Stable per-install identifier for this Mac as a hub. Persisted once
/// in `UserDefaults` so every heartbeat replaces the same CloudKit
/// record rather than accumulating one per launch.
public enum HubDeviceIdentity {
    static let key = "com.reolens.hubDeviceID"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key) { return existing }
        let new = UUID().uuidString
        defaults.set(new, forKey: key)
        return new
    }
}

/// Writes hub heartbeats to the private CloudKit database. Mirrors
/// `CloudKitMotionEventPublisher`'s entitlement + account guards; uses an
/// `.allKeys` save policy so the stable-ID record is upserted (overwrites
/// the prior heartbeat) instead of failing with `serverRecordChanged`.
public actor CloudKitHubStatusPublisher {
    private let containerID: String
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "HubStatus")

    public init(containerID: String = "iCloud.com.reolens.Reolens") {
        self.containerID = containerID
    }

    public func write(_ status: HubStatus) async {
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else {
            log.info("CloudKit unavailable on this binary; skipping hub heartbeat")
            return
        }
        let enrolledHash: String?
        switch CloudKitAccountIdentityGuard.decide() {
        case .accountChanged:
            log.error("Skipping hub heartbeat: iCloud account identity changed")
            return
        case .unavailable:
            log.info("Skipping hub heartbeat: no iCloud identity token")
            return
        case .allow:
            enrolledHash = nil
        case .enrollAndAllow(let hash):
            enrolledHash = hash
        }

        let db = CKContainer(identifier: containerID).privateCloudDatabase
        do {
            // `.allKeys` upserts the stable-ID record, overwriting the
            // previous heartbeat regardless of its change tag.
            _ = try await db.modifyRecords(
                saving: [status.toRecord()],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            if let enrolledHash { CloudKitAccountIdentityGuard.enroll(hash: enrolledHash) }
            log.debug("Hub heartbeat written (publisherEnabled=\(status.relayPublisherEnabled, privacy: .public))")
        } catch {
            log.warning("Hub heartbeat write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Reads every hub's heartbeat from the private CloudKit database.
/// Runs on all platforms (any device may need to show the banner).
public actor CloudKitHubStatusReader {
    private let containerID: String
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "HubStatus")

    public init(containerID: String = "iCloud.com.reolens.Reolens") {
        self.containerID = containerID
    }

    /// Fetch all `HubStatus` records. Returns an empty array when
    /// CloudKit is unavailable or the query fails — callers treat that as
    /// "unknown", never "offline".
    public func fetchAll() async -> [HubStatus] {
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else { return [] }
        let db = CKContainer(identifier: containerID).privateCloudDatabase
        let query = CKQuery(recordType: HubStatus.recordType, predicate: NSPredicate(value: true))
        do {
            let (results, _) = try await db.records(matching: query)
            return results.compactMap { _, result in
                switch result {
                case .success(let record): return HubStatus.decode(record: record)
                case .failure: return nil
                }
            }
        } catch {
            log.warning("Hub status fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

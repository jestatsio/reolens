import Foundation
import CloudKit
import OSLog

/// 0.7.0 — encrypted cross-device delivery of camera passwords to the
/// Apple TV.
///
/// **Why this exists.** iCloud Keychain (the existing opt-in password
/// sync, AGENTS.md §4) does **not** propagate generic passwords to
/// tvOS. So the Apple TV viewer sees the camera list (it rides iCloud
/// Drive) but has no passwords to stream with. This type closes that
/// gap WITHOUT relaxing §4's rules:
///
/// - The password is stored in `CKRecord.encryptedValues` — CloudKit
///   encrypts it client-side with keys held in the **user's own iCloud
///   account** (reachable by their Apple TV); Apple's servers store only
///   ciphertext. There is no Reolens server (AGENTS.md §5).
/// - Publishing is an **explicit, off-by-default opt-in** distinct from
///   iCloud-Keychain sync (see `TVCredentialSync`), surfaced with its
///   trade-off in Settings.
/// - The password is never written to `UserDefaults`, `cameras.json`, a
///   log, or any plaintext store (AGENTS.md §3 / §4 / §11). On tvOS it is
///   held **in memory only** (tvOS has no durable per-app Keychain).
///
/// `CameraCredential` is a **new CloudKit record type** with an
/// **encrypted field** — it must be promoted to Production (with the
/// `password` field marked encrypted) before a release build can save it.
public struct CameraCredential: Sendable, Equatable {
    public let cameraID: UUID
    /// Sensitive. Only ever lives in `encryptedValues` on the wire and in
    /// memory at the endpoints. Never logged, never persisted in plaintext.
    public let password: String

    public init(cameraID: UUID, password: String) {
        self.cameraID = cameraID
        self.password = password
    }

    public static let recordType = "CameraCredential"

    public enum RecordKey {
        public static let cameraID = "cameraID"
        /// Stored via `record.encryptedValues` — NOT a plaintext field.
        public static let password = "password"
    }

    /// Stable record name per camera so a re-publish replaces in place.
    public static func recordName(for cameraID: UUID) -> String {
        "cred-\(cameraID.uuidString)"
    }

    public func toRecord(in zone: CKRecordZone.ID = .default) -> CKRecord {
        let recordID = CKRecord.ID(recordName: Self.recordName(for: cameraID), zoneID: zone)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[RecordKey.cameraID] = cameraID.uuidString as NSString
        // Encrypted field — CloudKit ciphers this with the user's own
        // CloudKit keys; the server never sees plaintext.
        record.encryptedValues[RecordKey.password] = password as NSString
        return record
    }

    public static func decode(record: CKRecord) -> CameraCredential? {
        guard record.recordType == Self.recordType,
              let idString = record[RecordKey.cameraID] as? String,
              let id = UUID(uuidString: idString),
              let password = record.encryptedValues[RecordKey.password] as? String
        else { return nil }
        return CameraCredential(cameraID: id, password: password)
    }
}

/// Publishes / removes encrypted camera credentials in the user's private
/// CloudKit database. Mirrors `CloudKitMotionEventPublisher`'s entitlement
/// + account guards. Never logs the password.
public actor CloudKitCameraCredentialPublisher {
    private let containerID: String
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "CredentialSync")

    public init(containerID: String = "iCloud.com.reolens.Reolens") {
        self.containerID = containerID
    }

    public func publish(_ credentials: [CameraCredential]) async {
        guard !credentials.isEmpty else { return }
        guard let db = await authorizedDatabase() else { return }
        do {
            // `.allKeys` upserts each stable-ID record; non-atomic so one
            // failure doesn't drop the rest.
            _ = try await db.modifyRecords(
                saving: credentials.map { $0.toRecord() },
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
            // Count only — NEVER the password (AGENTS.md §3 / §11).
            log.info("Published \(credentials.count, privacy: .public) encrypted camera credential(s)")
        } catch {
            log.warning("Credential publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deleteAll(cameraIDs: [UUID]) async {
        guard !cameraIDs.isEmpty else { return }
        guard let db = await authorizedDatabase() else { return }
        let ids = cameraIDs.map { CKRecord.ID(recordName: CameraCredential.recordName(for: $0)) }
        do {
            _ = try await db.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            log.info("Removed \(ids.count, privacy: .public) camera credential(s) from CloudKit")
        } catch {
            log.warning("Credential delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shared availability + iCloud-account guard, returning the private
    /// DB only when it's safe to write. Mirrors the motion publisher.
    private func authorizedDatabase() async -> CKDatabase? {
        guard CloudKitAvailability.canUseCloudKit(containerID: containerID) else {
            log.info("CloudKit unavailable; skipping credential sync")
            return nil
        }
        switch CloudKitAccountIdentityGuard.decide() {
        case .accountChanged:
            log.error("Skipping credential sync: iCloud account identity changed")
            return nil
        case .unavailable:
            log.info("Skipping credential sync: no iCloud identity token")
            return nil
        case .allow:
            break
        case .enrollAndAllow(let hash):
            CloudKitAccountIdentityGuard.enroll(hash: hash)
        }
        return CKContainer(identifier: containerID).privateCloudDatabase
    }
}

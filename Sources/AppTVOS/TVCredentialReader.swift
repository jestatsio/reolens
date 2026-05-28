import Foundation
import CloudKit
import Observation
import OSLog

private let log = Logger(subsystem: "com.reolens.tvOS", category: "credentials")

/// 0.7.0 — fetches encrypted camera passwords from the user's private
/// CloudKit database (published by iOS/macOS when the user enables
/// "Stream on Apple TV"). Held **in memory only** — never written to
/// disk or `UserDefaults` (tvOS has no durable per-app Keychain, and
/// AGENTS.md §4 forbids persisting passwords anywhere but Keychain).
/// Passwords are never logged (§3 / §11).
///
/// **Contract:** the record type + field names below MUST match
/// `AppShared.CameraCredential`. The password lives in `encryptedValues`
/// (CloudKit ciphers it with the user's own keys; the server never sees
/// plaintext).
@MainActor
@Observable
public final class TVCredentialReader {
    public private(set) var didLoad = false

    /// In-memory only. cameraID → password.
    @ObservationIgnored private var passwords: [UUID: String] = [:]

    private static let containerID = "iCloud.com.reolens.Reolens"
    private static let recordType = "CameraCredential"
    private static let cameraIDKey = "cameraID"
    private static let passwordKey = "password" // encryptedValues

    public init() {}

    public func password(for cameraID: UUID) -> String? { passwords[cameraID] }

    /// Whether any credentials were fetched (used to choose between the
    /// "syncing" and "turn on Stream on Apple TV" empty states).
    public var hasAnyCredentials: Bool { !passwords.isEmpty }

    public func load() async {
        passwords = await Self.fetch()
        didLoad = true
        log.info("tvOS credentials loaded for \(self.passwords.count, privacy: .public) camera(s)")
    }

    private static func fetch() async -> [UUID: String] {
        // `CKContainer(identifier:)` traps (EXC_BREAKPOINT) on a binary
        // that lacks the iCloud-container entitlement, and there's
        // nothing to fetch when this Apple TV isn't signed into iCloud.
        // The ubiquity-identity token is a safe nil-returning probe for
        // both — gate CloudKit access on it so the app degrades to the
        // empty state instead of crashing. (AppShared's CloudKitAvailability
        // serves the same role for the Mac/iOS apps; AppTVOS can't import it.)
        guard FileManager.default.ubiquityIdentityToken != nil else {
            log.info("iCloud unavailable on this Apple TV; no credentials to fetch")
            return [:]
        }
        let db = CKContainer(identifier: containerID).privateCloudDatabase
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        do {
            let (results, _) = try await db.records(matching: query)
            var out: [UUID: String] = [:]
            for (_, result) in results {
                guard case .success(let record) = result,
                      let idString = record[cameraIDKey] as? String,
                      let id = UUID(uuidString: idString),
                      let password = record.encryptedValues[passwordKey] as? String
                else { continue }
                out[id] = password
            }
            return out
        } catch {
            log.warning("Credential fetch failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}

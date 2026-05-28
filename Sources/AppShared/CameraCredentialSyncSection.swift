import SwiftUI
import OSLog

/// 0.7.0 — coordinator for the "Stream on Apple TV" credential opt-in.
/// Distinct from the iCloud-Keychain-sync toggle (AGENTS.md §4): this one
/// publishes camera passwords, **encrypted**, to the user's private
/// CloudKit database so a tvOS device — which iCloud Keychain can't reach
/// — can stream. Off by default; explicit; revocable.
@MainActor
public enum TVCredentialSync {
    public static let enabledKey = "com.reolens.tvOSCredentialSync"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Apply the toggle: publish all current credentials when turning on,
    /// delete them all when turning off.
    public static func setEnabled(_ on: Bool, store: CameraStore) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            republish(store: store)
        } else {
            let ids = store.cameras.map(\.id)
            Task { await CloudKitCameraCredentialPublisher().deleteAll(cameraIDs: ids) }
        }
    }

    /// Re-publish all credentials if the opt-in is on. Call on launch and
    /// after a password add/change so the Apple TV stays current.
    public static func republishIfEnabled(store: CameraStore) {
        guard isEnabled else { return }
        republish(store: store)
    }

    private static func republish(store: CameraStore) {
        // Gather (cameraID, password) for cameras whose password is on
        // THIS device. Reads happen on the main actor; the password
        // strings never touch a log or disk here.
        let credentials = store.cameras.compactMap { entry -> CameraCredential? in
            guard let password = store.keychainStore.password(for: entry.id) else { return nil }
            return CameraCredential(cameraID: entry.id, password: password)
        }
        Task { await CloudKitCameraCredentialPublisher().publish(credentials) }
    }
}

/// Settings section for the Apple TV credential opt-in. Cross-platform
/// (iOS / macOS both publish). Surfaces the trade-off plainly per
/// AGENTS.md §4 — turning this on means camera passwords leave this
/// device (encrypted) for your private iCloud so the Apple TV can stream.
public struct CameraCredentialSyncSection: View {
    @AppStorage(TVCredentialSync.enabledKey) private var enabled: Bool = false
    @Environment(CameraStore.self) private var store

    public init() {}

    public var body: some View {
        let cloudKitAvailable = CloudKitAvailability.canUseCloudKit(
            containerID: "iCloud.com.reolens.Reolens"
        )
        Section("Apple TV") {
            Toggle("Stream on Apple TV", isOn: $enabled)
                .disabled(!cloudKitAvailable)
                .onChange(of: enabled) { _, newValue in
                    TVCredentialSync.setEnabled(newValue, store: store)
                }
            if cloudKitAvailable {
                Text("New in 0.7.0. The Apple TV app can show your camera list from iCloud, but Apple doesn't sync camera passwords to tvOS. Turn this on to sync your camera passwords — encrypted, through your own iCloud account, with no Reolens server — so the Apple TV can stream live video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Passwords are stored encrypted in your private iCloud (CloudKit) and held only in memory on the Apple TV. Turning this off removes them from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Label("iCloud isn't available on this Reolens build.", systemImage: "icloud.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }
}

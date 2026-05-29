#if os(macOS)
import AppKit
import ServiceManagement
import AppShared
import os

/// 0.7.0 — macOS coordinator for "Reolens Hub" mode: the explicit,
/// per-Mac opt-in that turns one always-on Mac into the headless
/// listener driving notifications, Live Activities, and the hub-health
/// heartbeat for the user's other devices.
///
/// Enabling Hub mode couples the three things that together *are* the
/// Hub:
///
/// 1. `AppPreferences.runAsHub` — read at launch (incl. by the `--hub`
///    headless bootstrap) to decide whether to start hosting.
/// 2. `MotionEventRelaySettings.publisherEnabled` — the existing
///    CloudKit publisher gate (`EventNotifier` already checks it); being
///    the Hub *is* being the publisher.
/// 3. `SMAppService.agent` — registers the bundled LaunchAgent so the
///    Mac relaunches Reolens headless at every login.
///
/// This mirrors `MenuBarController.setLaunchAtLogin` (which uses
/// `SMAppService.mainApp` for the foreground "launch at login" feature).
/// The two register *different* services and must not both be on for the
/// same purpose — the Settings UI keeps them coherent.
///
/// macOS-only by intent: iOS/iPadOS can't hold a background listener and
/// rely on the Hub Mac + CloudKit (AGENTS.md §1 carve-out). The
/// reconcile/connect logic itself lives in the cross-platform
/// `HubEngine` so it stays unit-testable; this controller is the thin
/// macOS lifecycle + login-item shell around it.
@MainActor
final class HubController {
    static let shared = HubController()

    /// File name of the LaunchAgent plist bundled at
    /// `Contents/Library/LaunchAgents/` (see Scripts/build-app.sh).
    static let agentPlistName = "com.reolens.Reolens.Hub.plist"

    private var engine: HubEngine?
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "Hub")

    private init() {}

    // MARK: - State for the Settings UI

    /// Whether this Mac is configured as the always-on Hub.
    var isEnabled: Bool { AppPreferences.runAsHubIsOn }

    /// The live engine, if hosting has started — lets the Settings
    /// section observe `hostedCameraCount` / `unhostableCameraNames`.
    var activeEngine: HubEngine? { engine }

    // MARK: - Engine lifecycle

    /// Start hosting with the given store, creating the engine on first
    /// use. Synchronous so `activeEngine` is available to the Settings
    /// UI immediately; the actual connect work runs in a detached task.
    /// Safe to call repeatedly — `HubEngine.start()` is idempotent, and
    /// reusing one engine keeps the single-`CameraStore`,
    /// single-listener-per-camera invariant.
    func startEngine(store: CameraStore) {
        let engine = engine ?? HubEngine(host: store)
        self.engine = engine
        Task { await engine.start() }
        // Begin the CloudKit heartbeat so the user's other devices can
        // tell this Hub is alive (drives the "Hub offline" banner).
        HubHeartbeatWriter.shared.start()
    }

    func stopEngine() {
        Task { [engine] in await engine?.stop() }
        HubHeartbeatWriter.shared.stop()
    }

    /// Called at launch. If this Mac is the Hub, begin hosting so the
    /// listener comes up even when launched headless or with no window.
    func syncFromDefaults(store: CameraStore) {
        guard AppPreferences.runAsHubIsOn else { return }
        log.info("Hub mode enabled on this Mac — starting engine")
        startEngine(store: store)
    }

    /// Apply the user's "Run this Mac as a Reolens Hub" toggle. Flips the
    /// runAsHub flag + the CloudKit publisher flag together, registers /
    /// unregisters the LaunchAgent, and starts / stops the engine.
    func setRunAsHub(_ enabled: Bool, store: CameraStore) {
        store.preferences.runAsHub = enabled
        // Being the Hub implies publishing motion events to CloudKit —
        // that is the point. Write the existing publisher key so
        // `EventNotifier`'s relay gate and the publisher Settings toggle
        // both reflect it without new plumbing.
        UserDefaults.standard.set(enabled, forKey: MotionEventRelaySettings.publisherEnabledKey)
        setLoginAgent(enabled)
        if enabled {
            startEngine(store: store)
        } else {
            stopEngine()
        }
    }

    // MARK: - LaunchAgent registration

    /// Register or unregister the headless Hub LaunchAgent. Registering
    /// is what surfaces the item under "Reolens" in System Settings →
    /// Login Items, satisfying AGENTS.md §5's "discoverable, never
    /// silent" requirement.
    private func setLoginAgent(_ enabled: Bool) {
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            if enabled, service.status != .enabled {
                try service.register()
                log.info("Reolens Hub LaunchAgent registered")
            } else if !enabled, service.status == .enabled {
                try service.unregister()
                log.info("Reolens Hub LaunchAgent unregistered")
            }
        } catch {
            log.error("Hub LaunchAgent toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif

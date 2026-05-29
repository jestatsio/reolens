#if os(macOS)
import AppKit
import AppShared
import os

/// 0.7.0 — macOS coordinator for "Reolens Hub" mode: the explicit,
/// per-Mac opt-in that turns this Mac into the active listener driving
/// notifications, Live Activities, and the hub-health heartbeat for the
/// user's other devices.
///
/// Enabling Hub mode couples two things that together *are* the Hub:
///
/// 1. `AppPreferences.runAsHub` — read at launch (by `syncFromDefaults`)
///    to decide whether to start hosting.
/// 2. `MotionEventRelaySettings.publisherEnabled` — the existing
///    CloudKit publisher gate (`EventNotifier` already checks it); being
///    the Hub *is* being the publisher.
///
/// The Hub keeps publishing as long as Reolens is running, including
/// after the last window closes (see
/// `applicationShouldTerminateAfterLastWindowClosed`). To have it come
/// back automatically after a reboot, pair it with "Launch at login"
/// (`MenuBarController.setLaunchAtLogin`, which uses the sandbox-safe
/// `SMAppService.mainApp`). The App Store build intentionally ships no
/// headless background LaunchAgent — a login agent that relaunches the
/// binary itself isn't App Store compatible (AGENTS.md §1 carve-out).
///
/// macOS-only by intent: iOS/iPadOS can't hold a background listener and
/// rely on the Hub Mac + CloudKit. The reconcile/connect logic itself
/// lives in the cross-platform `HubEngine` so it stays unit-testable;
/// this controller is the thin macOS lifecycle shell around it.
@MainActor
final class HubController {
    static let shared = HubController()

    private var engine: HubEngine?
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "Hub")

    private init() {}

    // MARK: - State for the Settings UI

    /// Whether this Mac is configured as the Hub.
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
    /// listener comes up even when relaunched at login with no window
    /// open yet.
    func syncFromDefaults(store: CameraStore) {
        guard AppPreferences.runAsHubIsOn else { return }
        log.info("Hub mode enabled on this Mac — starting engine")
        startEngine(store: store)
    }

    /// Apply the user's "Run this Mac as a Reolens Hub" toggle. Flips the
    /// runAsHub flag + the CloudKit publisher flag together, and starts /
    /// stops the engine.
    func setRunAsHub(_ enabled: Bool, store: CameraStore) {
        store.preferences.runAsHub = enabled
        // Being the Hub implies publishing motion events to CloudKit —
        // that is the point. Write the existing publisher key so
        // `EventNotifier`'s relay gate and the publisher Settings toggle
        // both reflect it without new plumbing.
        UserDefaults.standard.set(enabled, forKey: MotionEventRelaySettings.publisherEnabledKey)
        if enabled {
            startEngine(store: store)
        } else {
            stopEngine()
        }
    }
}
#endif

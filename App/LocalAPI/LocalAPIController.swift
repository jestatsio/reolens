#if os(macOS)
import Foundation
import AppShared
import ReolensServer
import os

/// 0.9.0 — macOS lifecycle shell for the opt-in Local HTTP API.
///
/// Mirrors `HubController`: a thin `@MainActor` coordinator that brings the
/// `ReolensAPIServer` up/down based on `AppPreferences.runLocalAPI`, injecting
/// the in-process `LiveCameraAPI` and the device-local bearer token. The server
/// binds to the LAN (loopback + RFC-1918) on the configured port and rejects
/// non-LAN peers (AGENTS.md §5 — opt-in, LAN-local, no cloud).
///
/// macOS-only by intent (AGENTS.md §1 carve-out): iPhone/iPad can't hold a
/// persistent background listener, exactly like the Hub. The contract
/// (`ReolensCore`) and adapter (`LiveCameraAPI`) ship everywhere; only the
/// persistent host is macOS-first.
@MainActor
final class LocalAPIController {
    static let shared = LocalAPIController()

    private var server: ReolensAPIServer?
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "LocalAPI")

    private init() {}

    /// Whether the server is currently up.
    var isRunning: Bool { server != nil }

    /// Called at launch. Starts the server if this Mac has the API enabled, so
    /// it comes up even when relaunched at login with no window yet.
    func syncFromDefaults(store: CameraStore) {
        guard AppPreferences.runLocalAPIIsOn else { return }
        log.info("Local API enabled on this Mac — starting server")
        start(store: store)
    }

    /// Apply the user's "Enable the Local API" toggle.
    func setEnabled(_ enabled: Bool, store: CameraStore) {
        store.preferences.runLocalAPI = enabled
        if enabled {
            start(store: store)
        } else {
            stop()
        }
    }

    /// Restart to pick up a regenerated token or a changed port.
    func restart(store: CameraStore) {
        guard isRunning else { return }
        stop()
        start(store: store)
    }

    private func start(store: CameraStore) {
        guard server == nil else { return }
        // Refuse to start without a bearer token. The gateway is fail-closed
        // anyway (a nil token rejects every protected route), but not starting
        // at all is clearer and avoids an open-looking listener (review C1).
        guard let token = LocalAPITokenStore.ensure() else {
            log.error("Local API: could not obtain a bearer token from the Keychain — not starting")
            return
        }
        let port = UInt16(exactly: store.preferences.localAPIPort) ?? 8443
        let server = ReolensAPIServer(
            api: LiveCameraAPI(store: store),
            token: token,
            config: ServerConfig(port: port, bindScope: .lan)
        )
        self.server = server
        Task {
            do {
                try await server.start()
                log.info("Local API listening on port \(port, privacy: .public)")
            } catch {
                // Most likely cause: the running build lacks the
                // `com.apple.security.network.server` entitlement, or the port
                // is already in use. Surface in the log and clear the handle so
                // the toggle can be retried.
                self.log.error("Local API failed to start: \(String(describing: error), privacy: .public)")
                self.server = nil
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
#endif

import Foundation
import Observation
import OSLog

/// 0.7.0 — the always-on listener that powers "Reolens Hub" mode.
///
/// Today the macOS app only connects a camera (and thus opens its
/// Baichuan alarm-event listener) when a view drives
/// `CameraSession.connect()`. A headless, window-less launch therefore
/// connects *nothing*. `HubEngine` closes that gap: when this Mac is the
/// designated Hub it eagerly connects **every** camera and keeps them
/// connected, so motion events flow to the user's private CloudKit
/// database — and on to the user's other devices — with no window open.
///
/// It deliberately holds no camera logic of its own. All connect /
/// disconnect / status work routes through the ``HubCameraHosting``
/// seam (satisfied by `CameraStore`), which keeps this reconciler
/// testable in isolation against an in-memory fake — no live store,
/// Keychain, or network — per AGENTS.md §6 / §12.
///
/// macOS-only by intent (iOS/iPadOS can't hold a background listener;
/// they rely on the Hub Mac + CloudKit). It lives in `AppShared` rather
/// than `App/` only so the reconcile logic can be unit-tested.
@MainActor
@Observable
public final class HubEngine {

    /// Whether the engine is actively hosting cameras (between
    /// `start()` and `stop()`).
    public private(set) var isRunning = false

    /// Number of cameras the engine is keeping connected.
    public private(set) var hostedCameraCount = 0

    /// Display names of configured cameras this Mac **cannot** host
    /// because their password was never entered here (`session(for:)`
    /// returns nil). Surfaced by `HubModeSection` so a silent "camera
    /// not watched" gap becomes a visible, fixable state rather than
    /// vanishing — see AGENTS.md §4 (credentials are device-local).
    public private(set) var unhostableCameraNames: [String] = []

    /// Total cameras the user has configured (hostable + unhostable).
    public var configuredCameraCount: Int {
        hostedCameraCount + unhostableCameraNames.count
    }

    @ObservationIgnored private let host: any HubCameraHosting
    @ObservationIgnored private let sweepInterval: Duration
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.reolens.Reolens", category: "Hub")

    /// - Parameters:
    ///   - host: the camera-hosting backend (production: `CameraStore`).
    ///   - sweepInterval: how often the keep-alive pass runs. Tests
    ///     pass a large value (or drive `reconcile()` directly) so the
    ///     timer never races assertions.
    public init(host: any HubCameraHosting, sweepInterval: Duration = .seconds(60)) {
        self.host = host
        self.sweepInterval = sweepInterval
    }

    deinit {
        sweepTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Connect every hostable camera and begin the keep-alive sweep.
    /// Idempotent — a second call while already running is a no-op.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        log.info("Hub engine starting")
        await reconcile()
        startSweep()
    }

    /// Disconnect every camera and stop the keep-alive sweep.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        sweepTask?.cancel()
        sweepTask = nil
        for camera in host.hostableCameraList {
            await host.disconnectCamera(camera.id)
        }
        hostedCameraCount = 0
        unhostableCameraNames = []
        log.info("Hub engine stopped")
    }

    // MARK: - Reconcile

    /// One keep-alive pass. Connects any hostable camera that isn't
    /// already connected (or mid-connect) — which covers the initial
    /// connect-all, reconnecting a dropped session, and adopting a
    /// camera that synced in from another device since the last pass.
    /// Cameras with no password on this Mac are recorded as unhostable,
    /// never silently skipped. Public so tests can drive it directly
    /// without waiting on the timer.
    public func reconcile() async {
        var hostableCount = 0
        var unhostable: [String] = []
        var toConnect: [UUID] = []

        for camera in host.hostableCameraList {
            guard host.hasCredentials(for: camera.id) else {
                unhostable.append(camera.displayName)
                continue
            }
            hostableCount += 1
            switch host.connectionStatus(for: camera.id) {
            case .connected, .connecting:
                break // healthy or already in-flight — leave it alone
            case nil, .disconnected, .error:
                toConnect.append(camera.id)
            }
        }

        hostedCameraCount = hostableCount
        unhostableCameraNames = unhostable

        guard !toConnect.isEmpty else { return }
        log.info("Hub reconciling \(toConnect.count, privacy: .public) camera(s)")
        // Connect concurrently: each `connect()` suspends on network
        // I/O, so the waits interleave rather than summing — and one
        // unreachable camera can't stall the rest behind its retry
        // deadline. `host` is a `@MainActor` (hence Sendable) reference;
        // the child closures hop to the main actor on call.
        let host = self.host
        await withTaskGroup(of: Void.self) { group in
            for id in toConnect {
                group.addTask {
                    await host.connectCamera(id)
                }
            }
        }
    }

    // MARK: - Sweep timer

    private func startSweep() {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.sweepInterval)
                if Task.isCancelled { return }
                await self.reconcile()
            }
        }
    }
}

/// The slice of camera-store behaviour `HubEngine` needs, abstracted so
/// the engine's reconcile logic can be unit-tested against an in-memory
/// fake (AGENTS.md §6 / §12). `CameraStore` provides the production
/// conformance below.
@MainActor
public protocol HubCameraHosting: AnyObject, Sendable {
    /// Every configured camera, as `(id, display name)`.
    var hostableCameraList: [HubCameraDescriptor] { get }
    /// True when this Mac holds the camera's password and can host it.
    func hasCredentials(for id: UUID) -> Bool
    /// Current connection status, or nil if no session exists yet.
    func connectionStatus(for id: UUID) -> ConnectionStatus?
    /// Open (or reuse) the camera's session and connect it.
    func connectCamera(_ id: UUID) async
    /// Tear down the camera's session.
    func disconnectCamera(_ id: UUID) async
}

/// Lightweight, `Sendable` view of a camera for the Hub engine — just
/// what it needs to connect and to name an unhostable camera, without
/// dragging the full `CameraEntry` across the seam.
public struct HubCameraDescriptor: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

extension CameraStore: HubCameraHosting {
    public var hostableCameraList: [HubCameraDescriptor] {
        cameras.map { HubCameraDescriptor(id: $0.id, displayName: $0.displayName) }
    }

    public func hasCredentials(for id: UUID) -> Bool {
        keychainStore.password(for: id) != nil
    }

    public func connectionStatus(for id: UUID) -> ConnectionStatus? {
        sessions[id]?.status
    }

    public func connectCamera(_ id: UUID) async {
        guard let session = session(for: id) else { return }
        await session.connect()
    }

    public func disconnectCamera(_ id: UUID) async {
        await sessions[id]?.disconnect()
    }
}

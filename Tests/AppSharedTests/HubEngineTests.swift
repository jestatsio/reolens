import Testing
import Foundation
@testable import AppShared

/// 0.7.0 — `HubEngine` is the always-on listener behind Reolens Hub
/// mode. These tests pin its reconcile contract against an in-memory
/// `HubCameraHosting` fake — no live `CameraStore`, Keychain, or
/// network (AGENTS.md §6 / §12):
///
/// - connect-all on first reconcile, hostable cameras only
/// - cameras without a password on this Mac are recorded as unhostable,
///   never silently skipped
/// - the keep-alive pass reconnects dropped/errored sessions but leaves
///   healthy ones alone
/// - a camera that syncs in later is adopted on the next pass
/// - `start()`/`stop()` flip `isRunning` and disconnect cleanly
@MainActor
@Suite("HubEngine")
struct HubEngineTests {

    /// In-memory stand-in for `CameraStore`'s Hub-hosting surface.
    /// Records connect/disconnect calls and flips status the way a real
    /// session would so reconcile's "already connected — leave it"
    /// branch is exercised.
    @MainActor
    final class FakeHubHost: HubCameraHosting {
        struct Cam {
            let id: UUID
            let name: String
            var hasPassword: Bool
            var status: ConnectionStatus?
        }

        var cams: [Cam]
        private(set) var connectCalls: [UUID] = []
        private(set) var disconnectCalls: [UUID] = []

        init(_ cams: [Cam]) { self.cams = cams }

        var hostableCameraList: [HubCameraDescriptor] {
            cams.map { HubCameraDescriptor(id: $0.id, displayName: $0.name) }
        }

        func hasCredentials(for id: UUID) -> Bool {
            cams.first { $0.id == id }?.hasPassword ?? false
        }

        func connectionStatus(for id: UUID) -> ConnectionStatus? {
            cams.first { $0.id == id }.flatMap { $0.status }
        }

        func connectCamera(_ id: UUID) async {
            connectCalls.append(id)
            if let i = cams.firstIndex(where: { $0.id == id }) {
                cams[i].status = .connected
            }
        }

        func disconnectCamera(_ id: UUID) async {
            disconnectCalls.append(id)
            if let i = cams.firstIndex(where: { $0.id == id }) {
                cams[i].status = .disconnected
            }
        }
    }

    private func cam(_ name: String, hasPassword: Bool = true, status: ConnectionStatus? = nil) -> FakeHubHost.Cam {
        FakeHubHost.Cam(id: UUID(), name: name, hasPassword: hasPassword, status: status)
    }

    /// Large sweep interval so the background timer never races an
    /// assertion — tests drive `reconcile()` directly.
    private func makeEngine(_ host: FakeHubHost) -> HubEngine {
        HubEngine(host: host, sweepInterval: .seconds(3600))
    }

    // MARK: - Connect-all

    @Test("reconcile connects every hostable camera")
    func reconcileConnectsAll() async {
        let host = FakeHubHost([cam("A"), cam("B"), cam("C")])
        let engine = makeEngine(host)

        await engine.reconcile()

        #expect(Set(host.connectCalls) == Set(host.cams.map(\.id)))
        #expect(engine.hostedCameraCount == 3)
        #expect(engine.unhostableCameraNames.isEmpty)
    }

    // MARK: - Unhostable cameras

    @Test("Cameras without a password are recorded, not connected")
    func unhostableCamerasAreSurfaced() async {
        let withPw = cam("Front Door", hasPassword: true)
        let noPw = cam("Garage", hasPassword: false)
        let host = FakeHubHost([withPw, noPw])
        let engine = makeEngine(host)

        await engine.reconcile()

        #expect(host.connectCalls == [withPw.id])
        #expect(engine.hostedCameraCount == 1)
        #expect(engine.unhostableCameraNames == ["Garage"])
        #expect(engine.configuredCameraCount == 2)
    }

    // MARK: - Keep-alive

    @Test("Keep-alive reconnects dropped sessions but leaves healthy ones")
    func reconcileReconnectsOnlyDropped() async {
        let healthy = cam("Healthy", status: .connected)
        let dropped = cam("Dropped", status: .error("lost"))
        let idle = cam("Idle", status: .disconnected)
        let host = FakeHubHost([healthy, dropped, idle])
        let engine = makeEngine(host)

        await engine.reconcile()

        #expect(!host.connectCalls.contains(healthy.id))
        #expect(host.connectCalls.contains(dropped.id))
        #expect(host.connectCalls.contains(idle.id))
        #expect(engine.hostedCameraCount == 3)
    }

    @Test("A camera mid-connect is not reconnected")
    func reconcileSkipsConnecting() async {
        let connecting = cam("Connecting", status: .connecting)
        let host = FakeHubHost([connecting])
        let engine = makeEngine(host)

        await engine.reconcile()

        #expect(host.connectCalls.isEmpty)
        #expect(engine.hostedCameraCount == 1)
    }

    // MARK: - Adoption

    @Test("A newly-synced camera is adopted on the next reconcile")
    func reconcileAdoptsNewCamera() async {
        let initial = cam("Initial")
        let host = FakeHubHost([initial])
        let engine = makeEngine(host)
        await engine.reconcile()

        let added = cam("Added")
        host.cams.append(added)
        await engine.reconcile()

        #expect(host.connectCalls.contains(added.id))
        #expect(engine.hostedCameraCount == 2)
    }

    // MARK: - Lifecycle

    @Test("start connects and marks running; stop disconnects and clears")
    func startStopLifecycle() async {
        let host = FakeHubHost([cam("A"), cam("B")])
        let engine = makeEngine(host)

        await engine.start()
        #expect(engine.isRunning)
        #expect(engine.hostedCameraCount == 2)

        await engine.stop()
        #expect(!engine.isRunning)
        #expect(engine.hostedCameraCount == 0)
        #expect(Set(host.disconnectCalls) == Set(host.cams.map(\.id)))
    }

    @Test("A second start while running is a no-op")
    func startIsIdempotent() async {
        let host = FakeHubHost([cam("A")])
        let engine = makeEngine(host)

        await engine.start()
        let countAfterFirst = host.connectCalls.count
        await engine.start()
        #expect(host.connectCalls.count == countAfterFirst)

        await engine.stop()
    }
}

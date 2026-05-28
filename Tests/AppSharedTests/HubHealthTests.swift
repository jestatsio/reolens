import Testing
import Foundation
@testable import AppShared

/// 0.7.0 — `HubHealth.evaluate` is the pure staleness decision behind the
/// "Hub offline" banner. Deterministic tests against a fixed `now` (no
/// CloudKit, no real clock):
///
/// - zero records → "no hub ever" (banner suppressed)
/// - a fresh heartbeat → online
/// - a stale heartbeat that was publishing → offline (alarming)
/// - a stale heartbeat that was gracefully off → roleOff (neutral)
/// - any one fresh hub among several → online
/// - clock-skew (future stamp) counts as fresh
/// - server modificationDate wins over client lastSeen
@Suite("HubHealth")
struct HubHealthTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 15 * 60

    /// Build a status whose *server* stamp is `ageSeconds` before `now`.
    private func status(
        id: String = "d",
        name: String = "Mac mini",
        ageSeconds: TimeInterval,
        relayOn: Bool = true,
        clientLastSeen: Date? = nil
    ) -> HubStatus {
        HubStatus(
            hubDeviceID: id,
            hubDeviceName: name,
            lastSeen: clientLastSeen ?? now.addingTimeInterval(-ageSeconds),
            appVersion: "0.7.0",
            relayPublisherEnabled: relayOn,
            serverModifiedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    @Test("No records → noHubEverConfigured")
    func empty() {
        #expect(HubHealth.evaluate(statuses: [], now: now, threshold: threshold) == .noHubEverConfigured)
    }

    @Test("Fresh heartbeat → online")
    func fresh() {
        let state = HubHealth.evaluate(statuses: [status(ageSeconds: 60)], now: now, threshold: threshold)
        #expect(state == .online(name: "Mac mini"))
    }

    @Test("Stale + was publishing → offline")
    func staleOffline() {
        let state = HubHealth.evaluate(statuses: [status(ageSeconds: 30 * 60, relayOn: true)], now: now, threshold: threshold)
        guard case .offline(let name, _) = state else {
            Issue.record("expected .offline, got \(state)")
            return
        }
        #expect(name == "Mac mini")
        #expect(state.showsOfflineBanner)
    }

    @Test("Stale + gracefully off → roleOff (neutral, no banner)")
    func staleRoleOff() {
        let state = HubHealth.evaluate(statuses: [status(ageSeconds: 30 * 60, relayOn: false)], now: now, threshold: threshold)
        #expect(state == .roleOff(name: "Mac mini"))
        #expect(!state.showsOfflineBanner)
    }

    @Test("Any one fresh hub among several → online")
    func oneFreshAmongStale() {
        let statuses = [
            status(id: "a", name: "Old Mac", ageSeconds: 60 * 60, relayOn: true),
            status(id: "b", name: "Live Mac", ageSeconds: 30, relayOn: true)
        ]
        let state = HubHealth.evaluate(statuses: statuses, now: now, threshold: threshold)
        #expect(state == .online(name: "Live Mac"))
    }

    @Test("Future-dated heartbeat (clock skew) counts as fresh")
    func futureStampIsFresh() {
        let state = HubHealth.evaluate(statuses: [status(ageSeconds: -120)], now: now, threshold: threshold)
        #expect(state == .online(name: "Mac mini"))
    }

    @Test("Staleness uses server modificationDate, not client lastSeen")
    func serverStampWins() {
        // Client lastSeen looks fresh, but the server stamp is stale —
        // the server stamp must win (skew-proof).
        let s = HubStatus(
            hubDeviceID: "d", hubDeviceName: "Mac mini",
            lastSeen: now.addingTimeInterval(-10),          // client says fresh
            appVersion: "0.7.0", relayPublisherEnabled: true,
            serverModifiedAt: now.addingTimeInterval(-30 * 60) // server says stale
        )
        #expect(HubHealth.evaluate(statuses: [s], now: now, threshold: threshold).showsOfflineBanner)
    }

    @Test("showsOfflineBanner is true only for .offline")
    func bannerGate() {
        #expect(!HubAvailability.unknown.showsOfflineBanner)
        #expect(!HubAvailability.noHubEverConfigured.showsOfflineBanner)
        #expect(!HubAvailability.online(name: "x").showsOfflineBanner)
        #expect(!HubAvailability.roleOff(name: "x").showsOfflineBanner)
        #expect(HubAvailability.offline(name: "x", lastSeen: now).showsOfflineBanner)
    }
}

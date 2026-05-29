import Foundation
import Observation
import OSLog

/// 0.7.0 — observable model behind the "Hub offline" banner. Reads the
/// `HubStatus` heartbeats every device's Hub publishes to the shared
/// private CloudKit database and decides whether to surface "Hub offline
/// — notifications paused".
///
/// The staleness decision is intentionally a *local* judgment, not a
/// push: a Hub that goes silent sends nothing, so "offline" can only be
/// inferred by comparing the heartbeat's age against a threshold. The
/// decision logic is a pure `nonisolated static func` so it unit-tests
/// without CloudKit, an actor hop, or a clock (mirrors
/// `CameraNotificationHealth`'s testable evaluator).
@MainActor
@Observable
public final class HubHealth {
    public static let shared = HubHealth()

    public private(set) var state: HubAvailability = .unknown

    /// 3× the 5-minute heartbeat cadence — absorbs a missed beat or
    /// CloudKit propagation lag without a false alarm.
    public static let stalenessThreshold: TimeInterval = 15 * 60

    @ObservationIgnored private let reader: CloudKitHubStatusReader
    @ObservationIgnored private let log = Logger(subsystem: "com.reolens.Reolens", category: "HubHealth")

    public init(reader: CloudKitHubStatusReader = CloudKitHubStatusReader()) {
        self.reader = reader
    }

    /// Fetch the latest heartbeats and recompute `state`. Call on
    /// foreground transitions (and optionally a short visible-screen
    /// timer). Cheap and deterministic — no push budget.
    public func refresh(now: Date = Date()) async {
        let statuses = await reader.fetchAll()
        state = Self.evaluate(statuses: statuses, now: now, threshold: Self.stalenessThreshold)
    }

    /// Pure staleness decision. Uses each record's CloudKit server
    /// `modificationDate` (skew-proof), falling back to the client
    /// `lastSeen` only when the server stamp is absent. A future-dated
    /// stamp (skew the other way) yields a non-positive age, which counts
    /// as fresh.
    public nonisolated static func evaluate(
        statuses: [HubStatus],
        now: Date,
        threshold: TimeInterval
    ) -> HubAvailability {
        guard !statuses.isEmpty else { return .noHubEverConfigured }

        func age(_ status: HubStatus) -> TimeInterval {
            now.timeIntervalSince(status.serverModifiedAt ?? status.lastSeen)
        }

        // The most-recently-seen hub overall (smallest age) decides
        // online vs offline — a single live Hub is enough.
        guard let mostRecent = statuses.min(by: { age($0) < age($1) }) else {
            return .noHubEverConfigured
        }

        if age(mostRecent) <= threshold {
            return .online(name: mostRecent.hubDeviceName)
        }

        // All heartbeats are stale. If every known hub had its publisher
        // switched off, this is a graceful "role off" (neutral, not
        // alarming); otherwise it's a genuine outage.
        if statuses.allSatisfy({ !$0.relayPublisherEnabled }) {
            return .roleOff(name: mostRecent.hubDeviceName)
        }
        return .offline(
            name: mostRecent.hubDeviceName,
            lastSeen: mostRecent.serverModifiedAt ?? mostRecent.lastSeen
        )
    }
}

/// Resolved hub availability for the UI.
public enum HubAvailability: Equatable, Sendable {
    /// CloudKit unreachable, or not yet fetched.
    case unknown
    /// Zero `HubStatus` records — the user never set up a Hub. Show
    /// nothing; don't nag.
    case noHubEverConfigured
    /// At least one Hub's heartbeat is fresh.
    case online(name: String)
    /// Every known Hub gracefully turned its publisher off — neutral.
    case roleOff(name: String)
    /// A Hub that was publishing has gone stale — a real outage.
    case offline(name: String, lastSeen: Date)

    /// Whether the alarming "Hub offline — notifications paused" banner
    /// should be shown. Only the genuine-outage case qualifies.
    public var showsOfflineBanner: Bool {
        if case .offline = self { return true }
        return false
    }
}

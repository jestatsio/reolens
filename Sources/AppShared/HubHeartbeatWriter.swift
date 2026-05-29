#if os(macOS)
import Foundation
import OSLog

/// 0.7.0 — drives the Hub-offline heartbeat on the macOS side. While
/// this Mac is the designated Reolens Hub it writes a `HubStatus` record
/// every ~5 minutes (plus immediately on start and on app-active), so
/// the user's other devices can tell the always-on listener is alive.
/// On a graceful stop it writes one final record marked
/// `relayPublisherEnabled = false`, which lets receivers show a neutral
/// "Hub role off" instead of an alarming "offline".
///
/// macOS-only: only a Mac is ever the Hub. The receiving/reading side
/// (`CloudKitHubStatusReader`, `HubHealth`) is cross-platform.
@MainActor
public final class HubHeartbeatWriter {
    public static let shared = HubHeartbeatWriter()

    /// 5-minute cadence. The receiver's staleness threshold is 3× this,
    /// so one or two missed beats (CloudKit propagation lag, brief sleep)
    /// don't trip a false "offline".
    private static let interval: Duration = .seconds(300)

    private let publisher = CloudKitHubStatusPublisher()
    private var timer: Task<Void, Never>?
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "HubStatus")

    private init() {}

    /// Begin periodic heartbeats: an immediate beat, then every interval.
    public func start() {
        beatNow()
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                if Task.isCancelled { return }
                self?.beatNow()
            }
        }
        log.info("Hub heartbeat started")
    }

    /// Stop heartbeats and write a final "going offline gracefully"
    /// record so receivers don't alarm.
    public func stop() {
        timer?.cancel()
        timer = nil
        let status = makeStatus(publisherEnabled: false)
        Task { await publisher.write(status) }
        log.info("Hub heartbeat stopped (wrote graceful-off)")
    }

    /// Write a heartbeat now. Also called from app-active transitions so
    /// a Hub that just woke refreshes its timestamp promptly.
    public func beatNow() {
        let status = makeStatus(publisherEnabled: MotionEventRelaySettings.publisherEnabled)
        Task { await publisher.write(status) }
    }

    private func makeStatus(publisherEnabled: Bool) -> HubStatus {
        HubStatus(
            hubDeviceID: HubDeviceIdentity.current(),
            hubDeviceName: Host.current().localizedName ?? "Mac",
            lastSeen: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            relayPublisherEnabled: publisherEnabled
        )
    }
}
#endif

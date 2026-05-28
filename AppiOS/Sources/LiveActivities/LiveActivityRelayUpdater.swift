import Foundation
import AppShared

/// 0.7.0 — drives the in-flight Live Activity from a **relayed** motion
/// event (one the Hub Mac published to CloudKit, delivered here by the
/// silent-push subscription), updating the activity **locally** through
/// `MotionEventActivityController`.
///
/// This is the architecturally honest realization of the roadmap's "Live
/// Activity push relay". A *true* ActivityKit push would require an APNs
/// provider signed with a `.p8` key — i.e. a server — which AGENTS.md §5
/// forbids. So instead the receiving device, already woken by the
/// existing CloudKit silent push, updates its own activity. The Live
/// Activity push token never leaves the device.
///
/// Host-app only: the Notification Service Extension runs in a separate
/// process and cannot hold the app's `Activity` handles, so it can only
/// enrich the banner — the activity update happens here, in
/// `AppDelegate.postLocalNotification(for:)`, after the user's
/// notification gates pass (mirroring the local Baichuan-driven path).
@available(iOS 26.0, *)
@MainActor
public enum LiveActivityRelayUpdater {

    /// Start or merge the hub's Live Activity from a relayed event.
    /// No-op for diagnostic "test" events.
    public static func apply(_ event: MotionEvent) async {
        guard event.detection != "test" else { return }

        // A relayed burst summary carries "<tag>.burst"; strip it back to
        // the base tag. Plain motion carries no AI tag.
        let base = event.detection.replacingOccurrences(of: ".burst", with: "")
        let tags: [String] = (base == "motion" || base.isEmpty) ? [] : [base]

        // The relayed snapshot is a CloudKit-staged file URL; read its
        // bytes so the activity can show the trigger frame. (The widget
        // has no network, so the controller persists this into the App
        // Group — see MotionEventActivityController.)
        let jpeg = event.snapshotFileURL.flatMap { try? Data(contentsOf: $0) }

        await MotionEventActivityController.shared.start(
            cameraID: event.cameraID,
            channel: event.channel,
            cameraName: event.cameraName ?? "Camera \(event.channel + 1)",
            aiTags: tags,
            triggerFrameJPEG: jpeg
        )
    }
}

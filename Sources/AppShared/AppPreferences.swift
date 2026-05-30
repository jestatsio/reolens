import Foundation
import Observation

/// 0.6.0 Slice 15 — UserDefaults-backed preferences extracted from
/// `CameraStore`.
///
/// `CameraStore` used to hold these directly, mixing UI prefs with
/// camera-list state and Keychain ops in a 775-LOC god object. This
/// type carves out the prefs slice so it can be tested in isolation
/// against a custom `UserDefaults` instance (no shared standard
/// pollution between test cases) and so future surfaces can read /
/// write prefs without depending on the whole CameraStore.
///
/// CameraStore embeds one of these and proxies its existing public
/// properties to the embedded instance — keeping the API stable so
/// the hundreds of callers across the app don't need to change.
@MainActor
@Observable
public final class AppPreferences {

    /// Storage backend. Injected so tests can use a `UserDefaults`
    /// pinned to a unique suite name per test.
    @ObservationIgnored
    private let defaults: UserDefaults

    /// Developer mode. Surfaces diagnostic UI (Raw JSON popovers,
    /// verbose log buttons, etc.) that would otherwise clutter the
    /// default view.
    public var developerMode: Bool {
        didSet {
            defaults.set(developerMode, forKey: Self.developerModeKey)
        }
    }

    /// Global "Show camera name on feed" preference. Default OFF
    /// because Reolink cameras typically burn their own OSD into the
    /// top-left of the frame; the app badge collides with it.
    public var showCameraNameOnFeed: Bool {
        didSet {
            defaults.set(showCameraNameOnFeed, forKey: Self.showCameraNameKey)
        }
    }

    /// Default quality for tap-to-play across both per-camera and
    /// All Recordings lists. The player sheet still exposes a toggle
    /// so the user can override per-clip; this is just the seed
    /// value. Defaults to `.low` because sub-stream first-frame
    /// latency on LAN is dramatically faster than main-stream and
    /// most users open recordings to triage motion events rather
    /// than to evaluate detail.
    public var defaultRecordingQuality: RecordingQuality {
        didSet {
            defaults.set(defaultRecordingQuality.rawValue, forKey: Self.defaultRecordingQualityKey)
        }
    }

    /// 0.6.0 — iOS / iPadOS "restore last camera on launch" memory.
    /// Set by the platform shell whenever the user navigates into a
    /// camera detail view; read on first appear to push that camera
    /// back onto the navigation stack so returning users don't re-
    /// pick the camera they were last viewing.
    ///
    /// Storage stays in UserDefaults (per-device) on purpose: every
    /// Apple device has a different "last camera I was watching" —
    /// the iPhone landing on the iPad's last selection would surprise
    /// users. macOS doesn't read this today because the macOS sidebar
    /// already preserves selection across launches via its own
    /// state-restoration plumbing.
    public var lastViewedCameraID: UUID? {
        didSet {
            if let id = lastViewedCameraID {
                defaults.set(id.uuidString, forKey: Self.lastViewedCameraKey)
            } else {
                defaults.removeObject(forKey: Self.lastViewedCameraKey)
            }
        }
    }

    /// 0.7.0 — "Run this Mac as a Reolens Hub" opt-in. When on, this
    /// Mac connects every camera and publishes motion events to the
    /// user's private CloudKit database even with no window open, so it
    /// can act as the always-on listener that drives notifications,
    /// Live Activities, and the hub-health heartbeat for the user's
    /// other devices. See `HubEngine` / `HubController`.
    ///
    /// Device-local on purpose (like `developerMode` and the menu-bar
    /// keys): each Mac decides independently whether it is the Hub —
    /// only one Mac per home should be, and that choice must never
    /// silently ride iCloud onto another machine. macOS is the only
    /// platform that acts on this flag; it lives here (cross-platform
    /// `AppShared`) so the gating logic stays testable in isolation.
    public var runAsHub: Bool {
        didSet {
            defaults.set(runAsHub, forKey: Self.runAsHubKey)
        }
    }

    /// 0.9.0 — "Run the Local HTTP API on this Mac" opt-in. When on, this
    /// Mac serves the read/control REST API (`docs/api/`) on the LAN,
    /// secured with a bearer token. Off by default. macOS-only (iOS/iPadOS
    /// can't hold a background listener) and surfaced only under Developer
    /// Mode for now — see `LocalAPIController`. Device-local on purpose,
    /// like `runAsHub`: each Mac decides independently and the choice never
    /// rides iCloud onto another machine.
    public var runLocalAPI: Bool {
        didSet {
            defaults.set(runLocalAPI, forKey: Self.runLocalAPIKey)
        }
    }

    /// 0.9.0 — TCP port the Local API binds to. Default 8443.
    public var localAPIPort: Int {
        didSet {
            defaults.set(localAPIPort, forKey: Self.localAPIPortKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.developerMode = defaults.bool(forKey: Self.developerModeKey)
        self.showCameraNameOnFeed = defaults.bool(forKey: Self.showCameraNameKey)
        self.defaultRecordingQuality = (defaults.string(forKey: Self.defaultRecordingQualityKey)
            .flatMap(RecordingQuality.init(rawValue:))) ?? .low
        self.lastViewedCameraID = defaults.string(forKey: Self.lastViewedCameraKey)
            .flatMap(UUID.init(uuidString:))
        self.runAsHub = defaults.bool(forKey: Self.runAsHubKey)
        self.runLocalAPI = defaults.bool(forKey: Self.runLocalAPIKey)
        let storedPort = defaults.integer(forKey: Self.localAPIPortKey)
        self.localAPIPort = storedPort == 0 ? 8443 : storedPort
    }

    // MARK: - Keys

    static let developerModeKey = "com.reolens.developerMode"
    static let showCameraNameKey = "com.reolens.showCameraNameOnFeed"
    static let defaultRecordingQualityKey = "com.reolens.defaultRecordingQuality"
    static let lastViewedCameraKey = "com.reolens.lastViewedCameraID"
    /// Public so the macOS Settings "Run as Hub" toggle can bind to it
    /// via `@AppStorage` (mirrors `MotionEventRelaySettings.publisherEnabledKey`).
    public static let runAsHubKey = "com.reolens.runAsHub"
    /// Public so the macOS Settings "Local API" toggle can bind via `@AppStorage`.
    public static let runLocalAPIKey = "com.reolens.runLocalAPI"
    public static let localAPIPortKey = "com.reolens.localAPIPort"

    // MARK: - Non-isolated peeks

    /// Read the developer-mode flag from outside the MainActor.
    /// Background logging hooks (`CameraSession` polling continuations,
    /// CloudKit subscriber observers) call this to decide whether to
    /// emit `.debug` log lines without hopping actors. Reads from
    /// `.standard` because that's where the live `CameraStore` —
    /// constructed without a custom `defaults` argument — writes.
    public static var developerModeIsOn: Bool {
        UserDefaults.standard.bool(forKey: developerModeKey)
    }

    /// Read the Run-as-Hub flag from outside the MainActor. Launch-time
    /// code (the `--hub` headless bootstrap) and the off-main-actor
    /// publish gate consult this to decide whether this Mac should
    /// behave as the always-on Hub without hopping actors. Reads from
    /// `.standard` for the same reason `developerModeIsOn` does — that's
    /// where the live `CameraStore` writes.
    public static var runAsHubIsOn: Bool {
        UserDefaults.standard.bool(forKey: runAsHubKey)
    }

    /// Read the Run-Local-API flag from outside the MainActor (launch-time
    /// lifecycle wiring). Reads `.standard` for the same reason the others do.
    public static var runLocalAPIIsOn: Bool {
        UserDefaults.standard.bool(forKey: runLocalAPIKey)
    }
}

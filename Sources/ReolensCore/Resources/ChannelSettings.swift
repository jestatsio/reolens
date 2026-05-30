import Foundation

/// Mutable per-channel settings the API exposes for read and partial update.
///
/// This is an intentionally focused v1 subset of the device's full settings
/// surface (the most useful, stable knobs). It can grow additively — new
/// optional fields are forward-compatible per AGENTS.md §7. (Which AI
/// categories a channel *supports* lives on ``ChannelCapabilities``;
/// enabling/disabling AI is a future additive field here.)
public struct ChannelSettings: Sendable, Codable, Hashable {
    /// Channel display name.
    public let name: String?
    /// On-screen-display overlay configuration.
    public let osd: OSDSettings?
    /// Whether Reolens notifications are enabled for this camera (the per-camera
    /// mute from `CameraNotificationPreferences`). This is a Reolens-level
    /// preference, not a device setting.
    public let notificationsEnabled: Bool?

    public init(
        name: String? = nil,
        osd: OSDSettings? = nil,
        notificationsEnabled: Bool? = nil
    ) {
        self.name = name
        self.osd = osd
        self.notificationsEnabled = notificationsEnabled
    }
}

/// On-screen-display overlay toggles.
public struct OSDSettings: Sendable, Codable, Hashable {
    /// Show the channel name overlay.
    public let showName: Bool?
    /// Show the date/time overlay.
    public let showDate: Bool?

    public init(showName: Bool? = nil, showDate: Bool? = nil) {
        self.showName = showName
        self.showDate = showDate
    }
}

/// A partial update to ``ChannelSettings``. Every field is optional; a nil
/// field means "leave unchanged". The adapter applies only the present fields.
public struct ChannelSettingsPatch: Sendable, Codable, Hashable {
    public var name: String?
    public var osd: OSDSettings?
    public var notificationsEnabled: Bool?

    public init(
        name: String? = nil,
        osd: OSDSettings? = nil,
        notificationsEnabled: Bool? = nil
    ) {
        self.name = name
        self.osd = osd
        self.notificationsEnabled = notificationsEnabled
    }
}

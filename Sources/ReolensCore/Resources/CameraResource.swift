import Foundation

/// A camera device (a standalone camera, an NVR, or a Home Hub) as the API
/// exposes it.
///
/// This is the clean public projection of an internal `CameraEntry` +
/// `DeviceInfo` + live connection status. Firmware-shaped fields (channel
/// bitmaps, hardware codes, session caps) are intentionally absent — consumers
/// see a stable shape.
public struct CameraResource: Sendable, Codable, Identifiable, Hashable {
    /// Opaque device id (the `CameraEntry` UUID, as a string).
    public let id: CameraID
    /// User-facing name, e.g. "Front Door" or "Home Hub Pro".
    public let displayName: String
    /// Whether this device is a camera, an NVR, or a hub.
    public let kind: DeviceKind
    /// Marketing model string when known, e.g. "RLC-810A".
    public let model: String?
    /// Firmware version when known.
    public let firmwareVersion: String?
    /// Number of channels this device exposes (1 for a single camera).
    public let channelCount: Int
    /// Whether the app currently holds a live connection to the device.
    public let online: Bool
    /// LAN host the device is reached at. Optional: included for authenticated,
    /// LAN-local consumers that need it (e.g. to build their own RTSP URL).
    /// Never logged at `.public` (AGENTS.md §11).
    public let host: String?

    public init(
        id: CameraID,
        displayName: String,
        kind: DeviceKind,
        model: String? = nil,
        firmwareVersion: String? = nil,
        channelCount: Int,
        online: Bool,
        host: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.channelCount = channelCount
        self.online = online
        self.host = host
    }
}

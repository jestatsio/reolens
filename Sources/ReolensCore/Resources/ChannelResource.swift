import Foundation

/// A single camera channel on a device (channel 0 on a standalone camera, or
/// one of many on an NVR / hub).
public struct ChannelResource: Sendable, Codable, Identifiable, Hashable {
    /// Zero-based channel index on the owning device.
    public let id: Int
    /// User-facing channel name when the device reports one.
    public let name: String?
    /// Whether the channel is currently online (a battery cam asleep reports
    /// offline until woken).
    public let online: Bool
    /// True for dual-lens models that present two physical lenses on one stream.
    public let isDualLens: Bool
    /// True for battery-powered cameras (which sleep between events).
    public let isBatteryPowered: Bool
    /// Battery telemetry, present only for battery cameras that have reported it.
    public let battery: BatteryInfo?
    /// What this channel supports, so consumers can disable controls gracefully.
    public let capabilities: ChannelCapabilities

    public init(
        id: Int,
        name: String? = nil,
        online: Bool,
        isDualLens: Bool = false,
        isBatteryPowered: Bool = false,
        battery: BatteryInfo? = nil,
        capabilities: ChannelCapabilities = ChannelCapabilities()
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.isDualLens = isDualLens
        self.isBatteryPowered = isBatteryPowered
        self.battery = battery
        self.capabilities = capabilities
    }
}

/// Battery telemetry for a battery-powered channel.
public struct BatteryInfo: Sendable, Codable, Hashable {
    /// Charge level, 0–100.
    public let percent: Int
    /// Whether the battery is actively charging.
    public let charging: Bool
    /// Whether an external power source is connected.
    public let pluggedIn: Bool

    public init(percent: Int, charging: Bool, pluggedIn: Bool) {
        self.percent = percent
        self.charging = charging
        self.pluggedIn = pluggedIn
    }
}

/// Capability flags for a channel, projected from the device's `GetAbility`
/// tree so consumers don't have to interpret Reolink's nested permission model.
public struct ChannelCapabilities: Sendable, Codable, Hashable {
    /// Pan/tilt/zoom is supported.
    public let ptz: Bool
    /// Two-way audio (talkback) is supported.
    public let talk: Bool
    /// AI detection categories the channel can report.
    public let ai: [DetectionKind]

    public init(ptz: Bool = false, talk: Bool = false, ai: [DetectionKind] = []) {
        self.ptz = ptz
        self.talk = talk
        self.ai = ai
    }
}

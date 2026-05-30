import Foundation

/// Configuration for the local HTTP facade.
///
/// The server is **opt-in and LAN-local** (AGENTS.md §5). `bindScope` decides
/// which peers are allowed: loopback-only (same-machine add-ons) or the local
/// RFC-1918 LAN. There is no public-internet binding.
public struct ServerConfig: Sendable {
    /// Which remote peers the server accepts.
    public enum BindScope: Sendable {
        /// Only `127.0.0.1` / `::1` — same-machine consumers.
        case loopback
        /// Loopback plus private RFC-1918 / link-local LAN ranges.
        case lan
    }

    /// TCP port to listen on.
    public var port: UInt16
    /// Allowed-peer scope.
    public var bindScope: BindScope

    public init(port: UInt16 = 8443, bindScope: BindScope = .lan) {
        self.port = port
        self.bindScope = bindScope
    }
}

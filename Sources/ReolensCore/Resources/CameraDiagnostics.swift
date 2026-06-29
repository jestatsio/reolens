import Foundation

/// Diagnostic snapshot of a single camera's live session — connection state,
/// the control plane in use, and recent activity. Returned by
/// ``CameraAPI/diagnostics(_:)`` and served at
/// `GET /v1/cameras/{id}/diagnostics`.
///
/// Reads current state without forcing a connect. All fields are credential-
/// and host-free (AGENTS.md §3): `lastError` is the same sanitized, user-facing
/// reason the app surfaces, never a raw URL.
public struct CameraDiagnostics: Sendable, Codable, Hashable {
    public let id: CameraID
    /// `"connected"` / `"connecting"` / `"disconnected"` / `"error"`.
    public let connectionStatus: String
    /// The control plane the session connected over: `"http"` / `"https"` /
    /// `"baichuan"`. `nil` when the camera isn't currently connected.
    public let controlTransport: String?
    /// Whether the camera is currently connected.
    public let online: Bool
    /// Number of live channels the session has discovered.
    public let channelCount: Int
    /// Motion / AI events recorded in this session so far.
    public let eventCount: Int
    /// The last connection-failure reason shown to the user, when the session
    /// is in an error state. Sanitized — no host or credentials.
    public let lastError: String?

    public init(
        id: CameraID,
        connectionStatus: String,
        controlTransport: String?,
        online: Bool,
        channelCount: Int,
        eventCount: Int,
        lastError: String?
    ) {
        self.id = id
        self.connectionStatus = connectionStatus
        self.controlTransport = controlTransport
        self.online = online
        self.channelCount = channelCount
        self.eventCount = eventCount
        self.lastError = lastError
    }
}

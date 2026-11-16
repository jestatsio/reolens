import Foundation

/// Liveness / summary information for the API instance.
///
/// Returned by ``CameraAPI/health()`` and served at `GET /v1/health`. The
/// HTTP route requires the bearer token like every other route except the
/// public contract document (`GET /v1/openapi.json`); an unauthenticated
/// probe still learns the server is up from the 401, without learning
/// anything about the fleet.
public struct SystemHealth: Sendable, Codable, Hashable {
    /// The contract version this instance serves, e.g. `"v1"`.
    public let apiVersion: String
    /// The Reolens app marketing version, when known.
    public let appVersion: String?
    /// Total number of cameras configured on this instance.
    public let cameraCount: Int
    /// How many of those are currently online.
    public let onlineCount: Int
    /// Whether this instance is running as a Reolens Hub, when applicable.
    public let hubRunning: Bool?

    public init(
        apiVersion: String = APIVersion.current,
        appVersion: String? = nil,
        cameraCount: Int,
        onlineCount: Int,
        hubRunning: Bool? = nil
    ) {
        self.apiVersion = apiVersion
        self.appVersion = appVersion
        self.cameraCount = cameraCount
        self.onlineCount = onlineCount
        self.hubRunning = hubRunning
    }
}

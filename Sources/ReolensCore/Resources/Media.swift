import Foundation

/// Raw image bytes plus their content type, returned by ``CameraAPI/snapshot(_:channel:)``.
///
/// Not `Codable`: the HTTP facade writes ``bytes`` directly to the response
/// body with the given ``contentType`` rather than wrapping them in the JSON
/// envelope.
public struct ImagePayload: Sendable, Hashable {
    /// Encoded image bytes (typically JPEG).
    public let bytes: Data
    /// MIME type, e.g. `"image/jpeg"`.
    public let contentType: String

    public init(bytes: Data, contentType: String = "image/jpeg") {
        self.bytes = bytes
        self.contentType = contentType
    }
}

/// A reference to a downloadable recording clip.
///
/// The facade may redirect a consumer to ``url`` or stream the bytes through
/// itself; either way the consumer gets a downloadable resource without ever
/// seeing camera credentials.
public struct DownloadRef: Sendable, Codable, Hashable {
    /// URL the clip can be fetched from (Reolens-hosted or a redirect target).
    public let url: URL?
    /// MIME type of the clip when known, e.g. `"video/mp4"`.
    public let contentType: String?
    /// Size in bytes when known.
    public let sizeBytes: Int64?

    public init(url: URL? = nil, contentType: String? = nil, sizeBytes: Int64? = nil) {
        self.url = url
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

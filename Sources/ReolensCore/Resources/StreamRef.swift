import Foundation

/// Descriptors for how to view a channel's live video.
///
/// v1 deliberately does **not** transcode video inside the API. Instead it
/// hands back references the consumer can open:
///
/// - ``mjpeg`` — a Reolens-hosted, token-authenticated MJPEG endpoint. The
///   universal fallback that "just works" in Home Assistant and browsers
///   without exposing camera credentials.
/// - ``rtsp`` — the direct RTSP URL. Populated **only** when the consumer
///   explicitly opts in (it embeds `user:password@host`, AGENTS.md §3/§4), and
///   omitted by default.
/// - ``hls`` — reserved for a future HLS-transcoding phase; nil in v1.
public struct StreamRef: Sendable, Codable, Hashable {
    /// Which encoded stream these references point at.
    public let quality: StreamQuality
    /// Video codec when known, `"h264"` or `"h265"`.
    public let codec: String?
    /// Reolens-hosted MJPEG endpoint (token-authed, no camera credentials in URL).
    public let mjpeg: URL?
    /// Direct RTSP URL. Embeds credentials — only set on explicit opt-in.
    public let rtsp: URL?
    /// HLS playlist URL. Reserved for a future phase; nil in v1.
    public let hls: URL?

    public init(
        quality: StreamQuality,
        codec: String? = nil,
        mjpeg: URL? = nil,
        rtsp: URL? = nil,
        hls: URL? = nil
    ) {
        self.quality = quality
        self.codec = codec
        self.mjpeg = mjpeg
        self.rtsp = rtsp
        self.hls = hls
    }
}

import Foundation

/// Parameters for a recordings search. Maps to the
/// `?from=&to=&types=&cursor=&limit=` query string on the recordings endpoint.
public struct RecordingQuery: Sendable, Codable, Hashable {
    /// Start of the time window (inclusive).
    public var from: Date
    /// End of the time window (inclusive).
    public var to: Date
    /// Restrict to clips triggered by these detection categories; nil = all.
    public var types: [DetectionKind]?
    /// Opaque pagination cursor from a previous ``RecordingPage/nextCursor``.
    public var cursor: String?
    /// Maximum items to return in this page. The adapter applies a sane cap.
    public var limit: Int?

    public init(
        from: Date,
        to: Date,
        types: [DetectionKind]? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.types = types
        self.cursor = cursor
        self.limit = limit
    }
}

/// Filter applied to the live event stream. An all-nil filter receives every
/// event from every camera.
public struct EventFilter: Sendable, Codable, Hashable {
    /// Only events from this camera; nil = all cameras.
    public var cameraID: CameraID?
    /// Only events on this channel; nil = all channels.
    public var channel: Int?
    /// Only events whose detection is in this set; nil = all detections (and
    /// motion edges, which have no detection).
    public var detections: [DetectionKind]?

    public init(cameraID: CameraID? = nil, channel: Int? = nil, detections: [DetectionKind]? = nil) {
        self.cameraID = cameraID
        self.channel = channel
        self.detections = detections
    }

    /// Convenience: an unfiltered subscription to every event.
    public static var all: EventFilter { EventFilter() }

    /// Whether a given event passes this filter.
    public func matches(_ event: EventResource) -> Bool {
        if let cameraID, event.cameraID != cameraID { return false }
        if let channel, event.channel != channel { return false }
        if let detections, let d = event.detection, !detections.contains(d) { return false }
        // Events with no detection (motion edges) pass unless a detection
        // allow-list is set, in which case they are filtered out.
        if let detections, event.detection == nil, !detections.isEmpty { return false }
        return true
    }
}

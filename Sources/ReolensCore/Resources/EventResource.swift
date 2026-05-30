import Foundation

/// A live motion / AI event, delivered over the `/v1/events` SSE stream and
/// also returned from any future event-history endpoint.
public struct EventResource: Sendable, Codable, Identifiable, Hashable {
    /// Unique id for this event occurrence.
    public let id: String
    /// The camera the event fired on.
    public let cameraID: CameraID
    /// The channel index within that camera.
    public let channel: Int
    /// Whether this is a motion edge or an AI classification.
    public let kind: EventKind
    /// The AI category, when `kind == .ai` (else nil).
    public let detection: DetectionKind?
    /// When the event was observed.
    public let timestamp: Date

    public init(
        id: String,
        cameraID: CameraID,
        channel: Int,
        kind: EventKind,
        detection: DetectionKind? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.cameraID = cameraID
        self.channel = channel
        self.kind = kind
        self.detection = detection
        self.timestamp = timestamp
    }
}

/// The flavor of a live event.
public enum EventKind: String, Sendable, Codable, Hashable {
    /// Motion began.
    case motionStart
    /// Motion ended.
    case motionStop
    /// An AI classification fired (see `EventResource.detection`).
    case ai
}

import Foundation

/// A recorded clip on the device's storage.
///
/// Clean projection of a Reolink `SearchFile`: the `trigger` bitfield is
/// decoded into `triggers`, and timestamps are real `Date`s rather than the
/// wire's split date/time components.
public struct RecordingResource: Sendable, Codable, Identifiable, Hashable {
    /// Opaque id locating this clip (treat as opaque; pass to the download endpoint).
    public let id: RecordingID
    /// Clip start time.
    public let start: Date
    /// Clip end time.
    public let end: Date
    /// Duration in seconds (`end - start`, surfaced for convenience).
    public let durationSeconds: Double
    /// Detection categories that triggered the recording (decoded bitfield).
    public let triggers: [DetectionKind]
    /// File size in bytes, when reported.
    public let sizeBytes: Int64?
    /// Frame width in pixels, when reported.
    public let width: Int?
    /// Frame height in pixels, when reported.
    public let height: Int?

    public init(
        id: RecordingID,
        start: Date,
        end: Date,
        triggers: [DetectionKind] = [],
        sizeBytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.durationSeconds = max(0, end.timeIntervalSince(start))
        self.triggers = triggers
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
    }
}

/// One page of recordings plus an optional cursor to fetch the next page.
public struct RecordingPage: Sendable, Codable, Hashable {
    public let items: [RecordingResource]
    /// Pass back as `?cursor=` to fetch the next page; nil when exhausted.
    public let nextCursor: String?

    public init(items: [RecordingResource], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

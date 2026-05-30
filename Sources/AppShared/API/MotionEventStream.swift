import Foundation

/// Process-wide fan-out of live motion / AI events to API subscribers — the
/// source behind the Reolens API's `/v1/events` SSE stream.
///
/// Every `CameraSession` publishes each Baichuan event here in addition to its
/// existing notification fan-out (`EventNotifier`). Subscribers receive a
/// neutral ``Event`` (no `ReolensCore` types) so this stays decoupled from the
/// public API surface; `LiveCameraAPI` maps these to `EventResource`.
///
/// An actor so the continuation registry is race-free. Multiple independent
/// subscribers (e.g. several connected HTTP clients) each get their own stream.
public actor MotionEventStream {
    public static let shared = MotionEventStream()

    public init() {}

    /// A live event, in neutral terms.
    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case motionStart
            case motionStop
            /// AI classification with the raw Reolink tag (e.g. "people").
            case ai(String)
        }
        public let cameraID: UUID
        public let channel: Int
        public let kind: Kind
        public let timestamp: Date

        public init(cameraID: UUID, channel: Int, kind: Kind, timestamp: Date) {
            self.cameraID = cameraID
            self.channel = channel
            self.kind = kind
            self.timestamp = timestamp
        }
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    /// Broadcast an event to every active subscriber.
    public func publish(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Open a new subscription. The returned stream finishes when the consumer
    /// stops iterating or its task is cancelled; the continuation is then
    /// unregistered automatically.
    public func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// Current subscriber count (used by tests / diagnostics).
    public var subscriberCount: Int { continuations.count }

    private func unsubscribe(_ id: UUID) {
        continuations[id] = nil
    }
}

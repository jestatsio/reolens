import Foundation
import Testing
import ReolensCore
@testable import ReolensServer

/// The SSE heartbeat merge: quiet fleets must not lose their event
/// streams to idle timeouts (PR #88 review). Heartbeats are SSE
/// comments, ignored by every consumer.
@Suite("SSE heartbeat lines")
struct SSEHeartbeatTests {

    private actor LineBox {
        private(set) var lines: [String] = []
        private(set) var finished = false
        func add(_ line: String) { lines.append(line) }
        func markFinished() { finished = true }
    }

    /// Collect merged lines in the background so assertions can poll
    /// with a deadline instead of hanging on a broken merge.
    private func collect(_ lines: AsyncStream<String>, into box: LineBox) -> Task<Void, Never> {
        Task {
            for await line in lines {
                await box.add(line)
            }
            await box.markFinished()
        }
    }

    @Test("heartbeats flow while the fleet is quiet, and events pass through as data lines")
    func heartbeatAndEvents() async throws {
        var continuation: AsyncStream<EventResource>.Continuation!
        let events = AsyncStream<EventResource> { continuation = $0 }
        let box = LineBox()
        let task = collect(
            ReolensAPIServer.sseLines(events: events, heartbeatInterval: .milliseconds(30)),
            into: box
        )
        defer { task.cancel() }

        continuation.yield(EventResource(
            id: "E1", cameraID: "CAM-1", channel: 0, kind: .ai,
            detection: .person, timestamp: Date(timeIntervalSince1970: 42)
        ))

        var seen: [String] = []
        for _ in 0..<60 {
            seen = await box.lines
            if seen.contains(where: { $0.hasPrefix("data:") }), seen.contains(": heartbeat") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        continuation.finish()
        #expect(seen.contains { $0.hasPrefix("data:") && $0.contains(#""person""#) })
        #expect(seen.contains(": heartbeat"))
    }

    @Test("the merged stream finishes when the event stream finishes")
    func finishesWithEvents() async throws {
        let events = AsyncStream<EventResource> { $0.finish() }
        let box = LineBox()
        let task = collect(
            ReolensAPIServer.sseLines(events: events, heartbeatInterval: .seconds(60)),
            into: box
        )
        defer { task.cancel() }

        var finished = false
        for _ in 0..<60 where !finished {
            finished = await box.finished
            if !finished { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(finished)
    }
}

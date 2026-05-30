import Foundation
import Network

/// async/await wrappers over `NWConnection`'s callback API. `NWConnection`
/// isn't `Sendable`; callers keep it inside one connection-handling task and
/// never share it across tasks.
extension NWConnection {
    /// Receive up to `maxLength` bytes. Returns the bytes plus whether the peer
    /// has closed its side (`isComplete`).
    func receiveData(maxLength: Int) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            self.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }

    /// Send all of `data`, resolving once the bytes are processed.
    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

/// Crosses a non-`Sendable` `NWConnection` into a child task. Network.framework
/// connections are internally thread-safe (they marshal to their own queue), so
/// the unchecked conformance is sound for our single-owner usage.
struct ConnectionBox: @unchecked Sendable {
    let connection: NWConnection
}

/// One-shot latch so a listener's `stateUpdateHandler` resumes the `start()`
/// continuation exactly once. The handler is serialized on the listener queue.
final class OnceFlag: @unchecked Sendable {
    private var done = false
    /// Returns true the first time only.
    func set() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

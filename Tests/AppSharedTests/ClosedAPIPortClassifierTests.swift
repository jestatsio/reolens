import Testing
import Foundation
import ReolinkAPI
@testable import AppShared

/// GitHub #76 — newer Reolink firmware (3.1.0.x, e.g. CX410) ships with the
/// HTTP/HTTPS API ports disabled by default; only Baichuan (9000) stays
/// open. A user adding such a camera over the default HTTP:80 transport got
/// a generic "Couldn't reach the camera" with no idea why. `CameraSession`
/// now classifies a *refused port* (`URLError.cannotConnectToHost`) and
/// surfaces an actionable "enable HTTP/HTTPS" message + transparently
/// retries over HTTPS:443. Pin the pure decision logic so it can't regress.
@Suite("CameraSession closed-API-port classifier (#76)")
struct ClosedAPIPortClassifierTests {

    // MARK: - suggestsClosedAPIPort

    @Test("cannotConnectToHost (raw URLError) means the port is refused")
    func refusedRawURLError() {
        #expect(CameraSession.suggestsClosedAPIPort(URLError(.cannotConnectToHost)))
    }

    @Test("cannotConnectToHost wrapped in ReolinkClientError.transport is still a refused port")
    func refusedWrappedTransport() {
        let err = ReolinkClientError.transport(URLError(.cannotConnectToHost))
        #expect(CameraSession.suggestsClosedAPIPort(err))
    }

    @Test("timed out is NOT a closed port — host is unreachable, not refusing")
    func timeoutIsNotClosedPort() {
        #expect(!CameraSession.suggestsClosedAPIPort(URLError(.timedOut)))
    }

    @Test("cannotFindHost is NOT a closed port — wrong IP / host not found")
    func cannotFindHostIsNotClosedPort() {
        #expect(!CameraSession.suggestsClosedAPIPort(URLError(.cannotFindHost)))
    }

    @Test("an auth failure is never classified as a closed port")
    func authFailureIsNotClosedPort() {
        let err = ReolinkClientError.http(status: 401, body: nil)
        #expect(!CameraSession.suggestsClosedAPIPort(err))
    }

    // MARK: - connectionFailureMessage

    @Test("a refused port yields the actionable enable-the-port message")
    func refusedPortMessageIsActionable() {
        let message = CameraSession.connectionFailureMessage(for: URLError(.cannotConnectToHost))
        #expect(message.contains("Port Settings"))
        #expect(message.contains("HTTP/HTTPS"))
    }

    @Test("a generic transport failure yields the generic reachability message")
    func genericFailureMessage() {
        let message = CameraSession.connectionFailureMessage(for: URLError(.timedOut))
        #expect(message.contains("Couldn't reach the camera"))
        #expect(!message.contains("Port Settings"))
    }

    @Test("failure messages never leak a host or credentials (AGENTS.md §3)")
    func messagesAreCredentialFree() {
        for error in [URLError(.cannotConnectToHost), URLError(.timedOut)] as [any Error] {
            let message = CameraSession.connectionFailureMessage(for: error)
            #expect(!message.contains("192.168"))
            #expect(!message.contains("admin"))
            #expect(!message.contains("@"))
        }
    }
}

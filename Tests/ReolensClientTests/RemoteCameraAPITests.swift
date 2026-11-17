import Foundation
import Testing
import ReolensCore
@testable import ReolensClient

/// Records requests and answers from a handler. No sockets (§12).
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [ClientRequest] = []
    var handler: @Sendable (ClientRequest) throws -> ClientResponse = { _ in ClientResponse(status: 200) }
    var lines: [String] = []

    private func record(_ request: ClientRequest) {
        lock.withLock { requests.append(request) }
    }

    func send(_ request: ClientRequest) async throws -> ClientResponse {
        record(request)
        return try handler(request)
    }

    func streamLines(_ request: ClientRequest) -> AsyncThrowingStream<String, any Error> {
        record(request)
        let lines = self.lines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    var lastRequest: ClientRequest? {
        lock.withLock { requests.last }
    }
}

private func envelope<T: Codable & Sendable>(_ data: T, meta: APIMeta? = nil) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(APIResponse(data: data, error: nil, meta: meta))
}

private func client(_ stub: StubTransport, token: String? = "test-token") -> RemoteCameraAPI {
    RemoteCameraAPI(baseURL: URL(string: "http://127.0.0.1:8443")!, token: token, transport: stub)
}

@Suite("RemoteCameraAPI")
struct RemoteCameraAPITests {
    @Test("cameras() hits /v1/cameras with the bearer token and decodes the envelope")
    func cameras() async throws {
        let stub = StubTransport()
        let expected = [CameraResource(id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true)]
        stub.handler = { _ in ClientResponse(status: 200, headers: ["content-type": "application/json"], body: try envelope(expected)) }

        let result = try await client(stub).cameras()
        #expect(result == expected)
        #expect(stub.lastRequest?.method == "GET")
        #expect(stub.lastRequest?.url.path == "/v1/cameras")
        #expect(stub.lastRequest?.header("authorization") == "Bearer test-token")
    }

    @Test("a missing token sends no Authorization header (server answers 401)")
    func noToken() async throws {
        let stub = StubTransport()
        stub.handler = { _ in ClientResponse(status: 401, body: Data(#"{"error":{"code":"unauthorized","message":"Missing or invalid API token","status":401}}"#.utf8)) }
        await #expect(throws: APIError.self) { try await client(stub, token: nil).health() }
        #expect(stub.lastRequest?.header("authorization") == nil)
    }

    @Test("server error envelopes throw the decoded APIError")
    func errorEnvelope() async throws {
        let stub = StubTransport()
        stub.handler = { _ in ClientResponse(status: 404, body: Data(#"{"error":{"code":"camera_not_found","message":"No camera with id X","status":404}}"#.utf8)) }
        do {
            _ = try await client(stub).camera("X")
            Issue.record("expected throw")
        } catch let error as APIError {
            #expect(error.code == "camera_not_found")
            #expect(error.status == 404)
        }
    }

    @Test("transport failure becomes unreachable, never a camera error")
    func unreachable() async throws {
        let stub = StubTransport()
        stub.handler = { _ in throw ReolensClientError.unreachable("Cannot reach the Reolens server") }
        await #expect(throws: ReolensClientError.self) { try await client(stub).cameras() }
    }

    @Test("snapshot returns raw bytes and the response content type")
    func snapshot() async throws {
        let stub = StubTransport()
        stub.handler = { _ in ClientResponse(status: 200, headers: ["content-type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF])) }
        let image = try await client(stub).snapshot("CAM-1", channel: 2)
        #expect(image.bytes == Data([0xFF, 0xD8, 0xFF]))
        #expect(image.contentType == "image/jpeg")
        #expect(stub.lastRequest?.url.path == "/v1/cameras/CAM-1/channels/2/snapshot")
    }

    @Test("ptz POSTs the command JSON and accepts an empty 202")
    func ptz() async throws {
        let stub = StubTransport()
        stub.handler = { _ in ClientResponse(status: 202) }
        try await client(stub).ptz("CAM-1", channel: 0, PTZCommand(op: .left, speed: 16))
        let body = try #require(stub.lastRequest?.body)
        let decoded = try JSONDecoder().decode(PTZCommand.self, from: body)
        #expect(decoded.op == .left)
        #expect(decoded.speed == 16)
        #expect(stub.lastRequest?.method == "POST")
    }

    @Test("recordings encode the time window + types and surface meta.nextCursor")
    func recordings() async throws {
        let stub = StubTransport()
        let item = RecordingResource(id: "REC-1", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 160), triggers: [.person])
        stub.handler = { _ in ClientResponse(status: 200, body: try envelope([item], meta: APIMeta(count: 1, nextCursor: "abc"))) }
        let page = try await client(stub).recordings(
            "CAM-1", channel: 0,
            RecordingQuery(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600), types: [.person], limit: 50)
        )
        #expect(page.items == [item])
        #expect(page.nextCursor == "abc")
        let query = stub.lastRequest?.url.query ?? ""
        #expect(query.contains("types=person"))
        #expect(query.contains("limit=50"))
        #expect(query.contains("from="))
    }

    @Test("events parse SSE data lines, skipping comments and blanks")
    func events() async throws {
        let stub = StubTransport()
        let eventJSON = #"{"id":"E1","cameraID":"CAM-1","channel":0,"kind":"ai","detection":"person","timestamp":"2026-06-01T10:00:00Z"}"#
        stub.lines = [": heartbeat", "", "data: \(eventJSON)", "data: not-json", eventJSON]
        var received: [EventResource] = []
        for await event in client(stub).events(.all) {
            received.append(event)
        }
        #expect(received.count == 2)
        #expect(received.first?.detection == .person)
        #expect(stub.lastRequest?.url.path == "/v1/events")
    }

    @Test("diagnostics decode the 0.10.0 typed enums from identical wire strings")
    func diagnostics() async throws {
        let stub = StubTransport()
        stub.handler = { _ in ClientResponse(status: 200, body: Data(#"{"data":{"id":"CAM-1","connectionStatus":"connected","controlTransport":"baichuan","online":true,"channelCount":1,"eventCount":3}}"#.utf8)) }
        let diag = try await client(stub).diagnostics("CAM-1")
        #expect(diag.connectionStatus == .connected)
        #expect(diag.controlTransport == .baichuan)
    }
}

@Suite("URLSessionTransport request shapes")
struct TransportRequestTests {
    @Test("streaming requests disable the idle timeout so quiet SSE streams are not reaped")
    func streamingTimeout() {
        let request = ClientRequest(method: "GET", url: URL(string: "http://127.0.0.1:8443/v1/events")!)
        #expect(URLSessionTransport.streamingRequest(request).timeoutInterval == .infinity)
    }
}

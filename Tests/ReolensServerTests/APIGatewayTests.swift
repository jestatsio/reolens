import Foundation
import Testing
import ReolensCore
@testable import ReolensServer

private let jsonDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

/// Builds a request with a bearer token by default.
private func request(
    _ method: String,
    _ path: String,
    query: [String: String] = [:],
    token: String? = "secret",
    body: Data = Data()
) -> HTTPRequest {
    var headers: [String: String] = [:]
    if let token { headers["authorization"] = "Bearer \(token)" }
    return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
}

private func responseOf(_ outcome: APIGateway.Outcome) -> HTTPResponse? {
    if case .response(let response) = outcome { return response }
    return nil
}

@Suite("APIGateway — auth")
struct GatewayAuthTests {
    let gateway = APIGateway(api: FakeCameraAPI.oneCamera, token: "secret")

    @Test("only openapi is public; health requires auth")
    func publicRoutes() async throws {
        let openapi = responseOf(await gateway.handle(request("GET", "/v1/openapi.json", token: nil)))
        #expect(openapi?.status == 200)
        // health is no longer public — no pre-auth fleet enumeration (H4).
        let healthNoToken = responseOf(await gateway.handle(request("GET", "/v1/health", token: nil)))
        #expect(healthNoToken?.status == 401)
        let healthAuthed = responseOf(await gateway.handle(request("GET", "/v1/health")))
        #expect(healthAuthed?.status == 200)
    }

    @Test("a nil configured token locks out protected routes (fail-closed)")
    func nilTokenFailsClosed() async throws {
        let locked = APIGateway(api: FakeCameraAPI.oneCamera, token: nil)
        // Even with a bearer header, no configured token → 401 (C1).
        let response = responseOf(await locked.handle(request("GET", "/v1/cameras", token: "anything")))
        #expect(response?.status == 401)
        // openapi stays reachable (public, carries no camera data).
        let openapi = responseOf(await locked.handle(request("GET", "/v1/openapi.json", token: nil)))
        #expect(openapi?.status == 200)
    }

    @Test("protected route without a token is 401")
    func missingToken() async throws {
        let response = responseOf(await gateway.handle(request("GET", "/v1/cameras", token: nil)))
        #expect(response?.status == 401)
    }

    @Test("protected route with the wrong token is 401")
    func wrongToken() async throws {
        let response = responseOf(await gateway.handle(request("GET", "/v1/cameras", token: "nope")))
        #expect(response?.status == 401)
    }

    @Test("constant-time compare matches only identical tokens")
    func constantTime() {
        #expect(APIGateway.constantTimeEqual("abc123", "abc123"))
        #expect(!APIGateway.constantTimeEqual("abc123", "abc124"))
        #expect(!APIGateway.constantTimeEqual("abc", "abc123"))
    }
}

@Suite("APIGateway — routing")
struct GatewayRoutingTests {
    let gateway = APIGateway(api: FakeCameraAPI.oneCamera, token: "secret")

    @Test("GET /v1/cameras returns the list with a count")
    func listCameras() async throws {
        let response = try #require(responseOf(await gateway.handle(request("GET", "/v1/cameras"))))
        #expect(response.status == 200)
        let decoded = try jsonDecoder.decode(APIResponse<[CameraResource]>.self, from: response.body)
        #expect(decoded.data?.count == 1)
        #expect(decoded.meta?.count == 1)
        #expect(decoded.data?.first?.id == "CAM-1")
    }

    @Test("GET /v1/cameras/{id} maps a not-found to 404 + stable code")
    func unknownCamera() async throws {
        let response = try #require(responseOf(await gateway.handle(request("GET", "/v1/cameras/CAM-X"))))
        #expect(response.status == 404)
        struct E: Decodable { let error: APIError }
        let decoded = try jsonDecoder.decode(E.self, from: response.body)
        #expect(decoded.error.code == "camera_not_found")
    }

    @Test("GET snapshot returns JPEG bytes")
    func snapshot() async throws {
        let response = try #require(responseOf(await gateway.handle(request("GET", "/v1/cameras/CAM-1/channels/0/snapshot"))))
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "image/jpeg")
        #expect(response.body == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test("snapshot of an unreachable camera maps to 502")
    func snapshotUnreachable() async throws {
        var fake = FakeCameraAPI.oneCamera
        fake.unreachableCameraID = "CAM-1"
        let gateway = APIGateway(api: fake, token: "secret")
        let response = try #require(responseOf(await gateway.handle(request("GET", "/v1/cameras/CAM-1/channels/0/snapshot"))))
        #expect(response.status == 502)
    }

    @Test("POST ptz with a valid body is 202; bad body is 400; bad channel is 400")
    func ptz() async throws {
        let good = responseOf(await gateway.handle(
            request("POST", "/v1/cameras/CAM-1/channels/0/ptz", body: Data(#"{"op":"left","speed":32}"#.utf8))
        ))
        #expect(good?.status == 202)

        let badBody = responseOf(await gateway.handle(
            request("POST", "/v1/cameras/CAM-1/channels/0/ptz", body: Data("not json".utf8))
        ))
        #expect(badBody?.status == 400)

        let badChannel = responseOf(await gateway.handle(
            request("POST", "/v1/cameras/CAM-1/channels/x/ptz", body: Data(#"{"op":"left"}"#.utf8))
        ))
        #expect(badChannel?.status == 400)
    }

    @Test("recordings requires from/to and returns items")
    func recordings() async throws {
        var fake = FakeCameraAPI.oneCamera
        fake.recordingItems = [RecordingResource(
            id: "REC-1",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_030),
            triggers: [.person]
        )]
        let gateway = APIGateway(api: fake, token: "secret")

        let missing = responseOf(await gateway.handle(request("GET", "/v1/cameras/CAM-1/channels/0/recordings")))
        #expect(missing?.status == 400)

        let ok = try #require(responseOf(await gateway.handle(request(
            "GET", "/v1/cameras/CAM-1/channels/0/recordings",
            query: ["from": "2026-05-30T00:00:00Z", "to": "2026-05-30T23:59:59Z"]
        ))))
        #expect(ok.status == 200)
        let decoded = try jsonDecoder.decode(APIResponse<[RecordingResource]>.self, from: ok.body)
        #expect(decoded.data?.first?.id == "REC-1")
    }

    @Test("settings GET and PATCH round-trip the patch")
    func settings() async throws {
        let get = responseOf(await gateway.handle(request("GET", "/v1/cameras/CAM-1/channels/0/settings")))
        #expect(get?.status == 200)

        let patched = try #require(responseOf(await gateway.handle(request(
            "PATCH", "/v1/cameras/CAM-1/channels/0/settings",
            body: Data(#"{"name":"Renamed"}"#.utf8)
        ))))
        #expect(patched.status == 200)
        let decoded = try jsonDecoder.decode(APIResponse<ChannelSettings>.self, from: patched.body)
        #expect(decoded.data?.name == "Renamed")
    }

    @Test("unknown path is 404")
    func unknownPath() async throws {
        let response = responseOf(await gateway.handle(request("GET", "/v1/nonsense")))
        #expect(response?.status == 404)
    }

    @Test("recording download never returns a credential-bearing URL")
    func downloadStripsURL() async throws {
        let response = try #require(responseOf(await gateway.handle(
            request("GET", "/v1/cameras/CAM-1/channels/0/recordings/clip.mp4/download")
        )))
        #expect(response.status == 200)
        let decoded = try jsonDecoder.decode(APIResponse<DownloadRef>.self, from: response.body)
        // The fake returns a camera URL; the gateway must strip it (C2).
        #expect(decoded.data?.url == nil)
        #expect(decoded.data?.contentType == "video/mp4")
    }

    @Test("events returns a stream, filtered by query")
    func events() async throws {
        var fake = FakeCameraAPI.oneCamera
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        fake.emittedEvents = [
            EventResource(id: "E1", cameraID: "CAM-1", channel: 0, kind: .ai, detection: .person, timestamp: t),
            EventResource(id: "E2", cameraID: "CAM-2", channel: 0, kind: .ai, detection: .vehicle, timestamp: t),
        ]
        let gateway = APIGateway(api: fake, token: "secret")

        let outcome = await gateway.handle(request("GET", "/v1/events", query: ["cameraId": "CAM-1"]))
        guard case .events(let stream) = outcome else {
            Issue.record("expected an events stream")
            return
        }
        var received: [EventResource] = []
        for await event in stream { received.append(event) }
        #expect(received.map(\.id) == ["E1"])
    }
}

@Suite("APIGateway — query decoding")
struct GatewayQueryTests {
    @Test("recordingQuery parses dates, types, limit")
    func recordingQuery() throws {
        let query = try #require(APIGateway.recordingQuery(from: [
            "from": "2026-05-30T00:00:00Z",
            "to": "2026-05-30T12:00:00Z",
            "types": "person,vehicle",
            "limit": "25",
        ]))
        #expect(query.types == [.person, .vehicle])
        #expect(query.limit == 25)
        #expect(APIGateway.recordingQuery(from: ["from": "2026-05-30T00:00:00Z"]) == nil)
    }

    @Test("eventFilter parses camera/channel/detections")
    func eventFilter() {
        let filter = APIGateway.eventFilter(from: ["cameraId": "CAM-1", "channel": "2", "detections": "person"])
        #expect(filter.cameraID == "CAM-1")
        #expect(filter.channel == 2)
        #expect(filter.detections == [.person])
    }
}

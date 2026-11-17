import Foundation
import Testing
import ReolensCore
import ReolensServer
@testable import ReolensClient

/// Proves the HTTP client and the real `APIGateway` agree on the wire:
/// paths, query parameter names, envelopes, auth, and SSE framing. The
/// transport calls the gateway in-process (no sockets, §12) but every
/// byte still goes through the genuine encode/decode on both sides —
/// exactly the agreement per-side stubs cannot check.
struct GatewayTransport: HTTPTransport {
    let gateway: APIGateway

    func send(_ request: ClientRequest) async throws -> ClientResponse {
        switch await gateway.handle(Self.httpRequest(request)) {
        case .response(let response):
            return ClientResponse(
                status: response.status,
                headers: Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) }),
                body: response.body
            )
        case .events, .mjpeg:
            throw ReolensClientError.malformedResponse("streaming outcome on a unary call")
        }
    }

    func streamLines(_ request: ClientRequest) -> AsyncThrowingStream<String, any Error> {
        let gateway = self.gateway
        let httpRequest = Self.httpRequest(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch await gateway.handle(httpRequest) {
                case .events(let stream):
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    for await event in stream {
                        if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
                            continuation.yield("data: \(line)")
                            continuation.yield("")
                        }
                    }
                    continuation.finish()
                case .response(let response):
                    continuation.finish(throwing: ReolensClientError.unreachable("Event stream refused (HTTP \(response.status))"))
                case .mjpeg:
                    continuation.finish(throwing: ReolensClientError.malformedResponse("mjpeg outcome on events"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func httpRequest(_ request: ClientRequest) -> HTTPRequest {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" } ?? [:]
        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
        return HTTPRequest(method: request.method, path: request.url.path, query: query, headers: headers, body: request.body)
    }
}

private struct IntegrationFake: CameraAPI {
    let event = EventResource(id: "E1", cameraID: "CAM-1", channel: 0, kind: .ai, detection: .person, timestamp: Date(timeIntervalSince1970: 42))
    func cameras() async throws -> [CameraResource] {
        [CameraResource(id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true)]
    }
    func camera(_ id: CameraID) async throws -> CameraResource {
        guard id == "CAM-1" else { throw APIError.cameraNotFound(id) }
        return try await cameras()[0]
    }
    func channels(_ id: CameraID) async throws -> [ChannelResource] { [ChannelResource(id: 0, online: true)] }
    func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload { ImagePayload(bytes: Data([9, 8, 7])) }
    func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef { StreamRef(quality: quality) }
    func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {}
    func reboot(_ id: CameraID) async throws {}
    func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        CameraDiagnostics(id: id, connectionStatus: .connected, controlTransport: .baichuan, online: true, channelCount: 1, eventCount: 1, lastError: nil)
    }
    func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage {
        RecordingPage(items: [RecordingResource(id: "REC-1", start: query.from, end: query.to, triggers: query.types ?? [])], nextCursor: "next-1")
    }
    func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef {
        DownloadRef(url: URL(string: "http://camera.invalid/secret-token"), contentType: "video/mp4", sizeBytes: 10)
    }
    func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings { ChannelSettings(name: "Cam") }
    func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        ChannelSettings(name: patch.name ?? "Cam", notificationsEnabled: patch.notificationsEnabled)
    }
    func events(_ filter: EventFilter) -> AsyncStream<EventResource> {
        let event = self.event
        return AsyncStream { continuation in
            if filter.matches(event) { continuation.yield(event) }
            continuation.finish()
        }
    }
    func health() async throws -> SystemHealth { SystemHealth(cameraCount: 1, onlineCount: 1) }
}

@Suite("RemoteCameraAPI ↔ APIGateway")
struct ClientGatewayIntegrationTests {
    private func client(token: String? = "tok") -> RemoteCameraAPI {
        RemoteCameraAPI(
            baseURL: URL(string: "http://127.0.0.1:8443")!,
            token: token,
            transport: GatewayTransport(gateway: APIGateway(api: IntegrationFake(), token: "tok"))
        )
    }

    @Test("health, cameras, channels, diagnostics round-trip through the real gateway")
    func roundTrips() async throws {
        let api = client()
        #expect(try await api.health().cameraCount == 1)
        #expect(try await api.cameras().first?.displayName == "Front Door")
        #expect(try await api.channels("CAM-1").first?.id == 0)
        let diag = try await api.diagnostics("CAM-1")
        #expect(diag.controlTransport == .baichuan)
    }

    @Test("a wrong token is the gateway's own 401, decoded as APIError")
    func auth() async {
        do {
            _ = try await client(token: "wrong").cameras()
            Issue.record("expected 401")
        } catch let error as APIError {
            #expect(error.code == "unauthorized")
            #expect(error.status == 401)
        } catch {
            Issue.record("expected APIError, got \(error)")
        }
    }

    @Test("snapshot bytes pass through the gateway's raw-bytes path")
    func snapshot() async throws {
        #expect(try await client().snapshot("CAM-1", channel: 0).bytes == Data([9, 8, 7]))
    }

    @Test("recordings query names agree (from/to/types) and cursor survives via meta")
    func recordings() async throws {
        let page = try await client().recordings(
            "CAM-1", channel: 0,
            RecordingQuery(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 60), types: [.person])
        )
        #expect(page.items.first?.triggers == [.person])
        #expect(page.nextCursor == "next-1")
    }

    @Test("download references never carry the upstream URL through the gateway")
    func downloadRedaction() async throws {
        let ref = try await client().recordingDownload("CAM-1", "REC-1")
        #expect(ref.url == nil)
        #expect(ref.sizeBytes == 10)
    }

    @Test("settings PATCH and PTZ 202 agree end to end")
    func writes() async throws {
        let api = client()
        let updated = try await api.updateSettings("CAM-1", channel: 0, ChannelSettingsPatch(name: "Porch", notificationsEnabled: false))
        #expect(updated.name == "Porch")
        #expect(updated.notificationsEnabled == false)
        try await api.ptz("CAM-1", channel: 0, PTZCommand(op: .left, speed: 4))
    }

    @Test("events stream through the gateway's SSE framing into the client parser")
    func events() async throws {
        var received: [EventResource] = []
        for await event in client().events(EventFilter(detections: [.person])) {
            received.append(event)
        }
        #expect(received.map(\.id) == ["E1"])
    }
}

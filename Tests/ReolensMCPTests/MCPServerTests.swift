import Foundation
import Testing
import ReolensCore
@testable import ReolensMCP

/// In-memory CameraAPI for MCP dispatch tests (mirrors the server tests'
/// fake; duplicated because test targets don't share helpers).
struct FakeAPI: CameraAPI {
    var cams = [CameraResource(id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true)]
    func cameras() async throws -> [CameraResource] { cams }
    func camera(_ id: CameraID) async throws -> CameraResource {
        guard let cam = cams.first(where: { $0.id == id }) else { throw APIError.cameraNotFound(id) }
        return cam
    }
    func channels(_ id: CameraID) async throws -> [ChannelResource] {
        [ChannelResource(id: 0, name: "Front Door", online: true, capabilities: ChannelCapabilities(ptz: true, talk: false, ai: [.person]))]
    }
    func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload { ImagePayload(bytes: Data([0xFF, 0xD8])) }
    func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef { StreamRef(quality: quality, codec: "h264") }
    func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {}
    func reboot(_ id: CameraID) async throws {}
    func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        CameraDiagnostics(id: id, connectionStatus: .connected, controlTransport: .https, online: true, channelCount: 1, eventCount: 2, lastError: nil)
    }
    func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage { RecordingPage(items: []) }
    func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef { DownloadRef(contentType: "video/mp4") }
    func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings { ChannelSettings(name: "Front Door", notificationsEnabled: true) }
    func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        ChannelSettings(name: patch.name ?? "Front Door", osd: patch.osd, notificationsEnabled: patch.notificationsEnabled ?? true)
    }
    func events(_ filter: EventFilter) -> AsyncStream<EventResource> { AsyncStream { $0.finish() } }
    func health() async throws -> SystemHealth { SystemHealth(cameraCount: cams.count, onlineCount: 1) }
}

private func parse(_ line: String?) -> JSONValue? {
    line.flatMap { JSONValue.parse($0) }
}

@Suite("MCPServer")
struct MCPServerTests {
    let server = MCPServer(api: FakeAPI())

    @Test("initialize negotiates a supported protocol version")
    func initialize() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        #expect(response?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(response?["result"]?["serverInfo"]?["name"]?.stringValue == "reolens")
    }

    @Test("notifications never get a response; blank lines are ignored")
    func notifications() async {
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(line: "   ") == nil)
    }

    @Test("tools/list exposes the full catalog with schemas")
    func toolsList() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = response?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == MCPTools.all.count)
        #expect(tools.contains { $0["name"]?.stringValue == "camera_snapshot" })
        #expect(tools.allSatisfy { $0["inputSchema"] != nil })
    }

    @Test("tools/call cameras_list returns DTO JSON text")
    func callList() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cameras_list","arguments":{}}}"#))
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("Front Door"))
        #expect(response?["result"]?["isError"] == nil)
    }

    @Test("camera selectors accept exact display names")
    func selectorByName() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"camera_diagnostics","arguments":{"camera":"front door"}}}"#))
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains(#""connectionStatus":"connected""#))
    }

    @Test("unknown camera surfaces the contract error code as an isError result")
    func unknownCamera() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"camera_get","arguments":{"camera":"nope"}}}"#))
        #expect(response?["result"]?["isError"]?.boolValue == true)
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("camera_not_found"))
    }

    @Test("snapshot returns MCP image content")
    func snapshot() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"camera_snapshot","arguments":{"camera":"CAM-1"}}}"#))
        let content = response?["result"]?["content"]?.arrayValue?.first
        #expect(content?["type"]?.stringValue == "image")
        #expect(content?["mimeType"]?.stringValue == "image/jpeg")
        #expect(content?["data"]?.stringValue == Data([0xFF, 0xD8]).base64EncodedString())
    }

    @Test("reboot without confirm is refused before touching the camera")
    func rebootGate() async {
        let response = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"camera_reboot","arguments":{"camera":"CAM-1"}}}"#))
        #expect(response?["result"]?["isError"]?.boolValue == true)
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("confirmation_required"))
    }

    @Test("malformed JSON is a -32700 parse error; unknown method is -32601")
    func protocolErrors() async {
        let parseError = parse(await server.handle(line: "not json"))
        #expect(parseError?["error"]?["code"]?.intValue == -32700)
        let unknown = parse(await server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"bogus/method"}"#))
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
    }

    @Test("JSONValue round-trips nested structures")
    func jsonValue() {
        let value: JSONValue = ["a": [1, true, "x"], "b": ["c": 2.5]]
        #expect(JSONValue.parse(value.serialized()) == value)
    }
}

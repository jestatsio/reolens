import Foundation
import Testing
import ReolensCore
import ReolensClient
@testable import ReolensCLIKit

final class FakeAPI: CameraAPI, @unchecked Sendable {
    var cams = [CameraResource(id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true)]
    var failure: (any Error)?
    private let lock = NSLock()
    private(set) var ptzOps: [PTZOp] = []
    var eventList: [EventResource] = []

    private func gate() throws { if let failure { throw failure } }
    func cameras() async throws -> [CameraResource] { try gate(); return cams }
    func camera(_ id: CameraID) async throws -> CameraResource {
        try gate()
        guard let cam = cams.first(where: { $0.id == id }) else { throw APIError.cameraNotFound(id) }
        return cam
    }
    func channels(_ id: CameraID) async throws -> [ChannelResource] { try gate(); return [ChannelResource(id: 0, online: true)] }
    func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload { try gate(); return ImagePayload(bytes: Data([1, 2, 3])) }
    func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef { try gate(); return StreamRef(quality: quality) }
    func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {
        try gate()
        lock.withLock { ptzOps.append(command.op) }
    }
    func reboot(_ id: CameraID) async throws { try gate() }
    func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        try gate()
        return CameraDiagnostics(id: id, connectionStatus: .connected, controlTransport: .http, online: true, channelCount: 1, eventCount: 0, lastError: nil)
    }
    func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage { try gate(); return RecordingPage(items: []) }
    func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef { try gate(); return DownloadRef() }
    func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings { try gate(); return ChannelSettings() }
    func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings { try gate(); return ChannelSettings(name: patch.name) }
    func events(_ filter: EventFilter) -> AsyncStream<EventResource> {
        let list = eventList
        return AsyncStream { continuation in
            for event in list where filter.matches(event) { continuation.yield(event) }
            continuation.finish()
        }
    }
    func health() async throws -> SystemHealth { try gate(); return SystemHealth(cameraCount: cams.count, onlineCount: 1) }
}

@Suite("CLIParse")
struct CLIParseTests {
    private func parse(_ argv: [String], env: [String: String] = [:]) -> CLIParse {
        CLIParse.parse(argv: argv, env: env, now: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("empty and --help show help")
    func help() {
        #expect(parse([]) == .help)
        #expect(parse(["--help"]) == .help)
        #expect(parse(["cameras", "list", "--help"]) == .help)
    }

    @Test("environment supplies URL and token; flags win")
    func envConfig() {
        guard case .run(let config, .camerasList) = parse(["cameras", "list"], env: ["REOLENS_API_URL": "http://mac.local:9000", "REOLENS_API_TOKEN": "sekrit"]) else {
            Issue.record("expected cameras list run"); return
        }
        #expect(config.baseURL.absoluteString == "http://mac.local:9000")
        #expect(config.token == "sekrit")
        guard case .run(let flagged, _) = parse(["--token", "flag-token", "health"], env: ["REOLENS_API_TOKEN": "env-token"]) else {
            Issue.record("expected health run"); return
        }
        #expect(flagged.token == "flag-token")
    }

    @Test("camera commands require --camera; flags may follow the command")
    func cameraRequired() {
        guard case .failure = parse(["snapshot", "--file", "/tmp/x.jpg"]) else {
            Issue.record("expected failure without --camera"); return
        }
        guard case .run(let config, .snapshot(let file)) = parse(["snapshot", "--camera", "Porch", "--file=/tmp/x.jpg"]) else {
            Issue.record("expected snapshot run"); return
        }
        #expect(config.camera == "Porch")
        #expect(file == "/tmp/x.jpg")
    }

    @Test("reboot needs --yes")
    func rebootGate() {
        guard case .failure(let message) = parse(["--camera", "CAM-1", "reboot"]) else {
            Issue.record("expected failure"); return
        }
        #expect(message.contains("--yes"))
        guard case .run(_, .reboot) = parse(["--camera", "CAM-1", "reboot", "--yes"]) else {
            Issue.record("expected reboot run"); return
        }
    }

    @Test("ptz validates op and preset")
    func ptzParse() {
        guard case .failure = parse(["--camera", "C", "ptz", "sideways"]) else { Issue.record("bad op should fail"); return }
        guard case .failure = parse(["--camera", "C", "ptz", "toPreset"]) else { Issue.record("toPreset needs --preset"); return }
        guard case .run(_, .ptz(let command, let duration)) = parse(["--camera", "C", "ptz", "left", "--speed", "8", "--duration-ms", "500"]) else {
            Issue.record("expected ptz run"); return
        }
        #expect(command.op == .left)
        #expect(command.speed == 8)
        #expect(duration == 500)
    }

    @Test("recordings --since resolves against the injected now")
    func recordingsSince() {
        guard case .run(_, .recordingsList(let query)) = parse(["--camera", "C", "recordings", "list", "--since", "24h", "--types", "person,vehicle"]) else {
            Issue.record("expected recordings run"); return
        }
        #expect(query.to == Date(timeIntervalSince1970: 1_000_000))
        #expect(query.from == Date(timeIntervalSince1970: 1_000_000 - 86400))
        #expect(query.types == [.person, .vehicle])
    }

    @Test("settings set requires a field; mcp-server and bad output parse distinctly")
    func miscParse() {
        guard case .failure = parse(["--camera", "C", "settings", "set"]) else { Issue.record("empty set should fail"); return }
        guard case .run(_, .settingsSet(let patch)) = parse(["--camera", "C", "settings", "set", "--osd-name", "off", "--notifications", "on"]) else {
            Issue.record("expected settings run"); return
        }
        #expect(patch.osd?.showName == false)
        #expect(patch.notificationsEnabled == true)
        guard case .mcpServer = parse(["mcp-server"]) else { Issue.record("expected mcpServer"); return }
        guard case .failure = parse(["--output", "yaml", "health"]) else { Issue.record("bad output should fail"); return }
        guard case .failure = parse(["frobnicate"]) else { Issue.record("unknown command should fail"); return }
    }
}

@Suite("CLIRunner")
struct CLIRunnerTests {
    private var config: CLIConfig { CLIConfig(baseURL: URL(string: "http://127.0.0.1:8443")!, token: "t") }

    @Test("cameras list renders a JSON envelope")
    func listJSON() async {
        let outcome = await CLIRunner().run(.camerasList, config: config, api: FakeAPI())
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains(#""ok":true"#))
        #expect(outcome.stdout.contains(#""command":"cameras list""#))
        #expect(outcome.stdout.contains("Front Door"))
        #expect(outcome.stderr.isEmpty)
    }

    @Test("text mode renders plain lines without an envelope")
    func listText() async {
        var textConfig = config
        textConfig.output = .text
        let outcome = await CLIRunner().run(.camerasList, config: textConfig, api: FakeAPI())
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("Front Door"))
        #expect(!outcome.stdout.contains(#""ok""#))
    }

    @Test("API errors exit 1 with the contract code on stderr")
    func apiError() async {
        var camConfig = config
        camConfig.camera = "nope"
        let outcome = await CLIRunner().run(.diagnostics, config: camConfig, api: FakeAPI())
        #expect(outcome.exitCode == 1)
        #expect(outcome.stderr.contains("camera_not_found"))
        #expect(outcome.stdout.isEmpty)
    }

    @Test("unreachable server exits 3 with setup guidance")
    func unreachable() async {
        let fake = FakeAPI()
        fake.failure = ReolensClientError.unreachable("Cannot reach the Reolens server")
        let outcome = await CLIRunner().run(.health, config: config, api: fake)
        #expect(outcome.exitCode == 3)
        #expect(outcome.stderr.contains("Local API"))
    }

    @Test("snapshot writes exact bytes to the requested file")
    func snapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reolens-cli-tests-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("snap.jpg")
        var camConfig = config
        camConfig.camera = "Front Door"
        let outcome = await CLIRunner().run(.snapshot(file: file.path), config: camConfig, api: FakeAPI())
        #expect(outcome.exitCode == 0)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("timed ptz jog moves then stops")
    func ptzJog() async {
        let fake = FakeAPI()
        var camConfig = config
        camConfig.camera = "CAM-1"
        let outcome = await CLIRunner().run(.ptz(PTZCommand(op: .left), durationMs: 1), config: camConfig, api: fake)
        #expect(outcome.exitCode == 0)
        #expect(fake.ptzOps == [.left, .stop])
    }

    @Test("events honor --max-events")
    func eventsBounded() async {
        let fake = FakeAPI()
        fake.eventList = (1...5).map { i in
            EventResource(id: "E\(i)", cameraID: "CAM-1", channel: 0, kind: .ai, detection: .person, timestamp: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let outcome = await CLIRunner().run(.events(maxEvents: 2, detections: nil), config: config, api: fake)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.split(separator: "\n").count == 2)
    }
}

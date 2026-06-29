import Foundation
import ReolensCore

/// In-memory `CameraAPI` for exercising the HTTP facade with no network and no
/// real cameras (AGENTS.md §12). Pure value type — `Sendable` for free.
struct FakeCameraAPI: CameraAPI {
    var cameraList: [CameraResource] = []
    var channelList: [ChannelResource] = []
    var snapshotBytes = Data([0xFF, 0xD8, 0xFF])   // JPEG SOI marker
    var recordingItems: [RecordingResource] = []
    var settingsValue = ChannelSettings(name: "Cam", osd: OSDSettings(showName: true, showDate: true), notificationsEnabled: true)
    var emittedEvents: [EventResource] = []
    /// Snapshot for this id throws `upstreamUnreachable` (502 path).
    var unreachableCameraID: CameraID?

    func cameras() async throws -> [CameraResource] { cameraList }

    func camera(_ id: CameraID) async throws -> CameraResource {
        guard let camera = cameraList.first(where: { $0.id == id }) else { throw APIError.cameraNotFound(id) }
        return camera
    }

    func channels(_ id: CameraID) async throws -> [ChannelResource] { channelList }

    func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload {
        if id == unreachableCameraID { throw APIError.upstreamUnreachable() }
        return ImagePayload(bytes: snapshotBytes)
    }

    func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef {
        StreamRef(quality: quality, codec: "h264")
    }

    func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {}

    func reboot(_ id: CameraID) async throws {
        guard cameraList.contains(where: { $0.id == id }) else { throw APIError.cameraNotFound(id) }
    }

    var diagnosticsValue = CameraDiagnostics(
        id: "CAM-1", connectionStatus: "connected", controlTransport: "baichuan",
        online: true, channelCount: 1, eventCount: 0, lastError: nil
    )

    func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        guard cameraList.contains(where: { $0.id == id }) else { throw APIError.cameraNotFound(id) }
        return diagnosticsValue
    }

    func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage {
        RecordingPage(items: recordingItems, nextCursor: nil)
    }

    func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef {
        DownloadRef(url: URL(string: "http://camera.local/clip"), contentType: "video/mp4")
    }

    func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings { settingsValue }

    func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        ChannelSettings(
            name: patch.name ?? settingsValue.name,
            osd: patch.osd ?? settingsValue.osd,
            notificationsEnabled: patch.notificationsEnabled ?? settingsValue.notificationsEnabled
        )
    }

    func events(_ filter: EventFilter) -> AsyncStream<EventResource> {
        let events = emittedEvents
        return AsyncStream { continuation in
            for event in events where filter.matches(event) {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func health() async throws -> SystemHealth {
        SystemHealth(cameraCount: cameraList.count, onlineCount: cameraList.filter(\.online).count)
    }
}

extension FakeCameraAPI {
    static let oneCamera = FakeCameraAPI(
        cameraList: [CameraResource(id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true)],
        channelList: [ChannelResource(id: 0, name: "Front Door", online: true, capabilities: ChannelCapabilities(ptz: true, talk: false, ai: [.person]))]
    )
}

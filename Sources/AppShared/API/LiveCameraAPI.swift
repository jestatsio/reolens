import Foundation
import ReolinkAPI
import ReolensCore
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "api")

/// In-process implementation of `CameraAPI`, backed by the existing
/// `CameraStore` / `CameraSession` stack. This is the single source of truth
/// that the app's own surfaces and the HTTP facade (`ReolensServer`) both call.
///
/// Holds the `@MainActor` `CameraStore` (implicitly `Sendable`). All camera
/// work runs on the main actor — where the store and sessions live — and
/// suspends at the CGI-actor boundary, matching how the rest of the app drives
/// these types. Per-camera operations connect the session on demand.
public struct LiveCameraAPI: CameraAPI {
    private let store: CameraStore

    public init(store: CameraStore) {
        self.store = store
    }

    // MARK: Devices & channels

    public func cameras() async throws -> [CameraResource] {
        // The list reflects current state without forcing a connect on every
        // camera (that would hammer the whole fleet). Per-camera endpoints
        // connect on demand.
        await MainActor.run {
            store.orderedCameras().map { entry in
                Self.cameraResource(entry: entry, session: store.sessions[entry.id])
            }
        }
    }

    public func camera(_ id: CameraID) async throws -> CameraResource {
        let session = try await connectedSession(id)
        return await MainActor.run {
            Self.cameraResource(entry: session.entry, session: session)
        }
    }

    public func channels(_ id: CameraID) async throws -> [ChannelResource] {
        let session = try await connectedSession(id)
        return try await loadChannels(session)
    }

    // MARK: Media

    public func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload {
        let session = try await connectedSession(id)
        let data = try await fetchSnapshot(session, channel: channel)
        return ImagePayload(bytes: data, contentType: "image/jpeg")
    }

    public func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef {
        let session = try await connectedSession(id)
        return await MainActor.run {
            // The MJPEG/HLS URLs are filled in by the HTTP facade (it knows its
            // own externally-visible base URL); the direct RTSP URL embeds
            // credentials and is deliberately omitted in v1.
            let codec = session.entry.preferredCodec == .h265 ? "h265" : "h264"
            return StreamRef(quality: quality, codec: codec)
        }
    }

    // MARK: Control

    public func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {
        let session = try await connectedSession(id)
        await session.ptz(
            channel: channel,
            op: ResourceMapping.ptzOp(command.op),
            speed: command.speed ?? 32,
            presetID: command.presetID
        )
    }

    public func reboot(_ id: CameraID) async throws {
        let session = try await connectedSession(id)
        // Best-effort: a reboot tears down the control connection, so a
        // transport error right after dispatch is the expected outcome, not a
        // failure. `connectedSession` already verified the camera is reachable
        // and authenticated, so reaching here means the command was sent.
        try? await session.client.sendIgnoringValue(Commands.reboot())
    }

    // MARK: Recordings

    public func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage {
        let session = try await connectedSession(id)
        return try await searchRecordings(session, channel: channel, query: query)
    }

    public func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef {
        let session = try await connectedSession(id)
        return await makeDownloadRef(session, recording: recording)
    }

    // MARK: Settings

    public func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings {
        let session = try await connectedSession(id)
        return await readSettings(session, channel: channel)
    }

    public func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        let session = try await connectedSession(id)
        return try await writeSettings(session, channel: channel, patch: patch)
    }

    // MARK: Live events & system

    public func events(_ filter: EventFilter) -> AsyncStream<EventResource> {
        AsyncStream { continuation in
            let task = Task {
                let upstream = await MotionEventStream.shared.subscribe()
                for await event in upstream {
                    let resource = Self.eventResource(event)
                    if filter.matches(resource) {
                        continuation.yield(resource)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func health() async throws -> SystemHealth {
        await MainActor.run {
            let cams = store.cameras
            let online = cams.reduce(into: 0) { count, entry in
                if store.sessions[entry.id]?.status == .connected { count += 1 }
            }
            return SystemHealth(
                apiVersion: APIVersion.current,
                appVersion: Self.appVersion,
                cameraCount: cams.count,
                onlineCount: online,
                hubRunning: store.preferences.runAsHub
            )
        }
    }

    // MARK: Diagnostics

    public func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        try await MainActor.run {
            guard let uuid = UUID(uuidString: id),
                  store.cameras.contains(where: { $0.id == uuid }) else {
                throw APIError.cameraNotFound(id)
            }
            // Read current state without forcing a connect — diagnostics
            // reflect the existing session, they don't start one.
            return Self.makeDiagnostics(id: id, session: store.sessions[uuid])
        }
    }

    /// Map a session's live state onto the diagnostics resource. `@MainActor`
    /// because it reads session state; all fields stay credential/host-free
    /// (AGENTS.md §3 — `lastError` is the already-sanitized user-facing reason).
    @MainActor
    static func makeDiagnostics(id: CameraID, session: CameraSession?) -> CameraDiagnostics {
        let connectionStatus: String
        let lastError: String?
        switch session?.status {
        case .connected?:          connectionStatus = "connected";    lastError = nil
        case .connecting?:         connectionStatus = "connecting";   lastError = nil
        case .error(let reason)?:  connectionStatus = "error";        lastError = reason
        case .disconnected?, nil:  connectionStatus = "disconnected"; lastError = nil
        }
        let online = session?.status == .connected
        let transport: String?
        if online, let session {
            transport = session.usingBaichuanControl
                ? "baichuan"
                : (session.credentials.useHTTPS ? "https" : "http")
        } else {
            transport = nil
        }
        return CameraDiagnostics(
            id: id,
            connectionStatus: connectionStatus,
            controlTransport: transport,
            online: online,
            channelCount: session?.liveChannels.count ?? 0,
            eventCount: session?.aiEventLog.count ?? 0,
            lastError: lastError
        )
    }

    // MARK: - Session resolution

    /// Resolve a connected session for `id`, connecting on demand. Throws a
    /// typed `APIError` for unknown cameras, missing credentials, or
    /// unreachable devices.
    @MainActor
    private func connectedSession(_ id: CameraID) async throws -> CameraSession {
        guard let uuid = UUID(uuidString: id) else { throw APIError.cameraNotFound(id) }
        guard store.cameras.contains(where: { $0.id == uuid }) else { throw APIError.cameraNotFound(id) }
        guard let session = store.session(for: uuid) else {
            throw APIError.upstreamUnreachable("No stored password for this camera")
        }
        if session.status != .connected {
            await session.connect()
            guard session.status == .connected else {
                throw APIError.upstreamUnreachable()
            }
        }
        return session
    }

    // MARK: - Mapping helpers (MainActor — read live session state)

    @MainActor
    private static func cameraResource(entry: CameraEntry, session: CameraSession?) -> CameraResource {
        let info = session?.deviceInfo
        let online = session?.status == .connected
        let liveCount = session?.liveChannels.count ?? 0
        let channelCount = liveCount > 0 ? liveCount : (info?.channelNum ?? 1)
        return CameraResource(
            id: entry.id.uuidString,
            displayName: entry.displayName,
            kind: ResourceMapping.deviceKind(info),
            model: info?.model,
            firmwareVersion: info?.firmVer,
            channelCount: channelCount,
            online: online,
            host: entry.host
        )
    }

    @MainActor
    private func loadChannels(_ session: CameraSession) async throws -> [ChannelResource] {
        // One ability fetch for the whole device covers ptz/talk per channel.
        let ability = try? await session.client
            .send(Commands.getAbility(username: session.credentials.username), as: AbilityEnvelope.self)
            .Ability
        var result: [ChannelResource] = []
        for ch in session.liveChannels {
            // Best-effort per-channel AI support. The CGIClient serializes
            // these on the wire, so they don't overload a sensitive hub.
            let aiState = try? await session.client.send(Commands.getAiState(channel: ch.channel), as: AIStateValue.self)
            let capabilities = ChannelCapabilities(
                ptz: Self.abilityFlag(ability, key: "ptzCtrl", channel: ch.channel),
                talk: Self.abilityFlag(ability, key: "talk", channel: ch.channel),
                ai: aiState.map(ResourceMapping.aiSupport) ?? []
            )
            let battery = session.batteryByChannel[ch.channel].map {
                BatteryInfo(
                    percent: $0.percent,
                    charging: $0.chargeStatus.lowercased() == "charging",
                    pluggedIn: $0.isPluggedIn
                )
            }
            result.append(ChannelResource(
                id: ch.channel,
                name: ch.name,
                online: ch.isOnline,
                isDualLens: session.isDualLens(channel: ch.channel),
                isBatteryPowered: session.isBatteryPowered(channel: ch.channel),
                battery: battery,
                capabilities: capabilities
            ))
        }
        return result
    }

    private static func abilityFlag(_ ability: Ability?, key: String, channel: Int) -> Bool {
        guard let ability else { return false }
        if let cap = ability.channelCapability(key, channel: channel) {
            return cap.permit > 0
        }
        return ability.has(key)
    }

    @MainActor
    private func fetchSnapshot(_ session: CameraSession, channel: Int) async throws -> Data {
        do {
            return try await session.client.snapshotData(channel: channel)
        } catch {
            throw Self.mapUpstream(error)
        }
    }

    @MainActor
    private func searchRecordings(_ session: CameraSession, channel: Int, query: RecordingQuery) async throws -> RecordingPage {
        let envelope: SearchEnvelope
        do {
            envelope = try await session.client.send(
                Commands.search(channel: channel, onlyStatus: false, streamType: "main", start: query.from, end: query.to),
                as: SearchEnvelope.self
            )
        } catch {
            throw Self.mapUpstream(error)
        }
        var items = (envelope.SearchResult.File ?? [])
            .compactMap(ResourceMapping.recording)
            .sorted { $0.start > $1.start }   // newest first
        if let types = query.types, !types.isEmpty {
            let allow = Set(types)
            items = items.filter { !Set($0.triggers).isDisjoint(with: allow) }
        }
        let offset = Self.decodeCursor(query.cursor)
        let limit = min(max(query.limit ?? 200, 1), 1000)
        let pageItems = Array(items.dropFirst(offset).prefix(limit))
        let nextOffset = offset + pageItems.count
        let nextCursor = nextOffset < items.count ? Self.encodeCursor(nextOffset) : nil
        return RecordingPage(items: pageItems, nextCursor: nextCursor)
    }

    @MainActor
    private func makeDownloadRef(_ session: CameraSession, recording: RecordingID) async -> DownloadRef {
        // Token-authed camera URL. The HTTP facade proxies this so the camera
        // host + token never reach an external consumer (AGENTS.md §3/§4).
        let token = await session.client.currentToken?.name
        let url = session.streamURLs.recordingDownload(source: recording, token: token)
        return DownloadRef(url: url, contentType: "video/mp4")
    }

    @MainActor
    private func readSettings(_ session: CameraSession, channel: Int) async -> ChannelSettings {
        var name = session.liveChannels.first(where: { $0.channel == channel })?.name
        var osd: OSDSettings?
        if let envelope = try? await session.client.send(Commands.getOsd(channel: channel), as: OsdEnvelope.self) {
            osd = OSDSettings(
                showName: envelope.Osd.osdChannel?.isEnabled,
                showDate: envelope.Osd.osdTime?.isEnabled
            )
            if let osdName = envelope.Osd.osdChannel?.name, !osdName.isEmpty { name = osdName }
        }
        let notificationsEnabled = CameraNotificationPreferences.shared
            .isNotificationsEnabled(for: session.entry.id, channel: channel)
        return ChannelSettings(name: name, osd: osd, notificationsEnabled: notificationsEnabled)
    }

    @MainActor
    private func writeSettings(_ session: CameraSession, channel: Int, patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        if let enabled = patch.notificationsEnabled {
            CameraNotificationPreferences.shared.setNotificationsEnabled(enabled, for: session.entry.id, channel: channel)
        }
        if patch.osd != nil || patch.name != nil {
            // Read-modify-write the device OSD block so we only touch the
            // requested fields.
            if var osd = try? await session.client.send(Commands.getOsd(channel: channel), as: OsdEnvelope.self).Osd {
                if let showName = patch.osd?.showName { osd.osdChannel?.isEnabled = showName }
                if let showDate = patch.osd?.showDate { osd.osdTime?.isEnabled = showDate }
                if let newName = patch.name {
                    if osd.osdChannel == nil {
                        osd.osdChannel = OsdSettings.OsdItem(enable: 1, name: newName)
                    } else {
                        osd.osdChannel?.name = newName
                    }
                }
                do {
                    try await session.client.sendIgnoringValue(Commands.setOsd(osd))
                } catch {
                    throw Self.mapUpstream(error)
                }
            }
        }
        return await readSettings(session, channel: channel)
    }

    // MARK: - Pure helpers

    static func eventResource(_ event: MotionEventStream.Event) -> EventResource {
        let kind: EventKind
        let detection: DetectionKind?
        switch event.kind {
        case .motionStart:
            kind = .motionStart
            detection = nil
        case .motionStop:
            kind = .motionStop
            detection = nil
        case .ai(let tag):
            kind = .ai
            detection = ResourceMapping.detection(fromReolinkTag: tag)
        }
        return EventResource(
            id: UUID().uuidString,
            cameraID: event.cameraID.uuidString,
            channel: event.channel,
            kind: kind,
            detection: detection,
            timestamp: event.timestamp
        )
    }

    static func encodeCursor(_ offset: Int) -> String {
        Data(String(offset).utf8).base64EncodedString()
    }

    static func decodeCursor(_ cursor: String?) -> Int {
        guard let cursor,
              let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8),
              let value = Int(text) else { return 0 }
        return max(0, value)
    }

    private static func mapUpstream(_ error: any Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let reolink = error as? ReolinkClientError, case .http(let status, _) = reolink,
           status == 401 || status == 403 {
            return .unauthorized("The camera rejected the stored credentials")
        }
        return .upstreamUnreachable()
    }

    private static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
}

import Foundation
import ReolensCore

/// JSON coders matching the server's (`APIJSON` in ReolensServer):
/// ISO-8601 dates, unescaped slashes.
enum ClientJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A ``CameraAPI`` that speaks to a running Reolens Local API server
/// (`ReolensServer`, `/v1`) over HTTP — the client half of the same
/// contract `LiveCameraAPI` implements in-process.
///
/// This is the gateway pattern from reolink-cli, natively: the Mac app
/// (with Settings → Local API enabled) holds the camera sessions and
/// credentials; the CLI/MCP processes hold only the bearer token and make
/// LAN requests. No camera password ever reaches this type.
///
/// Server errors throw the decoded ``APIError``; connection failures
/// throw ``ReolensClientError/unreachable(_:)`` so callers can tell
/// "start the app / enable the API" apart from "the camera said no".
public struct RemoteCameraAPI: CameraAPI {
    /// Server root, e.g. `http://127.0.0.1:8443` (no trailing `/v1`).
    public let baseURL: URL
    private let token: String?
    private let transport: any HTTPTransport

    public init(baseURL: URL, token: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: Devices & channels

    public func cameras() async throws -> [CameraResource] {
        try await get(["cameras"])
    }

    public func camera(_ id: CameraID) async throws -> CameraResource {
        try await get(["cameras", id])
    }

    public func channels(_ id: CameraID) async throws -> [ChannelResource] {
        try await get(["cameras", id, "channels"])
    }

    public func diagnostics(_ id: CameraID) async throws -> CameraDiagnostics {
        try await get(["cameras", id, "diagnostics"])
    }

    public func health() async throws -> SystemHealth {
        try await get(["health"])
    }

    // MARK: Media

    public func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload {
        let response = try await send(makeRequest("GET", ["cameras", id, "channels", String(channel), "snapshot"]))
        try throwIfError(response)
        guard (200..<300).contains(response.status) else {
            throw ReolensClientError.malformedResponse("Snapshot returned HTTP \(response.status)")
        }
        return ImagePayload(bytes: response.body, contentType: response.header("content-type") ?? "image/jpeg")
    }

    public func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef {
        try await get(["cameras", id, "channels", String(channel), "stream"], query: ["quality": quality.rawValue])
    }

    // MARK: Control

    public func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws {
        let body = try ClientJSON.encoder.encode(command)
        let response = try await send(makeRequest("POST", ["cameras", id, "channels", String(channel), "ptz"], body: body))
        try throwIfError(response)
    }

    public func reboot(_ id: CameraID) async throws {
        let response = try await send(makeRequest("POST", ["cameras", id, "reboot"]))
        try throwIfError(response)
    }

    // MARK: Recordings

    public func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage {
        var params: [String: String] = [
            "from": APITime.formatISO8601(query.from),
            "to": APITime.formatISO8601(query.to),
        ]
        if let types = query.types, !types.isEmpty {
            params["types"] = types.map(\.rawValue).joined(separator: ",")
        }
        if let cursor = query.cursor { params["cursor"] = cursor }
        if let limit = query.limit { params["limit"] = String(limit) }
        let (items, meta): ([RecordingResource], APIMeta?) =
            try await getWithMeta(["cameras", id, "channels", String(channel), "recordings"], query: params)
        return RecordingPage(items: items, nextCursor: meta?.nextCursor)
    }

    public func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef {
        // The contract method carries no channel; the HTTP route includes
        // one but the server ignores it (the recording id locates the
        // clip). Channel 0 fills the segment.
        try await get(["cameras", id, "channels", "0", "recordings", recording, "download"])
    }

    // MARK: Settings

    public func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings {
        try await get(["cameras", id, "channels", String(channel), "settings"])
    }

    public func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings {
        let body = try ClientJSON.encoder.encode(patch)
        let response = try await send(makeRequest("PATCH", ["cameras", id, "channels", String(channel), "settings"], body: body))
        let envelope: APIResponse<ChannelSettings> = try decodeEnvelope(response)
        guard let data = envelope.data else {
            throw ReolensClientError.malformedResponse("Response carried neither data nor error")
        }
        return data
    }

    // MARK: Live events

    public func events(_ filter: EventFilter) -> AsyncStream<EventResource> {
        var params: [String: String] = [:]
        if let cameraID = filter.cameraID { params["cameraId"] = cameraID }
        if let channel = filter.channel { params["channel"] = String(channel) }
        if let detections = filter.detections, !detections.isEmpty {
            params["detections"] = detections.map(\.rawValue).joined(separator: ",")
        }
        let request = makeRequest("GET", ["events"], query: params)
        let transport = self.transport
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await line in transport.streamLines(request) {
                        if let event = Self.parseSSELine(line) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    // Match the in-process semantics: a dead upstream ends
                    // the stream cleanly rather than throwing (the
                    // protocol's stream is non-throwing).
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parse one Server-Sent Events line into an event. Accepts the
    /// server's `data: {…}` framing and, defensively, a bare JSON line.
    /// Comments (`: …`), blank lines, and undecodable payloads yield nil.
    static func parseSSELine(_ line: String) -> EventResource? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        let payload = trimmed.hasPrefix("data:")
            ? String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard payload.hasPrefix("{"), let data = payload.data(using: .utf8) else { return nil }
        return try? ClientJSON.decoder.decode(EventResource.self, from: data)
    }

    // MARK: - Request plumbing

    private func get<T: Codable & Sendable>(_ segments: [String], query: [String: String] = [:]) async throws -> T {
        let (value, _): (T, APIMeta?) = try await getWithMeta(segments, query: query)
        return value
    }

    private func getWithMeta<T: Codable & Sendable>(_ segments: [String], query: [String: String] = [:]) async throws -> (T, APIMeta?) {
        let response = try await send(makeRequest("GET", segments, query: query))
        let envelope: APIResponse<T> = try decodeEnvelope(response)
        guard let data = envelope.data else {
            throw ReolensClientError.malformedResponse("Response carried neither data nor error")
        }
        return (data, envelope.meta)
    }

    private func decodeEnvelope<T: Codable & Sendable>(_ response: ClientResponse) throws -> APIResponse<T> {
        if let envelope = try? ClientJSON.decoder.decode(APIResponse<T>.self, from: response.body) {
            if let error = envelope.error { throw error }
            return envelope
        }
        // Error envelopes decode against any payload type only when `data`
        // is absent; fall back to the error-only shape before giving up.
        try throwIfError(response)
        throw ReolensClientError.malformedResponse("Undecodable response (HTTP \(response.status))")
    }

    /// Throw the server's ``APIError`` when the response carries one (or a
    /// generic upstream error for a bare failure status). 2xx passes.
    private func throwIfError(_ response: ClientResponse) throws {
        if (200..<300).contains(response.status) { return }
        struct ErrorEnvelope: Decodable { let error: APIError }
        if let envelope = try? ClientJSON.decoder.decode(ErrorEnvelope.self, from: response.body) {
            throw envelope.error
        }
        throw APIError(code: "http_\(response.status)", message: "The server returned HTTP \(response.status)", status: response.status)
    }

    private func send(_ request: ClientRequest) async throws -> ClientResponse {
        do {
            return try await transport.send(request)
        } catch let error as ReolensClientError {
            throw error
        } catch {
            throw ReolensClientError.unreachable(URLSessionTransport.shortReason(error))
        }
    }

    private func makeRequest(_ method: String, _ segments: [String], query: [String: String] = [:], body: Data = Data()) -> ClientRequest {
        var url = baseURL
        for segment in [APIVersion.current] + segments {
            url = url.appendingPathComponent(segment)
        }
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            if let withQuery = components?.url { url = withQuery }
        }
        var headers: [String: String] = ["Accept": "application/json"]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        if !body.isEmpty {
            headers["Content-Type"] = "application/json"
        }
        return ClientRequest(method: method, url: url, headers: headers, body: body)
    }
}

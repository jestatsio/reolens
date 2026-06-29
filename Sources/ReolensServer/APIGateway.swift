import Foundation
import ReolensCore

/// Maps an `HTTPRequest` onto the `CameraAPI` contract: bearer authentication,
/// `/v1` routing, body/query decoding, and consistent error envelopes.
///
/// Pure of any socket I/O — it takes an `HTTPRequest` and returns an
/// ``Outcome`` — so the whole routing/auth surface is unit-testable against an
/// in-memory `any CameraAPI` with no network (AGENTS.md §12). The `NWListener`
/// shell (`ReolensAPIServer`) only does byte transport.
public struct APIGateway: Sendable {
    private let api: any CameraAPI
    /// Required bearer token. `nil` locks out every protected route
    /// (fail-closed) — it does NOT disable auth. See `handle`.
    private let token: String?
    /// Base URL the facade is reachable at, used to fill stream references.
    private let publicBaseURL: String?

    public init(api: any CameraAPI, token: String?, publicBaseURL: String? = nil) {
        self.api = api
        self.token = token
        self.publicBaseURL = publicBaseURL
    }

    /// The result of handling a request: either a complete response, or a live
    /// event stream the connection should serve as Server-Sent Events.
    public enum Outcome: Sendable {
        case response(HTTPResponse)
        case events(AsyncStream<EventResource>)
        /// A live MJPEG video stream — each `Data` is one JPEG frame; the
        /// connection serves them as `multipart/x-mixed-replace`.
        case mjpeg(AsyncStream<Data>)
    }

    public func handle(_ request: HTTPRequest) async -> Outcome {
        let segments = request.pathSegments
        // Only the contract document is public. `/v1/health` requires auth too,
        // so an unauthenticated LAN peer can't enumerate the camera fleet — a
        // 401 is itself proof the server is up (security review H4).
        let isPublic = request.method == "GET" && segments == ["v1", "openapi.json"]

        // Fail closed: a protected route is served only with a valid token. A
        // nil configured token (e.g. Keychain failure) therefore locks
        // everything down rather than silently disabling auth (review C1).
        if !isPublic {
            guard let token, Self.authorized(request, token: token) else {
                return .response(.failure(.unauthorized()))
            }
        }
        return await dispatch(request, segments: segments)
    }

    // MARK: - Routing

    private var notFound: Outcome { .response(.failure(.notFound())) }

    private func dispatch(_ request: HTTPRequest, segments: [String]) async -> Outcome {
        // All routes live under /v1. Swift has no array-literal switch patterns,
        // so match on segment count + fixed positions.
        guard segments.first == "v1" else {
            return .response(.failure(.notFound("Use the \(APIVersion.pathPrefix) prefix")))
        }
        let s = Array(segments.dropFirst())
        let method = request.method

        switch s.count {
        case 1:
            switch (method, s[0]) {
            case ("GET", "health"):
                return await run { .envelope(try await api.health()) }
            case ("GET", "openapi.json"):
                return .response(.json(OpenAPIDescriptor()))
            case ("GET", "cameras"):
                return await run { let list = try await api.cameras(); return .envelope(list, meta: APIMeta(count: list.count)) }
            case ("GET", "events"):
                return .events(api.events(Self.eventFilter(from: request.query)))
            default:
                return notFound
            }

        case 2 where s[0] == "cameras" && method == "GET":
            // /v1/cameras/{id}
            return await run { .envelope(try await api.camera(s[1])) }

        case 3 where s[0] == "cameras" && s[2] == "channels" && method == "GET":
            // /v1/cameras/{id}/channels
            let id = s[1]
            return await run { let list = try await api.channels(id); return .envelope(list, meta: APIMeta(count: list.count)) }

        case 3 where s[0] == "cameras" && s[2] == "diagnostics" && method == "GET":
            // /v1/cameras/{id}/diagnostics
            return await run { .envelope(try await api.diagnostics(s[1])) }

        case 3 where s[0] == "cameras" && s[2] == "reboot" && method == "POST":
            // /v1/cameras/{id}/reboot
            return await run { try await api.reboot(s[1]); return .accepted() }

        case 5 where s[0] == "cameras" && s[2] == "channels":
            // /v1/cameras/{id}/channels/{ch}/{action}
            return await channelAction(request, id: s[1], channelRaw: s[3], action: s[4], method: method)

        case 7 where s[0] == "cameras" && s[2] == "channels" && s[4] == "recordings" && s[6] == "download" && method == "GET":
            // /v1/cameras/{id}/channels/{ch}/recordings/{rid}/download
            let id = s[1]
            let rid = s[5]
            return await run {
                let ref = try await api.recordingDownload(id, rid)
                // Never expose the camera's credential/token-bearing download
                // URL to a consumer (AGENTS.md §3/§4; security review C2). v1
                // returns metadata only — a server-proxied byte stream is a
                // later phase.
                return .envelope(DownloadRef(url: nil, contentType: ref.contentType, sizeBytes: ref.sizeBytes))
            }

        default:
            return notFound
        }
    }

    private func channelAction(_ request: HTTPRequest, id: CameraID, channelRaw: String, action: String, method: String) async -> Outcome {
        guard let channel = Int(channelRaw) else { return badChannel() }
        switch (method, action) {
        case ("GET", "snapshot"):
            return await run {
                let image = try await api.snapshot(id, channel: channel)
                return .bytes(image.bytes, contentType: image.contentType)
            }
        case ("GET", "stream"):
            let quality = StreamQuality(rawValue: request.query["quality"] ?? "sub") ?? .sub
            return await run {
                let ref = try await api.streamRef(id, channel: channel, quality: quality)
                return .envelope(self.fillStreamURLs(ref, id: id, channel: channel))
            }
        case ("GET", "mjpeg"):
            return .mjpeg(mjpegStream(id: id, channel: channel))
        case ("POST", "ptz"):
            guard let command = try? APIJSON.decoder.decode(PTZCommand.self, from: request.body) else {
                return .response(.failure(.badRequest("Body must be a PTZ command, e.g. {\"op\":\"left\",\"speed\":32}")))
            }
            return await run { try await api.ptz(id, channel: channel, command); return .accepted() }
        case ("GET", "recordings"):
            guard let query = Self.recordingQuery(from: request.query) else {
                return .response(.failure(.badRequest("from and to (ISO-8601) are required")))
            }
            return await run {
                let page = try await api.recordings(id, channel: channel, query)
                return .envelope(page.items, meta: APIMeta(count: page.items.count, nextCursor: page.nextCursor))
            }
        case ("GET", "settings"):
            return await run { .envelope(try await api.settings(id, channel: channel)) }
        case ("PATCH", "settings"):
            guard let patch = try? APIJSON.decoder.decode(ChannelSettingsPatch.self, from: request.body) else {
                return .response(.failure(.badRequest("Body must be a settings patch")))
            }
            return await run { .envelope(try await api.updateSettings(id, channel: channel, patch)) }
        default:
            return notFound
        }
    }

    /// Run an API call, mapping a thrown `APIError` (or anything else) to a
    /// consistent error response.
    private func run(_ work: () async throws -> HTTPResponse) async -> Outcome {
        do {
            return .response(try await work())
        } catch let error as APIError {
            return .response(.failure(error))
        } catch {
            return .response(.failure(.upstreamUnreachable()))
        }
    }

    private func badChannel() -> Outcome {
        .response(.failure(.badRequest("Channel must be an integer")))
    }

    /// Fill in the Reolens-hosted MJPEG URL (the facade owns its base URL; the
    /// adapter can't know it). Points at the live `/mjpeg` multipart endpoint —
    /// the universal Home Assistant live-view path.
    private func fillStreamURLs(_ ref: StreamRef, id: CameraID, channel: Int) -> StreamRef {
        guard let base = publicBaseURL else { return ref }
        let mjpeg = URL(string: "\(base)\(APIVersion.pathPrefix)/cameras/\(id)/channels/\(channel)/mjpeg")
        return StreamRef(quality: ref.quality, codec: ref.codec, mjpeg: mjpeg, rtsp: ref.rtsp, hls: ref.hls)
    }

    /// A best-effort MJPEG frame source: polls `snapshot` on an interval until
    /// the consumer disconnects (~1.4 fps — a gentle preview/motion stream that
    /// doesn't hammer the camera, AGENTS.md §10). Reuses the already-
    /// authenticated, credential-safe snapshot fetch rather than proxying RTSP.
    private func mjpegStream(id: CameraID, channel: Int) -> AsyncStream<Data> {
        let api = self.api
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let image = try await api.snapshot(id, channel: channel)
                        continuation.yield(image.bytes)
                    } catch {
                        break   // camera unreachable — end the stream cleanly
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Auth

    static func authorized(_ request: HTTPRequest, token: String) -> Bool {
        guard let header = request.header("authorization") else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        return constantTimeEqual(String(header.dropFirst(prefix.count)), token)
    }

    /// Length-checked constant-time comparison (token length is fixed, so the
    /// early length check leaks nothing useful).
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - Query decoding

    static func recordingQuery(from query: [String: String]) -> RecordingQuery? {
        guard let fromRaw = query["from"], let toRaw = query["to"],
              let from = parseDate(fromRaw), let to = parseDate(toRaw) else { return nil }
        let types = query["types"]?
            .split(separator: ",")
            .compactMap { DetectionKind(rawValue: String($0)) }
        let limit = query["limit"].flatMap(Int.init)
        return RecordingQuery(from: from, to: to, types: types?.isEmpty == true ? nil : types, cursor: query["cursor"], limit: limit)
    }

    static func eventFilter(from query: [String: String]) -> EventFilter {
        let detections = query["detections"]?
            .split(separator: ",")
            .compactMap { DetectionKind(rawValue: String($0)) }
        return EventFilter(
            cameraID: query["cameraId"],
            channel: query["channel"].flatMap(Int.init),
            detections: (detections?.isEmpty == true) ? nil : detections
        )
    }

    static func parseDate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// Compact discovery document served at `/v1/openapi.json`. The full OpenAPI
/// schema lives in `docs/api/openapi.yaml`.
private struct OpenAPIDescriptor: Encodable {
    let openapi = "3.1.0"
    let info = Info()
    let paths = [
        "GET /v1/health", "GET /v1/cameras", "GET /v1/cameras/{id}",
        "GET /v1/cameras/{id}/channels",
        "GET /v1/cameras/{id}/diagnostics",
        "POST /v1/cameras/{id}/reboot",
        "GET /v1/cameras/{id}/channels/{ch}/snapshot",
        "GET /v1/cameras/{id}/channels/{ch}/stream",
        "GET /v1/cameras/{id}/channels/{ch}/mjpeg",
        "POST /v1/cameras/{id}/channels/{ch}/ptz",
        "GET /v1/cameras/{id}/channels/{ch}/recordings",
        "GET /v1/cameras/{id}/channels/{ch}/recordings/{rid}/download",
        "GET|PATCH /v1/cameras/{id}/channels/{ch}/settings",
        "GET /v1/events",
    ]

    struct Info: Encodable {
        let title = "Reolens Local API"
        let version = APIVersion.current
    }

    enum CodingKeys: String, CodingKey {
        case openapi, info
        case paths = "x-paths"
    }
}

import Foundation
import ReolensCore

/// A minimal MCP server (JSON-RPC 2.0, newline-delimited) over any
/// ``CameraAPI``. Hand-rolled like the HTTP facade so the package stays
/// dependency-free; the stdio byte loop lives in the executable shell,
/// which feeds one line at a time to ``handle(line:)``.
///
/// Lifecycle: `initialize` → `notifications/initialized` → `tools/list` /
/// `tools/call`. Tool *execution* failures return an `isError` result
/// (never raw error text — only the contract's sanitized code/message);
/// malformed requests return JSON-RPC errors.
public struct MCPServer: Sendable {
    private let api: any CameraAPI
    private let serverVersion: String

    /// Protocol versions this server will echo back when a client asks.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultProtocolVersion = "2025-06-18"

    public init(api: any CameraAPI, serverVersion: String = "0.10.0") {
        self.api = api
        self.serverVersion = serverVersion
    }

    /// Handle one input line. Returns the response line to write, or nil
    /// for notifications (which never get a response).
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let request = JSONValue.parse(trimmed), case .object = request else {
            return Self.errorResponse(id: .null, code: -32700, message: "Parse error")
        }
        guard request["jsonrpc"]?.stringValue == "2.0", let method = request["method"]?.stringValue else {
            return Self.errorResponse(id: request["id"] ?? .null, code: -32600, message: "Invalid request")
        }
        let id = request["id"]
        let isNotification = id == nil || id == .null

        switch method {
        case "initialize":
            guard !isNotification, let id else { return nil }
            return Self.resultResponse(id: id, result: initializeResult(params: request["params"]))
        case "ping":
            guard !isNotification, let id else { return nil }
            return Self.resultResponse(id: id, result: [:])
        case "tools/list":
            guard !isNotification, let id else { return nil }
            return Self.resultResponse(id: id, result: ["tools": .array(MCPTools.all.map(\.descriptor))])
        case "tools/call":
            guard !isNotification, let id else { return nil }
            return await callTool(id: id, params: request["params"])
        default:
            if method.hasPrefix("notifications/") { return nil }
            guard !isNotification, let id else { return nil }
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.defaultProtocolVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "reolens", "version": .string(serverVersion)],
        ]
    }

    // MARK: - JSON-RPC framing

    static func resultResponse(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).serialized()
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .int(code), "message": .string(message)],
        ]).serialized()
    }

    static func toolResult(id: JSONValue, content: [JSONValue], isError: Bool = false) -> String {
        var result: [String: JSONValue] = ["content": .array(content)]
        if isError { result["isError"] = true }
        return resultResponse(id: id, result: .object(result))
    }

    static func textContent(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }

    /// Encode a contract DTO as the JSON text agents read. DTOs are
    /// already credential-free by design (AGENTS.md §3).
    static func encodeDTO<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Render a thrown error as tool-error content. Only the contract's
    /// sanitized ``APIError`` code/message pass through; anything else
    /// collapses to a generic upstream failure so raw transport text
    /// (which can embed URLs) never reaches an agent transcript.
    static func errorText(_ error: any Error) -> String {
        if let apiError = error as? APIError {
            return JSONValue.object([
                "code": .string(apiError.code),
                "message": .string(apiError.message),
            ]).serialized()
        }
        if let toolError = error as? MCPToolFailure {
            return JSONValue.object([
                "code": .string(toolError.code),
                "message": .string(toolError.message),
            ]).serialized()
        }
        return JSONValue.object([
            "code": "upstream_unreachable",
            "message": "The camera could not be reached",
        ]).serialized()
    }
}

/// A tool-level failure with a stable code (bad arguments, missing
/// confirmation). Rendered as an `isError` tool result.
struct MCPToolFailure: Error {
    let code: String
    let message: String

    static func invalid(_ message: String) -> MCPToolFailure {
        MCPToolFailure(code: "invalid_arguments", message: message)
    }
}

// MARK: - Tool dispatch

extension MCPServer {
    private func callTool(id: JSONValue, params: JSONValue?) async -> String {
        guard let name = params?["name"]?.stringValue else {
            return Self.errorResponse(id: id, code: -32602, message: "tools/call requires a tool name")
        }
        guard MCPTools.tool(named: name) != nil else {
            return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments = params?["arguments"]?.objectValue ?? [:]
        do {
            let content = try await execute(tool: name, arguments: arguments)
            return Self.toolResult(id: id, content: content)
        } catch {
            return Self.toolResult(id: id, content: [Self.textContent(Self.errorText(error))], isError: true)
        }
    }

    private func execute(tool name: String, arguments: [String: JSONValue]) async throws -> [JSONValue] {
        switch name {
        case "system_health":
            return [Self.textContent(Self.encodeDTO(try await api.health()))]
        case "cameras_list":
            return [Self.textContent(Self.encodeDTO(try await api.cameras()))]
        case "camera_get":
            let camera = try await resolve(arguments)
            return [Self.textContent(Self.encodeDTO(try await api.camera(camera.id)))]
        case "camera_channels":
            let camera = try await resolve(arguments)
            return [Self.textContent(Self.encodeDTO(try await api.channels(camera.id)))]
        case "camera_diagnostics":
            let camera = try await resolve(arguments)
            return [Self.textContent(Self.encodeDTO(try await api.diagnostics(camera.id)))]
        case "camera_snapshot":
            let camera = try await resolve(arguments)
            let image = try await api.snapshot(camera.id, channel: channel(arguments))
            return [[
                "type": "image",
                "data": .string(image.bytes.base64EncodedString()),
                "mimeType": .string(image.contentType),
            ]]
        case "camera_stream":
            let camera = try await resolve(arguments)
            let quality = try streamQuality(arguments)
            let ref = try await api.streamRef(camera.id, channel: channel(arguments), quality: quality)
            return [Self.textContent(Self.encodeDTO(ref))]
        case "camera_ptz":
            let camera = try await resolve(arguments)
            let command = try ptzCommand(arguments)
            try await api.ptz(camera.id, channel: channel(arguments), command)
            if let durationMs = arguments["durationMs"]?.intValue, durationMs > 0, command.op != .stop {
                try await Task.sleep(for: .milliseconds(Int64(durationMs)))
                try await api.ptz(camera.id, channel: channel(arguments), PTZCommand(op: .stop))
                return [Self.textContent(#"{"accepted":true,"stopped":true}"#)]
            }
            return [Self.textContent(#"{"accepted":true}"#)]
        case "camera_reboot":
            guard arguments["confirm"]?.boolValue == true else {
                throw MCPToolFailure(code: "confirmation_required", message: "Reboot requires \"confirm\": true")
            }
            let camera = try await resolve(arguments)
            try await api.reboot(camera.id)
            return [Self.textContent(#"{"accepted":true}"#)]
        case "camera_recordings":
            let camera = try await resolve(arguments)
            let query = try recordingQuery(arguments)
            let page = try await api.recordings(camera.id, channel: channel(arguments), query)
            return [Self.textContent(Self.encodeDTO(page))]
        case "camera_recording_download":
            let camera = try await resolve(arguments)
            guard let recording = arguments["recording"]?.stringValue, !recording.isEmpty else {
                throw MCPToolFailure.invalid("recording id is required")
            }
            let ref = try await api.recordingDownload(camera.id, recording)
            return [Self.textContent(Self.encodeDTO(ref))]
        case "camera_settings_get":
            let camera = try await resolve(arguments)
            return [Self.textContent(Self.encodeDTO(try await api.settings(camera.id, channel: channel(arguments))))]
        case "camera_settings_update":
            let camera = try await resolve(arguments)
            let patch = settingsPatch(arguments)
            let result = try await api.updateSettings(camera.id, channel: channel(arguments), patch)
            return [Self.textContent(Self.encodeDTO(result))]
        default:
            throw MCPToolFailure.invalid("Unknown tool: \(name)")
        }
    }

    // MARK: Argument helpers

    private func resolve(_ arguments: [String: JSONValue]) async throws -> CameraResource {
        guard let selector = arguments["camera"]?.stringValue, !selector.isEmpty else {
            throw MCPToolFailure.invalid("camera (id or exact display name) is required")
        }
        return try await api.resolveCamera(selector)
    }

    private func channel(_ arguments: [String: JSONValue]) -> Int {
        arguments["channel"]?.intValue ?? 0
    }

    private func streamQuality(_ arguments: [String: JSONValue]) throws -> StreamQuality {
        guard let raw = arguments["quality"]?.stringValue else { return .sub }
        guard let quality = StreamQuality(rawValue: raw) else {
            throw MCPToolFailure.invalid("quality must be main or sub")
        }
        return quality
    }

    private func ptzCommand(_ arguments: [String: JSONValue]) throws -> PTZCommand {
        guard let raw = arguments["op"]?.stringValue, let op = PTZOp(rawValue: raw) else {
            throw MCPToolFailure.invalid("op must be one of: \(PTZOp.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if op == .toPreset, arguments["presetID"]?.intValue == nil {
            throw MCPToolFailure.invalid("presetID is required for toPreset")
        }
        return PTZCommand(op: op, speed: arguments["speed"]?.intValue, presetID: arguments["presetID"]?.intValue)
    }

    private func recordingQuery(_ arguments: [String: JSONValue]) throws -> RecordingQuery {
        guard let fromRaw = arguments["from"]?.stringValue, let from = APITime.parseISO8601(fromRaw),
              let toRaw = arguments["to"]?.stringValue, let to = APITime.parseISO8601(toRaw) else {
            throw MCPToolFailure.invalid("from and to (ISO-8601) are required")
        }
        var types: [DetectionKind]?
        if let rawTypes = arguments["types"]?.arrayValue {
            types = try rawTypes.map { value in
                guard let raw = value.stringValue, let kind = DetectionKind(rawValue: raw) else {
                    throw MCPToolFailure.invalid("types must be detection categories: \(DetectionKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return kind
            }
        }
        return RecordingQuery(
            from: from, to: to, types: types,
            cursor: arguments["cursor"]?.stringValue,
            limit: arguments["limit"]?.intValue
        )
    }

    private func settingsPatch(_ arguments: [String: JSONValue]) -> ChannelSettingsPatch {
        var osd: OSDSettings?
        if arguments["osdShowName"] != nil || arguments["osdShowDate"] != nil {
            osd = OSDSettings(
                showName: arguments["osdShowName"]?.boolValue,
                showDate: arguments["osdShowDate"]?.boolValue
            )
        }
        return ChannelSettingsPatch(
            name: arguments["name"]?.stringValue,
            osd: osd,
            notificationsEnabled: arguments["notificationsEnabled"]?.boolValue
        )
    }
}

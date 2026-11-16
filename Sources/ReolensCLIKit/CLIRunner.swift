import Foundation
import ReolensCore
import ReolensClient
import ReolensMCP

/// The outcome of one CLI invocation: process exit code plus the exact
/// stdout/stderr text. Returning values instead of printing keeps the
/// whole surface unit-testable; the executable shell only writes bytes.
public struct CLIOutcome: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Exit codes (also advertised in the `features` manifest).
public enum CLIExit {
    /// Success.
    public static let ok: Int32 = 0
    /// The API (or a camera behind it) returned an error.
    public static let apiError: Int32 = 1
    /// Bad command line.
    public static let usage: Int32 = 2
    /// The Reolens server could not be reached at all.
    public static let unreachable: Int32 = 3
}

/// Executes a parsed ``CLICommand`` against any ``CameraAPI`` and renders
/// the result. JSON mode emits `{ok, command, data}` envelopes on stdout
/// and `{ok:false, command, error}` on stderr; text mode renders compact
/// human lines. Snapshot bytes go to the requested file, never stdout.
public struct CLIRunner: Sendable {
    public init() {}

    /// - Parameter eventSink: when provided, `events` renders each event
    ///   to the sink as it arrives (the executable wires this to stdout
    ///   so following is truly live); otherwise events are collected
    ///   into the outcome (bounded tests, `--max-events`).
    public func run(_ command: CLICommand, config: CLIConfig, api: any CameraAPI, eventSink: (@Sendable (String) -> Void)? = nil) async -> CLIOutcome {
        do {
            switch command {
            case .version:
                return success(command, config, payload: ["version": .string(reolensCLIVersion)], text: "reolens-cli \(reolensCLIVersion)")
            case .features:
                return success(command, config, payload: CLIHelp.featuresManifest, text: pretty(CLIHelp.featuresManifest))
            case .health:
                let health = try await api.health()
                return success(command, config, payload: dto(health), text: TextRender.health(health))
            case .doctor:
                return try await doctor(command, config, api)
            case .camerasList:
                let cameras = try await api.cameras()
                return success(command, config, payload: dto(cameras), text: TextRender.cameras(cameras))
            case .events(let maxEvents, let detections):
                return try await events(command, config, api, maxEvents: maxEvents, detections: detections, sink: eventSink)
            default:
                return try await cameraCommand(command, config, api)
            }
        } catch {
            return failure(command, config, error)
        }
    }

    // MARK: - Camera-scoped commands

    private func cameraCommand(_ command: CLICommand, _ config: CLIConfig, _ api: any CameraAPI) async throws -> CLIOutcome {
        guard let selector = config.camera, !selector.isEmpty else {
            return CLIOutcome(exitCode: CLIExit.usage, stderr: "\(command.displayName) requires --camera <id-or-name>\n")
        }
        let camera = try await api.resolveCamera(selector)
        let channel = config.channel

        switch command {
        case .camerasShow:
            let fetched = try await api.camera(camera.id)
            return success(command, config, payload: dto(fetched), text: TextRender.cameras([fetched]))
        case .channels, .capabilities:
            let channels = try await api.channels(camera.id)
            return success(command, config, payload: dto(channels), text: TextRender.channels(channels))
        case .diagnostics:
            let diag = try await api.diagnostics(camera.id)
            return success(command, config, payload: dto(diag), text: TextRender.diagnostics(diag))
        case .snapshot(let file):
            let image = try await api.snapshot(camera.id, channel: channel)
            try writeFile(image.bytes, to: file)
            let payload: JSONValue = [
                "file": .string(file),
                "bytes": .int(image.bytes.count),
                "contentType": .string(image.contentType),
                "camera": .string(camera.id),
                "channel": .int(channel),
            ]
            return success(command, config, payload: payload, text: "Wrote \(image.bytes.count) bytes to \(file)")
        case .stream(let quality):
            let ref = try await api.streamRef(camera.id, channel: channel, quality: quality)
            return success(command, config, payload: dto(ref), text: pretty(dto(ref)))
        case .ptz(let ptz, let durationMs):
            try await api.ptz(camera.id, channel: channel, ptz)
            var stopped = false
            if let durationMs, durationMs > 0, ptz.op != .stop {
                try await Task.sleep(for: .milliseconds(Int64(durationMs)))
                try await api.ptz(camera.id, channel: channel, PTZCommand(op: .stop))
                stopped = true
            }
            return success(command, config, payload: ["accepted": true, "stopped": .bool(stopped)], text: stopped ? "Moved, then stopped" : "Accepted")
        case .reboot:
            try await api.reboot(camera.id)
            return success(command, config, payload: ["accepted": true], text: "Reboot sent (camera will be offline for 30-60s)")
        case .recordingsList(let query):
            let page = try await api.recordings(camera.id, channel: channel, query)
            return success(command, config, payload: dto(page), text: TextRender.recordings(page))
        case .recordingsDownload(let id):
            let ref = try await api.recordingDownload(camera.id, id)
            return success(command, config, payload: dto(ref), text: pretty(dto(ref)))
        case .settingsGet:
            let settings = try await api.settings(camera.id, channel: channel)
            return success(command, config, payload: dto(settings), text: pretty(dto(settings)))
        case .settingsSet(let patch):
            let settings = try await api.updateSettings(camera.id, channel: channel, patch)
            return success(command, config, payload: dto(settings), text: pretty(dto(settings)))
        default:
            // Non-camera commands are handled in `run`; reaching here is a
            // programming error, surfaced as usage rather than a crash.
            return CLIOutcome(exitCode: CLIExit.usage, stderr: "unhandled command: \(command.displayName)\n")
        }
    }

    private func doctor(_ command: CLICommand, _ config: CLIConfig, _ api: any CameraAPI) async throws -> CLIOutcome {
        let health = try await api.health()
        let cameras = try await api.cameras()
        var entries: [JSONValue] = []
        var lines: [String] = [TextRender.health(health)]
        for camera in cameras {
            do {
                let diag = try await api.diagnostics(camera.id)
                entries.append(dto(diag))
                lines.append("\(camera.displayName): \(TextRender.diagnostics(diag))")
            } catch let error as APIError {
                entries.append(["id": .string(camera.id), "error": .string(error.code)])
                lines.append("\(camera.displayName): diagnostics unavailable (\(error.code))")
            }
        }
        let payload: JSONValue = ["health": dto(health), "cameras": .array(entries)]
        return success(command, config, payload: payload, text: lines.joined(separator: "\n"))
    }

    private func events(_ command: CLICommand, _ config: CLIConfig, _ api: any CameraAPI, maxEvents: Int?, detections: [DetectionKind]?, sink: (@Sendable (String) -> Void)?) async throws -> CLIOutcome {
        var filter = EventFilter(detections: detections)
        if let selector = config.camera, !selector.isEmpty {
            filter.cameraID = try await api.resolveCamera(selector).id
        }
        if config.channelExplicit {
            filter.channel = config.channel
        }
        // With a sink, each event is emitted as it arrives (live follow);
        // without one, events collect into the outcome. With no
        // --max-events this follows until the server ends the stream
        // (Ctrl-C terminates the process as usual).
        var rendered: [String] = []
        var count = 0
        for await event in api.events(filter) {
            let line = config.output == .json ? dto(event).serialized() : TextRender.event(event)
            if let sink {
                sink(line + "\n")
            } else {
                rendered.append(line)
            }
            count += 1
            if let maxEvents, count >= maxEvents { break }
        }
        return CLIOutcome(exitCode: CLIExit.ok, stdout: rendered.isEmpty ? "" : rendered.joined(separator: "\n") + "\n")
    }

    // MARK: - Rendering + errors

    private func success(_ command: CLICommand, _ config: CLIConfig, payload: JSONValue, text: String) -> CLIOutcome {
        switch config.output {
        case .text:
            return CLIOutcome(exitCode: CLIExit.ok, stdout: text + "\n")
        case .json:
            let envelope: JSONValue = ["ok": true, "command": .string(command.displayName), "data": payload]
            return CLIOutcome(exitCode: CLIExit.ok, stdout: envelope.serialized() + "\n")
        }
    }

    private func failure(_ command: CLICommand, _ config: CLIConfig, _ error: any Error) -> CLIOutcome {
        let (code, message, exit): (String, String, Int32)
        switch error {
        case let apiError as APIError:
            (code, message, exit) = (apiError.code, apiError.message, CLIExit.apiError)
        case ReolensClientError.unreachable(let reason):
            (code, message, exit) = ("unreachable", "\(reason). Is Reolens running with Settings -> Local API enabled?", CLIExit.unreachable)
        case ReolensClientError.malformedResponse(let reason):
            (code, message, exit) = ("malformed_response", reason, CLIExit.apiError)
        case is CancellationError:
            (code, message, exit) = ("cancelled", "Cancelled", CLIExit.apiError)
        default:
            // Never render raw error text: transport errors can embed URLs.
            (code, message, exit) = ("upstream_unreachable", "The camera could not be reached", CLIExit.apiError)
        }
        switch config.output {
        case .text:
            return CLIOutcome(exitCode: exit, stderr: "error [\(code)]: \(message)\n")
        case .json:
            let envelope: JSONValue = [
                "ok": false,
                "command": .string(command.displayName),
                "error": ["code": .string(code), "message": .string(message)],
            ]
            return CLIOutcome(exitCode: exit, stderr: envelope.serialized() + "\n")
        }
    }

    /// Encode a contract DTO, then re-parse so it can nest in envelopes.
    private func dto<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return parsed
    }

    private func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return value.serialized() }
        return text
    }

    private func writeFile(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw APIError(code: "write_failed", message: "Could not write \(path)", status: 500)
        }
    }
}

/// Compact one-line-per-item text renderings. Hosts are omitted on
/// purpose (JSON mode carries what the API returns; text mode models
/// the redact-before-sharing habit).
enum TextRender {
    static func health(_ health: SystemHealth) -> String {
        var parts = ["API \(health.apiVersion)", "\(health.cameraCount) cameras, \(health.onlineCount) online"]
        if let app = health.appVersion { parts.insert("app \(app)", at: 1) }
        if let hub = health.hubRunning { parts.append("hub: \(hub ? "on" : "off")") }
        return parts.joined(separator: " · ")
    }

    static func cameras(_ cameras: [CameraResource]) -> String {
        if cameras.isEmpty { return "No cameras configured" }
        return cameras.map { camera in
            "\(camera.displayName)  \(camera.id)  \(camera.kind.rawValue)  \(camera.online ? "online" : "offline")"
        }.joined(separator: "\n")
    }

    static func channels(_ channels: [ChannelResource]) -> String {
        if channels.isEmpty { return "No channels" }
        return channels.map { channel in
            var caps: [String] = []
            if channel.capabilities.ptz { caps.append("ptz") }
            if channel.capabilities.talk { caps.append("talk") }
            if !channel.capabilities.ai.isEmpty {
                caps.append("ai:" + channel.capabilities.ai.map(\.rawValue).joined(separator: ","))
            }
            if let battery = channel.battery { caps.append("battery \(battery.percent)%") }
            return "ch\(channel.id) \(channel.name ?? "-") \(channel.online ? "online" : "offline") \(caps.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    static func diagnostics(_ diag: CameraDiagnostics) -> String {
        var parts = [diag.connectionStatus.rawValue]
        if let transport = diag.controlTransport { parts.append("via \(transport.rawValue)") }
        parts.append("\(diag.channelCount) channel(s)")
        parts.append("\(diag.eventCount) event(s)")
        var line = parts.joined(separator: " · ")
        if let error = diag.lastError { line += "\n  last error: \(error)" }
        return line
    }

    static func recordings(_ page: RecordingPage) -> String {
        if page.items.isEmpty { return "No recordings in window" }
        var lines = page.items.map { item in
            "\(APITime.formatISO8601(item.start))  \(item.id)  \(Int(item.durationSeconds))s  \(item.triggers.map(\.rawValue).joined(separator: ","))"
        }
        if let cursor = page.nextCursor { lines.append("next: --cursor \(cursor)") }
        return lines.joined(separator: "\n")
    }

    static func event(_ event: EventResource) -> String {
        let what = event.detection?.rawValue ?? event.kind.rawValue
        return "\(APITime.formatISO8601(event.timestamp))  \(event.cameraID) ch\(event.channel)  \(what)"
    }
}

import Foundation
import ReolensCore

/// Output rendering mode. JSON (envelopes) is the default, matching
/// reolink-cli; text is the human rendering.
public enum CLIOutputFormat: String, Sendable, CaseIterable {
    case json
    case text
}

/// Connection + selection options shared by every command. Built from
/// environment defaults overlaid with flags (flags win).
public struct CLIConfig: Sendable, Equatable {
    /// Local API root (no `/v1` suffix). Default `http://127.0.0.1:8443`.
    public var baseURL: URL
    /// Bearer token. Sourced from `REOLENS_API_TOKEN` or `--token`;
    /// never printed or logged.
    public var token: String?
    public var output: CLIOutputFormat
    /// Camera selector (id or exact display name) from `--camera`.
    public var camera: String?
    /// Channel index from `--channel` (default 0).
    public var channel: Int
    /// Whether `--channel` was passed explicitly. The events filter uses
    /// this so the default 0 doesn't silently narrow the stream.
    public var channelExplicit: Bool

    public init(baseURL: URL, token: String?, output: CLIOutputFormat = .json, camera: String? = nil, channel: Int = 0, channelExplicit: Bool = false) {
        self.baseURL = baseURL
        self.token = token
        self.output = output
        self.camera = camera
        self.channel = channel
        self.channelExplicit = channelExplicit
    }

    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8443")!

    public static func fromEnvironment(_ env: [String: String]) -> CLIConfig {
        let url = env["REOLENS_API_URL"].flatMap { URL(string: $0) } ?? defaultBaseURL
        return CLIConfig(baseURL: url, token: env["REOLENS_API_TOKEN"])
    }
}

/// One parsed command. Camera/channel selection lives on ``CLIConfig``;
/// commands carry only their own arguments.
public enum CLICommand: Sendable, Equatable {
    case health
    case doctor
    case features
    case version
    case camerasList
    case camerasShow
    case channels
    case capabilities
    case diagnostics
    case snapshot(file: String)
    case stream(quality: StreamQuality)
    case ptz(PTZCommand, durationMs: Int?)
    case reboot
    case recordingsList(RecordingQuery)
    case recordingsDownload(id: String)
    case settingsGet
    case settingsSet(ChannelSettingsPatch)
    case events(maxEvents: Int?, detections: [DetectionKind]?)

    /// Stable command name used in output envelopes (`"cameras list"`).
    public var displayName: String {
        switch self {
        case .health: "health"
        case .doctor: "doctor"
        case .features: "features"
        case .version: "version"
        case .camerasList: "cameras list"
        case .camerasShow: "cameras show"
        case .channels: "channels"
        case .capabilities: "capabilities"
        case .diagnostics: "diagnostics"
        case .snapshot: "snapshot"
        case .stream: "stream"
        case .ptz: "ptz"
        case .reboot: "reboot"
        case .recordingsList: "recordings list"
        case .recordingsDownload: "recordings download"
        case .settingsGet: "settings get"
        case .settingsSet: "settings set"
        case .events: "events"
        }
    }

    /// Whether the command needs `--camera`.
    public var requiresCamera: Bool {
        switch self {
        case .health, .doctor, .features, .version, .camerasList, .events: false
        default: true
        }
    }
}

/// The result of parsing argv.
public enum CLIParse: Sendable, Equatable {
    case run(CLIConfig, CLICommand)
    case mcpServer(CLIConfig)
    case help
    /// Usage failure (exit 2). Message is shown with the usage hint.
    case failure(String)
}

// MARK: - Parsing

public extension CLIParse {
    /// Parse arguments (excluding the program name). Flags may appear in
    /// any position and in `--flag value` or `--flag=value` form.
    static func parse(argv: [String], env: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) -> CLIParse {
        if argv.isEmpty || argv[0] == "help" || argv[0] == "--help" || argv[0] == "-h" {
            return .help
        }
        let tokens: Tokens
        switch partition(argv) {
        case .help: return .help
        case .failure(let message): return .failure(message)
        case .tokens(let parsed): tokens = parsed
        }
        let config: CLIConfig
        switch buildConfig(flags: tokens.flags, env: env) {
        case .failure(let message): return .failure(message)
        case .success(let built): config = built
        }
        guard let head = tokens.positionals.first else { return .help }
        return dispatch(
            head: head, tail: Array(tokens.positionals.dropFirst()),
            flags: tokens.flags, bools: tokens.bools, config: config, now: now
        )
    }

    private struct Tokens {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var bools: Set<String> = []
    }

    private enum Partition {
        case tokens(Tokens)
        case help
        case failure(String)
    }

    /// Split argv into positionals, valued flags, and boolean flags.
    private static func partition(_ argv: [String]) -> Partition {
        var tokens = Tokens()
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token == "--help" || token == "-h" {
                return .help
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    tokens.flags[String(body[..<equals])] = String(body[body.index(after: equals)...])
                } else if body == "yes" {
                    tokens.bools.insert(body)
                } else {
                    guard index + 1 < argv.count, !argv[index + 1].hasPrefix("--") else {
                        return .failure("--\(body) requires a value")
                    }
                    tokens.flags[body] = argv[index + 1]
                    index += 1
                }
            } else {
                tokens.positionals.append(token)
            }
            index += 1
        }
        return .tokens(tokens)
    }

    /// Global config: environment defaults, then flags on top.
    private static func buildConfig(flags: [String: String], env: [String: String]) -> Parsed<CLIConfig> {
        var config = CLIConfig.fromEnvironment(env)
        if let raw = flags["api-url"] {
            guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                return .failure("--api-url must be an http(s) URL")
            }
            config.baseURL = url
        }
        if let token = flags["token"] { config.token = token }
        if let raw = flags["output"] {
            guard let format = CLIOutputFormat(rawValue: raw) else {
                return .failure("--output must be json or text")
            }
            config.output = format
        }
        config.camera = flags["camera"] ?? env["REOLENS_CAMERA"]
        if let raw = flags["channel"] {
            guard let channel = Int(raw), channel >= 0 else {
                return .failure("--channel must be a non-negative integer")
            }
            config.channel = channel
            config.channelExplicit = true
        }
        return .success(config)
    }

    /// Argument-free commands, keyed by their first word. Whether each
    /// needs `--camera` comes from `CLICommand.requiresCamera`.
    private static let simpleCommands: [String: CLICommand] = [
        "health": .health, "doctor": .doctor, "features": .features, "version": .version,
        "channels": .channels, "capabilities": .capabilities, "diagnostics": .diagnostics,
    ]

    private static func dispatch(head: String, tail: [String], flags: [String: String], bools: Set<String>, config: CLIConfig, now: Date) -> CLIParse {
        if head == "mcp-server" { return .mcpServer(config) }
        if let simple = simpleCommands[head] {
            return simple.requiresCamera ? cameraCommand(config, simple) : .run(config, simple)
        }
        switch head {
        case "cameras": return parseCameras(tail: tail, config: config)
        case "snapshot": return parseSnapshot(flags: flags, config: config)
        case "stream": return parseStream(flags: flags, config: config)
        case "ptz":
            switch parsePTZ(tail: tail, flags: flags) {
            case .success(let command): return cameraCommand(config, command)
            case .failure(let message): return .failure(message)
            }
        case "reboot":
            guard bools.contains("yes") else {
                return .failure("reboot restarts the camera (30-60s offline); pass --yes to confirm")
            }
            return cameraCommand(config, .reboot)
        case "recordings": return parseRecordings(tail: tail, flags: flags, config: config, now: now)
        case "settings": return parseSettings(tail: tail, flags: flags, config: config)
        case "events": return parseEvents(flags: flags, config: config)
        default: return .failure("unknown command: \(head)")
        }
    }

    private static func parseCameras(tail: [String], config: CLIConfig) -> CLIParse {
        switch tail.first ?? "list" {
        case "list": return .run(config, .camerasList)
        case "show": return cameraCommand(config, .camerasShow)
        default: return .failure("cameras expects list or show")
        }
    }

    private static func parseSnapshot(flags: [String: String], config: CLIConfig) -> CLIParse {
        guard let file = flags["file"], !file.isEmpty else {
            return .failure("snapshot requires --file <path>")
        }
        return cameraCommand(config, .snapshot(file: file))
    }

    private static func parseStream(flags: [String: String], config: CLIConfig) -> CLIParse {
        if let raw = flags["quality"], StreamQuality(rawValue: raw) == nil {
            return .failure("--quality must be main or sub")
        }
        let quality = flags["quality"].flatMap { StreamQuality(rawValue: $0) } ?? .sub
        return cameraCommand(config, .stream(quality: quality))
    }

    private static func parseRecordings(tail: [String], flags: [String: String], config: CLIConfig, now: Date) -> CLIParse {
        switch tail.first ?? "list" {
        case "list":
            switch parseRecordingQuery(flags: flags, now: now) {
            case .success(let query): return cameraCommand(config, .recordingsList(query))
            case .failure(let message): return .failure(message)
            }
        case "download":
            guard tail.count >= 2 else { return .failure("recordings download requires a recording id") }
            return cameraCommand(config, .recordingsDownload(id: tail[1]))
        default:
            return .failure("recordings expects list or download")
        }
    }

    private static func parseSettings(tail: [String], flags: [String: String], config: CLIConfig) -> CLIParse {
        switch tail.first ?? "get" {
        case "get": return cameraCommand(config, .settingsGet)
        case "set":
            switch parseSettingsPatch(flags: flags) {
            case .success(let patch): return cameraCommand(config, .settingsSet(patch))
            case .failure(let message): return .failure(message)
            }
        default:
            return .failure("settings expects get or set")
        }
    }

    private static func parseEvents(flags: [String: String], config: CLIConfig) -> CLIParse {
        var maxEvents: Int?
        if let raw = flags["max-events"] {
            guard let value = Int(raw), value > 0 else { return .failure("--max-events must be a positive integer") }
            maxEvents = value
        }
        switch parseTypes(flags["types"]) {
        case .success(let types): return .run(config, .events(maxEvents: maxEvents, detections: types))
        case .failure(let message): return .failure(message)
        }
    }

    private static func cameraCommand(_ config: CLIConfig, _ command: CLICommand) -> CLIParse {
        guard let camera = config.camera, !camera.isEmpty else {
            return .failure("\(command.displayName) requires --camera <id-or-name>")
        }
        return .run(config, command)
    }

    private enum Parsed<T> { case success(T), failure(String) }

    private static func parsePTZ(tail: [String], flags: [String: String]) -> Parsed<CLICommand> {
        guard let opRaw = tail.first, let op = PTZOp(rawValue: opRaw) else {
            return .failure("ptz requires an op: \(PTZOp.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var durationMs: Int?
        if let raw = flags["duration-ms"] {
            guard let value = Int(raw), value > 0 else { return .failure("--duration-ms must be a positive integer") }
            durationMs = value
        }
        let preset = flags["preset"].flatMap(Int.init)
        if op == .toPreset, preset == nil {
            return .failure("ptz toPreset requires --preset <id>")
        }
        let command = PTZCommand(op: op, speed: flags["speed"].flatMap(Int.init), presetID: preset)
        return .success(.ptz(command, durationMs: durationMs))
    }

    private static func parseRecordingQuery(flags: [String: String], now: Date) -> Parsed<RecordingQuery> {
        let from: Date
        let to: Date
        if let since = flags["since"] {
            guard let seconds = parseDuration(since) else {
                return .failure("--since must look like 30m, 24h, or 7d")
            }
            to = now
            from = now.addingTimeInterval(-seconds)
        } else if let fromRaw = flags["from"], let toRaw = flags["to"],
                  let parsedFrom = APITime.parseISO8601(fromRaw), let parsedTo = APITime.parseISO8601(toRaw) {
            from = parsedFrom
            to = parsedTo
        } else {
            return .failure("recordings list requires --since <duration> or --from/--to (ISO-8601)")
        }
        switch parseTypes(flags["types"]) {
        case .failure(let message): return .failure(message)
        case .success(let types):
            return .success(RecordingQuery(
                from: from, to: to, types: types,
                cursor: flags["cursor"],
                limit: flags["limit"].flatMap(Int.init)
            ))
        }
    }

    private static func parseSettingsPatch(flags: [String: String]) -> Parsed<ChannelSettingsPatch> {
        var patch = ChannelSettingsPatch()
        patch.name = flags["name"]
        var osdName: Bool?
        var osdDate: Bool?
        if let raw = flags["osd-name"] {
            guard let value = parseOnOff(raw) else { return .failure("--osd-name must be on or off") }
            osdName = value
        }
        if let raw = flags["osd-date"] {
            guard let value = parseOnOff(raw) else { return .failure("--osd-date must be on or off") }
            osdDate = value
        }
        if osdName != nil || osdDate != nil {
            patch.osd = OSDSettings(showName: osdName, showDate: osdDate)
        }
        if let raw = flags["notifications"] {
            guard let value = parseOnOff(raw) else { return .failure("--notifications must be on or off") }
            patch.notificationsEnabled = value
        }
        guard patch.name != nil || patch.osd != nil || patch.notificationsEnabled != nil else {
            return .failure("settings set requires at least one of --name, --osd-name, --osd-date, --notifications")
        }
        return .success(patch)
    }

    private static func parseTypes(_ raw: String?) -> Parsed<[DetectionKind]?> {
        guard let raw, !raw.isEmpty else { return .success(nil) }
        var kinds: [DetectionKind] = []
        for part in raw.split(separator: ",") {
            guard let kind = DetectionKind(rawValue: String(part).trimmingCharacters(in: .whitespaces)) else {
                return .failure("--types must be detection categories: \(DetectionKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            kinds.append(kind)
        }
        return .success(kinds)
    }

    /// Durations like `90s`, `30m`, `24h`, `7d` → seconds.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        guard let suffix = raw.last, let value = Double(raw.dropLast()), value > 0 else { return nil }
        switch suffix {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default: return nil
        }
    }

    private static func parseOnOff(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: return nil
        }
    }
}

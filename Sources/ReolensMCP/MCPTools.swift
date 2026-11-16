import Foundation

/// The MCP tool catalog: names, descriptions, and JSON Schemas.
///
/// The surface mirrors the ``CameraAPI`` contract one-to-one (0.10.0),
/// with reolink-cli-style `camera_*` naming. There is deliberately no
/// generic/raw escape hatch and no streaming subscription tool; live
/// events ride the `/v1/events` SSE endpoint and the CLI `events`
/// command instead.
public enum MCPTools {
    public struct Tool: Sendable {
        /// Tool name as called by clients (e.g. `camera_snapshot`).
        public let name: String
        /// Human/agent-facing summary of what the tool does.
        public let description: String
        /// JSON Schema for the tool's arguments object.
        public let inputSchema: JSONValue

        /// The `tools/list` entry for this tool.
        public var descriptor: JSONValue {
            ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
        }
    }

    private static let cameraProp: JSONValue = [
        "type": "string",
        "description": "Camera id or exact display name (see cameras_list).",
    ]
    private static let channelProp: JSONValue = [
        "type": "integer",
        "description": "Channel index on the device. Defaults to 0.",
    ]

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        object["additionalProperties"] = false
        return .object(object)
    }

    private static let detectionKinds = "motion, person, vehicle, pet, face, package, visitor, other"
    private static let ptzOps = "left, right, up, down, leftUp, leftDown, rightUp, rightDown, zoomIn, zoomOut, focusNear, focusFar, stop, autoScan, toPreset, startPatrol, stopPatrol"

    /// Every tool this server exposes, in `tools/list` order.
    public static let all: [Tool] = [
        Tool(name: "system_health",
             description: "Liveness and fleet summary for the Reolens instance (API version, camera/online counts, hub state).",
             inputSchema: schema([:])),
        Tool(name: "cameras_list",
             description: "List configured cameras with id, display name, kind, model, and online state. Run this before camera-specific tools.",
             inputSchema: schema([:])),
        Tool(name: "camera_get",
             description: "Fetch one camera by id or exact display name (connects on demand).",
             inputSchema: schema(["camera": cameraProp], required: ["camera"])),
        Tool(name: "camera_channels",
             description: "List a camera's channels, including per-channel capabilities (ptz, talk, ai categories) and battery state.",
             inputSchema: schema(["camera": cameraProp], required: ["camera"])),
        Tool(name: "camera_diagnostics",
             description: "Connection diagnostics for one camera: connection status, control transport (http/https/baichuan), online flag, event count, last error. Does not force a connect.",
             inputSchema: schema(["camera": cameraProp], required: ["camera"])),
        Tool(name: "camera_snapshot",
             description: "Capture a current JPEG still from a channel. Returns image content. Treat snapshots as personal data.",
             inputSchema: schema(["camera": cameraProp, "channel": channelProp], required: ["camera"])),
        Tool(name: "camera_stream",
             description: "Live-view references for a channel (Reolens-hosted MJPEG URL; direct RTSP with credentials is never exposed).",
             inputSchema: schema([
                "camera": cameraProp, "channel": channelProp,
                "quality": ["type": "string", "description": "main or sub. Defaults to sub."],
             ], required: ["camera"])),
        Tool(name: "camera_ptz",
             description: "Move a PTZ camera. With durationMs, moves then stops automatically (timed jog).",
             inputSchema: schema([
                "camera": cameraProp, "channel": channelProp,
                "op": ["type": "string", "description": .string("One of: \(ptzOps).")],
                "speed": ["type": "integer", "description": "Movement speed (~1-63)."],
                "presetID": ["type": "integer", "description": "Preset slot; required for toPreset."],
                "durationMs": ["type": "integer", "description": "Move for this many milliseconds, then stop."],
             ], required: ["camera", "op"])),
        Tool(name: "camera_reboot",
             description: "Reboot a camera (30-60s offline). Requires confirm: true.",
             inputSchema: schema([
                "camera": cameraProp,
                "confirm": ["type": "boolean", "description": "Must be true to reboot."],
             ], required: ["camera", "confirm"])),
        Tool(name: "camera_recordings",
             description: "Search stored recordings in an ISO-8601 time window, newest first. Follow nextCursor to page.",
             inputSchema: schema([
                "camera": cameraProp, "channel": channelProp,
                "from": ["type": "string", "description": "Window start, ISO-8601 (inclusive)."],
                "to": ["type": "string", "description": "Window end, ISO-8601 (inclusive)."],
                "types": ["type": "array", "items": ["type": "string"], "description": .string("Detection categories: \(detectionKinds).")],
                "cursor": ["type": "string", "description": "Opaque cursor from a previous page."],
                "limit": ["type": "integer", "description": "Maximum items in this page."],
             ], required: ["camera", "from", "to"])),
        Tool(name: "camera_recording_download",
             description: "Recording download reference (content type/size). Byte streaming is not exposed yet; credentials are never returned.",
             inputSchema: schema([
                "camera": cameraProp,
                "recording": ["type": "string", "description": "Recording id from camera_recordings."],
             ], required: ["camera", "recording"])),
        Tool(name: "camera_settings_get",
             description: "Read a channel's settings (name, OSD overlays, Reolens notifications enabled).",
             inputSchema: schema(["camera": cameraProp, "channel": channelProp], required: ["camera"])),
        Tool(name: "camera_settings_update",
             description: "Update a channel's settings. Only provided fields change. Returns the resulting settings.",
             inputSchema: schema([
                "camera": cameraProp, "channel": channelProp,
                "name": ["type": "string", "description": "Channel display name."],
                "osdShowName": ["type": "boolean", "description": "Show the name overlay."],
                "osdShowDate": ["type": "boolean", "description": "Show the date/time overlay."],
                "notificationsEnabled": ["type": "boolean", "description": "Reolens notifications for this camera."],
             ], required: ["camera"])),
    ]

    /// Look up a tool by name; nil when unknown.
    public static func tool(named name: String) -> Tool? {
        all.first(where: { $0.name == name })
    }
}

import Foundation
import ReolensCore
import ReolensMCP

/// The CLI's marketing version (kept aligned with the app by
/// `Scripts/check-versions.sh` expectations for the release).
public let reolensCLIVersion = "0.10.0"

/// Usage text and the machine-readable `features` manifest.
public enum CLIHelp {
    /// Full `--help` text.
    public static let usage = """
    reolens-cli \(reolensCLIVersion) — drive your Reolens cameras from the terminal or an AI agent.

    Talks to Reolens for Mac's Local API (Settings -> Local API, off by
    default). The app holds camera sessions and passwords; this tool
    holds only the API bearer token. JSON output by default.

    Usage:
      reolens-cli [--api-url URL] [--token TOKEN] [--output json|text]
                  [--camera <id-or-name>] [--channel N] <command> [options]

    Environment:
      REOLENS_API_URL    API root (default http://127.0.0.1:8443)
      REOLENS_API_TOKEN  Bearer token (preferred over --token)
      REOLENS_CAMERA     Default --camera selector

    Commands:
      health                    API liveness + fleet summary
      doctor                    Health + per-camera diagnostics
      features                  Machine-readable capability manifest
      version                   Print the CLI version
      cameras list              List configured cameras
      cameras show              One camera (requires --camera)
      channels                  Channels + capabilities (requires --camera)
      capabilities              Alias view of channels (requires --camera)
      diagnostics               Connection diagnostics (requires --camera)
      snapshot --file PATH      Save a JPEG still (requires --camera)
      stream [--quality Q]      Live-view references (requires --camera)
      ptz <op> [options]        Move a PTZ camera (requires --camera)
                                  --speed N --preset N --duration-ms N
      reboot --yes              Reboot a camera (requires --camera)
      recordings list           Search recordings (requires --camera)
                                  --since 24h | --from ISO --to ISO
                                  [--types person,vehicle] [--limit N]
      recordings download <id>  Download reference (requires --camera)
      settings get              Read channel settings (requires --camera)
      settings set [options]    --name X --osd-name on|off
                                  --osd-date on|off --notifications on|off
      events [--max-events N]   Follow the live motion/AI event stream
                                  [--types person,...] [--camera X]
      mcp-server                Run the MCP server over stdio

    Examples:
      export REOLENS_API_TOKEN=...   # copy it in Settings -> Local API
      reolens-cli cameras list
      reolens-cli --camera "Front Door" snapshot --file ./porch.jpg
      reolens-cli --camera porch ptz left --duration-ms 800
      reolens-cli --camera porch recordings list --since 24h --types person
      reolens-cli events --max-events 5

    Exit codes: 0 ok, 1 API error, 2 usage, 3 server unreachable.
    Snapshots and output can contain LAN details — redact before sharing.
    """

    /// Machine-readable manifest (`features` command), mirroring
    /// reolink-cli's so agents can gate on what this build supports.
    public static var featuresManifest: JSONValue {
        [
            "name": "reolens-cli",
            "version": .string(reolensCLIVersion),
            "apiVersion": .string(APIVersion.current),
            "commands": .array(commandNames.map { .string($0) }),
            "mcpTools": .array(MCPTools.all.map { .string($0.name) }),
            "exitCodes": ["ok": 0, "apiError": 1, "usage": 2, "unreachable": 3],
        ]
    }

    /// Every command name, as advertised in the features manifest.
    public static let commandNames = [
        "health", "doctor", "features", "version",
        "cameras list", "cameras show", "channels", "capabilities", "diagnostics",
        "snapshot", "stream", "ptz", "reboot",
        "recordings list", "recordings download",
        "settings get", "settings set", "events", "mcp-server",
    ]
}

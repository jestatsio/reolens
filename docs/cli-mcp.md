# Reolens CLI + MCP server

`reolens-cli` drives the cameras Reolens manages from a terminal,
scripts (`jq`-friendly JSON), or an AI agent (built-in MCP server). It
follows the shape of the official
[reolink-cli](https://github.com/reolink/reolink-cli) — a thin client
plus a local session holder — but is native Reolens code built on the
same [`/v1` contract](api/README.md) as everything else. (Reolink's
binaries are proprietary with unpublished source, so they cannot ship
inside an App Store app; nothing here depends on them. The two tools
coexist fine — they just talk to your cameras through different paths.)

## How it fits together

| Piece | Role |
|---|---|
| Reolens for Mac, Local API on | Holds camera sessions + passwords; serves `/v1` on your LAN |
| `reolens-cli` | Sends requests with the API bearer token; prints JSON |
| `reolens-cli mcp-server` | Same runtime as typed MCP tools over stdio |

Your camera passwords never enter the CLI process. The only secret it
holds is the Local API token, which you control and can regenerate.

## Setup (once)

1. On your Mac: Reolens → Settings → Advanced → turn on **Developer
   Mode**, then enable the **Local HTTP API** in the section it
   reveals. Copy the token shown there (you can copy it again any
   time; Regenerate invalidates the old one).
2. In your shell:

```bash
export REOLENS_API_TOKEN=...            # the token you copied
# Only if the Mac is another machine on your LAN:
export REOLENS_API_URL=http://192.168.1.20:8443
reolens-cli health
```

`health` exit 3 means the app is not running or the API is off. A
`401 unauthorized` means the token is missing or stale.

## Install

**From a GitHub Release:** download
`reolens-cli-<version>-macos-universal.tar.gz`, extract, and put
`reolens-cli` on your `PATH` (for example `~/.local/bin`). The binary
is not notarized yet, so first run needs:

```bash
xattr -d com.apple.quarantine ./reolens-cli
```

**From source** (Xcode 26):

```bash
swift build -c release --product reolens-cli
# or the universal release tarball:
./Scripts/build-cli.sh
```

**Without installing:** `swift run reolens-cli <command>` from a checkout.

## Commands

Run `reolens-cli --help` for the full list, or `reolens-cli features`
for the machine-readable manifest. Highlights:

```bash
reolens-cli cameras list
reolens-cli --camera "Front Door" snapshot --file ./porch.jpg
reolens-cli --camera porch ptz left --duration-ms 800   # timed jog, auto-stop
reolens-cli --camera porch recordings list --since 24h --types person
reolens-cli --camera porch settings set --notifications off
reolens-cli events --max-events 5                        # or follow forever
reolens-cli doctor                                       # health + diagnostics
reolens-cli --output text cameras list                   # human rendering
```

Rules worth knowing:

- `--camera` takes an id from `cameras list` or the exact display
  name. `--channel` defaults to 0.
- JSON is the default: `{"ok":true,"command":"…","data":…}` on stdout,
  errors as `{"ok":false,…,"error":{"code","message"}}` on stderr.
  Branch on `error.code`, not message text.
- Exit codes: `0` ok, `1` API error, `2` usage, `3` server unreachable.
- `reboot` requires `--yes` (the camera is offline 30–60s).
- `recordings download` returns reference metadata only; clip bytes
  are not relayed yet, and camera URLs/credentials are never exposed.
- `stream` returns the Reolens-hosted MJPEG reference — point Home
  Assistant / Frigate / go2rtc at it without sharing camera passwords.

## MCP server

Any MCP client (Claude Code, Codex, Cursor, …) can drive the same
surface as typed tools (`cameras_list`, `camera_snapshot`,
`camera_ptz`, … — `tools/list` is authoritative):

```json
{
  "mcpServers": {
    "reolens": {
      "command": "/path/to/reolens-cli",
      "args": ["mcp-server"],
      "env": { "REOLENS_API_TOKEN": "...", "REOLENS_API_URL": "http://127.0.0.1:8443" }
    }
  }
}
```

Notes for agents and their operators:

- The server speaks JSON-RPC 2.0 over stdio; one process per host
  session. Reolens for Mac must be running with the Local API enabled.
- Snapshots return MCP image content — they are personal data; treat
  transcripts accordingly.
- `camera_reboot` requires `"confirm": true`.
- Tool errors carry only the API's sanitized `code`/`message` — never
  hosts in raw transport text, never credentials.
- There is no event-subscription tool yet; use the CLI `events`
  command or the `/v1/events` SSE stream for live monitoring.

## Security

LAN-only by construction: the Local API binds loopback + RFC-1918,
is off by default, and requires the bearer token on every route
(including `/v1/health`). Prefer `REOLENS_API_TOKEN` over `--token`
(argv shows in `ps`). CLI JSON can include LAN hostnames (already
visible to any authenticated API consumer) — redact before sharing
output, and protect snapshot files like camera footage.

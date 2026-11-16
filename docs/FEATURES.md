# Features

The full feature surface of Reolens. For a quick overview see the
[README](../README.md); for the per-release history see
[CHANGELOG.md](../CHANGELOG.md).

## Live viewing

- **Multi-camera grids** with adaptive layout, spotlight, and fixed 2×2
  → 5×5 presets. Drag-and-drop reorder. Per-camera rotation.
- **Hardware-decoded RTSP** (H.264 / H.265) via VideoToolbox. FLV / JPEG
  fallback when the stream renegotiates.
- **Picture-in-Picture, pinch-to-zoom, drag-to-pan** on iOS / iPadOS.
- **Two-way talkback** on supported cameras.
- **Full PTZ** — all 17 ops (pan / tilt / zoom / focus / presets /
  patrols) from a dedicated control bar.
- **Battery cameras** wake on the first tap; the single-camera detail
  view auto-wakes on appear so you don't tap twice.
- **Cameras with their web API off just work** (0.9.0) — newer firmware
  that ships HTTP/HTTPS disabled connects automatically over Baichuan
  (port 9000) with live video, motion/AI events, and PTZ; Reolens
  remembers which control plane each camera answers on.

## Recordings

- **Per-camera Recordings tab** with a day-density calendar, a per-day
  timeline strip with AI-event ticks, and a player that scrubs with a
  thumbnail rail.
- **All Recordings** view that fans across every channel — and across
  hubs — into one chronological feed. Filter by AI tag or by camera.
- **Cross-day natural-language search** ("packages this week",
  "vehicles yesterday at the driveway"). Runs through Apple's on-device
  `FoundationModels` when available (no recording data crosses the
  model boundary — just the prompt); otherwise a deterministic regex
  parser.
- **Bookmarks** — long-press / right-click / swipe to bookmark without
  playing. The clip downloads in the background so it's available
  offline; Wi-Fi by default, cellular toggle in Settings.

## Notifications

- **Rich motion / AI notifications** with the trigger frame, not just
  text. Tap to jump straight to the clip.
- **CloudKit-relayed background pushes** to iOS / iPadOS — events ride
  through *your own* iCloud private database, no Reolens server.
- **Per-camera mute** (default on, iCloud-synced) and **per-AI-tag
  filters**. **Notification diagnostics** screen + a 1,000-record
  rolling **notification log** so silent-push issues are self-
  diagnosing. **Overnight digest** — local notification at a user-
  configurable hour summarizing the previous day's events.

## Schedules

- **Recording schedule editor** — visual 7×24 weekly grid of when each
  camera writes to storage. Reads / writes via Reolink's `Rec` CGI
  command; degrades to read-only on firmware that doesn't expose it.
- **Motion-detection schedule** with **per-AI-tag overrides** — set
  the channel-level "when can alarms fire" window, then override per
  tag (e.g. quiet `vehicle` overnight while still alerting on
  `people`).
- **Motion privacy zones** — draw rectangles on the live frame;
  written back via `SetMask` with graceful local-only fallback.

## Platform polish

- **Stage Manager / multi-window** on iPad + macOS. "Open in New
  Window" on any camera row.
- **Home Screen / Lock Screen / Control Center widgets** on iOS /
  iPadOS; desktop widgets on macOS.
- **Live Activities + Dynamic Island** on iOS for in-flight motion
  events. Hub-grouped — multiple events on the same hub merge into
  one Live Activity rather than stacking.
- **HomeKit bridge scaffolding** on iOS / iPadOS (added in 0.6.0). The
  per-camera "Expose to HomeKit" toggle syncs through iCloud so flipping
  it on one device propagates to the device that has the entitlement.
  Full HomeKit Secure Video recording tier ships once Apple completes
  MFi certification — see [ROADMAP.md](ROADMAP.md).
- **Liquid Glass throughout** — toolbars, sidebars, chips, badges,
  popovers, sheets, HUDs all use the iOS 26 / macOS 26
  `.glassEffect()` material via centralized design tokens.
- **iCloud sync** — camera list, grid layout, channel order, and
  rotations sync across your Apple devices. Passwords stay per-
  device in Keychain by default; optional iCloud Keychain sync is in
  Settings.
- **Shortcuts & Siri** — "Hey Siri, open the Front Door camera in
  Reolens." Three App Intents: Open Camera, Show Today's Events,
  Mute Camera Notifications.
- **Apple TV viewer** — a living-room live-view app (tvOS): focusable
  camera grid into fullscreen RTSP, fed by the iCloud-synced camera
  list with opt-in encrypted credential sync.
- **Watch companion** — glanceable camera snapshots on Apple Watch.
- **Auto-updates** — App Store and TestFlight on every Apple platform.

## Local REST API (macOS, opt-in)

A clean, versioned `/v1` HTTP API — list cameras, pull snapshots, move
PTZ, search recordings, watch a live MJPEG stream, and follow a live
motion/AI event stream (SSE). Turn it on under **Settings → Advanced →
Developer Mode → Local API**. It binds to your LAN only, is secured with
a bearer token, is off by default, and adds no dependencies (no Reolens
server — it runs on your own Mac). Built for Home Assistant, Shortcuts,
and scripts. Full contract in [docs/api/](api/README.md).

## Command line + AI agents (macOS, opt-in)

- **`reolens-cli`** (0.10.0) — a native terminal client for the same
  contract: list cameras, save snapshots, timed PTZ jogs, recording
  search, settings, reboot, a fleet-wide `doctor`, and a live event
  follow mode. JSON envelopes by default, `--output text` for humans,
  scriptable exit codes. Ships as a universal binary on each GitHub
  Release; talks only to your Mac's Local API with its bearer token.
- **MCP server** — `reolens-cli mcp-server` exposes typed tools
  (`cameras_list`, `camera_snapshot`, `camera_ptz`, …) over stdio so
  Claude Code, Codex, Cursor, and other MCP clients can drive your
  cameras in plain language. Setup in [cli-mcp.md](cli-mcp.md).

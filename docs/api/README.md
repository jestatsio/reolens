# Reolens Local API

A clean, versioned, **Reolink-agnostic** REST API for the cameras Reolens
manages. It is the single contract the app's own surfaces and external
consumers (Home Assistant, scripts, third-party apps) are both built on.

- **Contract source of truth:** the `ReolensCore` Swift target
  (`Sources/ReolensCore/`). The resource types here mirror those DTOs exactly —
  if they ever disagree, `ReolensCore` wins, and that's a bug to fix here.
- **Formal schema:** [`openapi.yaml`](openapi.yaml) (OpenAPI 3.1). The running
  server also serves it at `GET /v1/openapi.json`.

## Design principles

1. **Reolink quirks never leak.** Trigger bitfields, session caps, and
   firmware-shaped fields are mapped to clean resources before they reach a
   consumer. Detection categories use a normalized vocabulary (`person`,
   `pet`) — not Reolink's `people` / `dog_cat`.
2. **Privacy-first, LAN-local.** The server is **inbound, LAN-bound, opt-in,
   and off by default** — the user's own device, no cloud (AGENTS.md §5, same
   spirit as the Hub). Credentials never appear in responses by default.
3. **Stable & versioned.** All routes live under `/v1`. Changes within `v1`
   are additive and backward-compatible (AGENTS.md §7); a breaking change mints
   `/v2`.
4. **Relay-ready.** The wire is plain JSON-over-HTTP with a bearer token, so a
   future end-to-end-encrypted relay can carry the identical contract without
   any schema change.

## Authentication

Every route except `GET /v1/health` requires a bearer token:

```
Authorization: Bearer <token>
```

The token is generated in the app (Settings → Local API), stored in the
Keychain, and shown once. It is compared in constant time. Requests from peers
outside the loopback / RFC-1918 LAN are refused.

## Conventions

- **Envelope.** JSON resource endpoints return `{ "data": …, "meta": … }` on
  success and `{ "error": { "code", "message", "status" } }` on failure.
  Binary endpoints (snapshot) and the SSE event stream are exceptions — they
  emit raw bytes / bare event JSON.
- **Errors.** Branch on the stable `error.code` (e.g. `camera_not_found`), not
  on `message` text. `message` never contains credentials or URLs with auth.
- **Time.** All timestamps are ISO-8601.
- **Pagination.** Recordings use an opaque `cursor`; follow `meta.nextCursor`
  until it is absent.

## Endpoints

| Method & path | Purpose |
|---|---|
| `GET /v1/health` | Liveness + summary (no auth) |
| `GET /v1/cameras` | List cameras |
| `GET /v1/cameras/{id}` | One camera |
| `GET /v1/cameras/{id}/channels` | Channels on a camera |
| `GET /v1/cameras/{id}/diagnostics` | Connection state + control transport |
| `POST /v1/cameras/{id}/reboot` | Reboot the camera |
| `GET /v1/cameras/{id}/channels/{ch}/snapshot` | Current still (`image/jpeg`) |
| `GET /v1/cameras/{id}/channels/{ch}/stream` | Stream references (mjpeg/rtsp/hls) |
| `GET /v1/cameras/{id}/channels/{ch}/mjpeg` | Live MJPEG video (multipart) |
| `POST /v1/cameras/{id}/channels/{ch}/ptz` | Pan/tilt/zoom |
| `GET /v1/cameras/{id}/channels/{ch}/recordings` | Search recordings |
| `GET /v1/cameras/{id}/channels/{ch}/recordings/{rid}/download` | Download a clip |
| `GET /v1/cameras/{id}/channels/{ch}/settings` | Read channel settings |
| `PATCH /v1/cameras/{id}/channels/{ch}/settings` | Partial settings update |
| `GET /v1/events` | Live motion/AI events (SSE) |
| `GET /v1/openapi.json` | This contract |

## Examples

```bash
TOKEN=… ; BASE=http://localhost:8443/v1

# List cameras
curl -H "Authorization: Bearer $TOKEN" "$BASE/cameras"

# Snapshot to a file
curl -H "Authorization: Bearer $TOKEN" \
  "$BASE/cameras/CAM-1/channels/0/snapshot" -o snap.jpg

# Nudge a PTZ camera left
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"op":"left","speed":32}' \
  "$BASE/cameras/CAM-1/channels/0/ptz"

# Check a camera's connection diagnostics (incl. control transport)
curl -H "Authorization: Bearer $TOKEN" "$BASE/cameras/CAM-1/diagnostics"

# Reboot a camera
curl -X POST -H "Authorization: Bearer $TOKEN" "$BASE/cameras/CAM-1/reboot"

# Follow the live event stream
curl -N -H "Authorization: Bearer $TOKEN" "$BASE/events"

# Recordings for a day, person-triggered only
curl -H "Authorization: Bearer $TOKEN" \
  "$BASE/cameras/CAM-1/channels/0/recordings?from=2026-05-30T00:00:00Z&to=2026-05-30T23:59:59Z&types=person"
```

## Home Assistant

Point a `generic` camera at the MJPEG URL from `GET …/stream` (`still_image_url`
→ the snapshot endpoint, `stream_source` → the MJPEG endpoint). Both carry the
bearer token, so no Reolink credentials are exposed to Home Assistant.

## Status

This is the design artifact plus the `ReolensCore` contract (Phase 0–1).
Implementation lands in phases — see the project plan: in-process adapter
(`LiveCameraAPI`, Phase 2), the HTTP facade (`ReolensServer`, Phase 3), and the
opt-in macOS integration (Phase 4). HLS streaming and the relay transport are
later phases.

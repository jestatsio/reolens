<h1 align="center">
  <img src="docs/assets/icon-256.png" alt="Reolens" width="120" height="120"><br>
  Reolens
</h1>

<p align="center">
  A native client for Reolink cameras, NVRs, and Home Hubs — on Mac, iPad, and iPhone.
</p>

<p align="center">
  <a href="https://github.com/jestatsio/reolens/actions/workflows/ci.yml"><img src="https://github.com/jestatsio/reolens/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jestatsio/reolens/releases/latest"><img src="https://img.shields.io/github/v/release/jestatsio/reolens?label=release&color=4cd2ff" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-1ba6d8" alt="macOS 26+">
  <img src="https://img.shields.io/badge/iOS-26%2B-1ba6d8" alt="iOS 26+">
</p>

<p align="center">
  <a href="https://reolens.io">Website</a> ·
  <a href="https://testflight.apple.com/join/c815tbVE">TestFlight</a> ·
  <a href="#install">Install</a> ·
  <a href="docs/FEATURES.md">Features</a> ·
  <a href="CHANGELOG.md">What's new</a> ·
  <a href="https://github.com/jestatsio/reolens/issues">Issues</a>
</p>

---

Reolens watches your Reolink cameras with a real native app — SwiftUI,
Swift 6, AVFoundation / VideoToolbox. No Electron, no Java, no QtWebEngine.
Cold-launches in under a second and feels at home on every Apple platform.

It runs **entirely on your devices**: no Reolens server, no third-party
analytics, no telemetry, no accounts.

![Adaptive multi-camera grid](docs/screenshots/grid-adaptive.png)

<sub>Screenshot footage is procedurally rendered, not real captures — privacy-clean and still representative.</sub>

## Highlights

- 🎥 **Live** — hardware-decoded RTSP (H.264 / H.265), adaptive grids up to 5×5, PiP, full 17-op PTZ, two-way talkback.
- ⏺️ **Recordings** — day-density calendar, thumbnail scrubber, a cross-hub "All Recordings" feed, and on-device natural-language search.
- 🔔 **Notifications** — rich motion / AI pushes with the trigger frame, relayed through *your own* iCloud, with per-camera and per-tag filters.
- 🗓️ **Schedules** — visual recording grid, motion windows with per-AI-tag overrides, and drawable privacy zones.
- 🧩 **Platform-native** — widgets, Live Activities + Dynamic Island, Shortcuts & Siri, Stage Manager, Liquid Glass throughout.
- 🔌 **Local REST API** — opt-in, LAN-only `/v1` HTTP API on macOS for Home Assistant, Shortcuts, and scripts.
- 🔒 **Private by design** — no server, no accounts, no telemetry; camera passwords stay in the Keychain.

→ The full surface lives in **[docs/FEATURES.md](docs/FEATURES.md)**.

## Install

**Mac · iPad · iPhone — [TestFlight](https://testflight.apple.com/join/c815tbVE).**
One multiplatform app: Mac, iPad, and iPhone share a single App Store record,
and TestFlight installs the right build on each device. Requires macOS 26+ /
iPadOS 26+ / iOS 26+.

**Build from source:**

```sh
git clone https://github.com/jestatsio/reolens.git
cd reolens
./Scripts/build-app.sh run      # macOS — builds + signs + launches
cd AppiOS && xcodegen generate  # iOS — then open in Xcode 26
```

Requires Xcode 26 + Swift 6.2.

## Quick start

1. **Launch Reolens.** It asks for Local Network permission (to reach your
   cameras) and Notification permission (for motion alerts).
2. **Click + in the sidebar** to add a camera. Enter its IP (or hostname),
   username, and password — the rest is auto-detected.
3. **Pick a camera** to view it, and use the toolbar layout picker to switch
   between adaptive / spotlight / 2×2 → 4×4 grids.

Drag tiles to rearrange; right-click for "Make primary", "Rotate", and
per-channel settings.

## Remote access

Reolens is **LAN-only by design** — it talks only to your camera's local IP,
never to Reolink's cloud, a DDNS provider, or any relay. To reach it from
away, put your phone *on* the LAN with an overlay network instead of forwarding
ports. **[Tailscale](https://tailscale.com)** is the recommended path: free for
personal use, ~10 minutes to set up, and no open ports or WAN-IP exposure.

→ Full step-by-step in **[docs/remote-connectivity.md](docs/remote-connectivity.md)**.

## Requirements

- **macOS 26 Tahoe+** (Apple Silicon or Intel), or **iPadOS / iOS 26+**
- **A Reolink camera, NVR, or Home Hub** on the local network
- HTTP / HTTPS access to the device's CGI port (default 80 / 443)

On macOS 14 / iOS 18? Stay on the 0.4.x security-backport track — see
[SECURITY.md](SECURITY.md). FoundationModels features (Today digest, NL search)
fall back to deterministic implementations without Apple Intelligence.

## Screenshots

| | |
|---|---|
| ![Adaptive grid](docs/screenshots/grid-adaptive.png) | ![Spotlight layout](docs/screenshots/spotlight.png) |
| Adaptive multi-camera grid | Spotlight layout |
| ![Detail + PTZ](docs/screenshots/detail-ptz.png) | ![About panel](docs/screenshots/about.png) |
| Detail view with full PTZ controls | About panel |

## Privacy

Reolens runs entirely on your devices. The only network surface is your
Reolink devices (LAN), your own iCloud (camera-list sync + motion-event push
relay, private database), and Apple's App Store / TestFlight for updates.
No third-party analytics, crash reporting, telemetry, or accounts.

**Credentials are device-local** — camera passwords live in each device's
Keychain (`kSecAttrSynchronizable: false`), and iCloud sync carries only
metadata. The full model is in [AGENTS.md](AGENTS.md) §3, §4.

## Documentation

| | |
|---|---|
| [Features](docs/FEATURES.md) | The full feature surface |
| [Architecture](docs/ARCHITECTURE.md) | Layers, concurrency model, repo layout |
| [Local REST API](docs/api/README.md) | The `/v1` HTTP API contract |
| [Roadmap](docs/ROADMAP.md) | What's planned next |
| [Changelog](CHANGELOG.md) | Per-release history |
| [Contributing](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) | Dev setup + engineering principles |

## Development

```sh
swift build                 # libs + macOS app
swift test                  # ~340 tests across 68 suites
./Scripts/build-app.sh run  # bundled .app (needed for Local Network access)

bash Scripts/check-versions.sh  # macOS + iOS marketing versions must match
bash Scripts/coverage-gate.sh   # per-target coverage regression gate
```

Cutting a release is tag-driven — see [docs/RELEASE.md](docs/RELEASE.md).

## Contributing

PRs welcome. Read [AGENTS.md](AGENTS.md) (engineering principles) and
[CONTRIBUTING.md](CONTRIBUTING.md) (dev setup, tests, commit conventions)
first. For security issues, use the private flow in [SECURITY.md](SECURITY.md)
rather than a public issue.

## License

MIT — see [LICENSE](LICENSE).

Reolink is a trademark of Reolink Innovation Inc. Reolens is an unaffiliated
third-party client; the protocol is reverse-engineered from public CGI
documentation and community projects — the
[Reolink CGI reference](https://support.reolink.com/), 
[reolink_aio](https://github.com/starkillerOG/reolink_aio) (Home Assistant's
Python client), and [neolink](https://github.com/thirtythreeforty/neolink)
(Rust, for Baichuan).

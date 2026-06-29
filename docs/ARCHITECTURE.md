# Architecture

How Reolens is put together. For the engineering principles that gate
every change — platform parity by default, no telemetry, no credentials
in logs — see [AGENTS.md](../AGENTS.md). For the iOS-specific project
layout, see [AppiOS/README.md](../AppiOS/README.md).

## Layers

```
┌──────────────────────────────────────────────────────────────────┐
│ App (SwiftUI views, @Observable state, ReolensApp / RootView)    │
│ AppiOS/ (iOS twin) + Widget extensions + Live Activity ext.      │
├──────────────────────────────────────────────────────────────────┤
│ AppShared (CameraStore split, RecordingsLoader, RecordingIndex,  │
│            PollManager, EventNotifier, RelayDiagnostics,         │
│            SharedContainer, ReolensGlass design tokens, …)       │
├──────────────────────────────────────────────────────────────────┤
│ ReolinkBaichuan (port 9000: talkback, alarm push, findAlarmVideo)│
│ ReolinkStreaming (RTSP + VideoToolbox + H.264 / H.265 + SDP)     │
├──────────────────────────────────────────────────────────────────┤
│ ReolinkAPI (CGI client, Commands, Codable models, StreamURLs)    │
└──────────────────────────────────────────────────────────────────┘
```

Dependency-only-downward. `ReolinkAPI` ships standalone — no UI deps,
testable in isolation. `AppShared` is the cross-platform behaviour
layer driving the macOS app, the iOS / iPadOS app, both widget
extensions, and the Live Activity extension.

## Concurrency primitives

- `CGIClient` is an **actor** — one instance per camera. Reolink
  devices have a notoriously small global session cap, so the actor
  serializes login / refresh and reuses one token across all commands.
- `CameraSession` is `@MainActor`-isolated and `@Observable` — SwiftUI
  views observe its state directly.
- `RecordingsLoader` is an `@MainActor @Observable` class with a
  generation counter so a rapid date-flip never publishes stale
  results on top of the latest reload.
- `PollManager` owns the motion-event polling lifecycle separately
  from `CameraSession` with a depth-counted pause/resume primitive.

## Repository layout

```
Package.swift            — SwiftPM manifest (libs + macOS executable + tests)
App/                     — macOS SwiftUI executable
  ReolensApp.swift       — @main, About panel, Check-for-Updates menu
  Views/                 — sidebar, grid, detail, PTZ, settings, scrubber,
                           bookmarks, schedule editors, About
  Widgets/               — macOS desktop WidgetKit extension target
AppiOS/                  — iOS / iPadOS Xcode project (xcodegen-managed)
  Sources/               — RootView, iPadSplitShell, iPhoneTabShell,
                           SingleChannelView, LiveActivities/
  Widgets/               — iOS WidgetKit + Control Center + ActivityKit
                           extension target (5 widget surfaces total)
  UITests/               — XCUITest baseline journeys
  project.yml            — xcodegen spec; run `xcodegen generate` after edits
Sources/
  AppShared/             — cross-platform behaviour layer
  ReolinkAPI/            — CGI client + Codable models + StreamURLs
  ReolinkStreaming/      — RTSP / VideoToolbox / H.264 + H.265 / SDP
  ReolinkBaichuan/       — port-9000 protocol (talkback, push, alarms)
  ReolensServer/         — local /v1 REST API (Network.framework, macOS)
Tests/                   — ~340 tests across 68 suites
Scripts/                 — build, sign, App Store (TestFlight) upload,
                           icon generation, coverage gate, version-check gate
docs/                    — reolens.io landing page (GitHub Pages),
                           FEATURES.md, ARCHITECTURE.md, API contract,
                           RELEASE.md + IOS_RELEASE.md + MAC_RELEASE.md runbooks
.github/workflows/
  ci.yml                 — build + test + smoke launch + coverage gate
                           + iOS XCUITest job
  release.yml            — on tag push: archive + upload iOS & macOS
                           to App Store Connect / TestFlight
```

import SwiftUI
import ReolinkAPI
import ReolinkStreaming

/// 0.7.0 — Apple TV "living-room viewer" UI. Live view only (no
/// recordings / PTZ / settings). Cross-platform SwiftUI so the library
/// also compiles under `swift build` for CI verification; the focus
/// engine drives navigation on the actual tvOS app.

/// Root: a focusable camera grid that pushes a fullscreen live view.
public struct TVRootView: View {
    @State private var list = TVCameraListStore()
    @State private var credentials = TVCredentialReader()

    public init() {}

    public var body: some View {
        NavigationStack {
            TVCameraGridView(store: list, credentials: credentials)
                .navigationTitle("Reolens")
                .navigationDestination(for: TVCameraEntry.self) { camera in
                    TVLiveFullscreenView(
                        camera: camera,
                        password: credentials.password(for: camera.id)
                    )
                }
        }
        .task {
            await list.load()
            await credentials.load()
        }
    }
}

struct TVCameraGridView: View {
    let store: TVCameraListStore
    let credentials: TVCredentialReader

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 48)]

    var body: some View {
        Group {
            if store.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras yet", systemImage: "video.slash")
                } description: {
                    Text("Add cameras in Reolens on your iPhone or Mac, signed in to the same iCloud account.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 48) {
                        ForEach(store.cameras) { camera in
                            NavigationLink(value: camera) {
                                TVCameraCard(camera: camera)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(60)
                }
            }
        }
    }
}

/// A camera tile. tvOS lacks per-camera snapshots (those live in each
/// device's local App Group, not iCloud), so the card is name + icon.
struct TVCameraCard: View {
    let camera: TVCameraEntry

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(camera.displayName)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }
}

/// Fullscreen live view. Builds an RTSP `LiveVideoPlayer` directly from
/// the camera + its synced password — no `CameraSession` needed.
struct TVLiveFullscreenView: View {
    let camera: TVCameraEntry
    let password: String?

    @State private var player: LiveVideoPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                LiveVideoView(player: player)
                    .ignoresSafeArea()
            } else if password == nil {
                ContentUnavailableView {
                    Label("Streaming needs credential sync", systemImage: "key.slash")
                } description: {
                    Text("On your iPhone or Mac, open Reolens → Settings → Apple TV and turn on “Stream on Apple TV.”")
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle(camera.displayName)
        .onAppear {
            setIdleTimerDisabled(true)
            startIfPossible()
        }
        .onDisappear {
            player?.stop()
            player = nil
            setIdleTimerDisabled(false)
        }
    }

    private func startIfPossible() {
        guard player == nil, let password else { return }
        let creds = CameraCredentials(
            host: camera.host,
            port: camera.port,
            username: camera.username,
            password: password,
            useHTTPS: camera.useHTTPS
        )
        // Fullscreen single view → main stream (AGENTS.md §10: sub in
        // grids, main when expanded). candidatesForLive falls back to
        // ext/sub if main doesn't respond.
        let urls = StreamURLs(credentials: creds).candidatesForLive(
            channel: camera.primaryChannel,
            stream: .main,
            preferredCodec: camera.preferredCodec
        )
        let newPlayer = LiveVideoPlayer(urls: urls, username: camera.username, password: password)
        newPlayer.start()
        player = newPlayer
    }

    /// Keep the screensaver from interrupting a live stream. Our custom
    /// `AVSampleBufferDisplayLayer` doesn't auto-suppress idle the way
    /// `AVPlayerViewController` does. tvOS only — no idle timer on macOS.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

#if os(tvOS)
import UIKit
#endif

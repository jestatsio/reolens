import SwiftUI
import UserNotifications
import AppShared

/// macOS Settings window. 0.6.1 reorganized this into the seven
/// shared `Settings*Bucket` views; 0.6.2 deletes the legacy 5-tab
/// layout (the emergency-revert flag) now that the new IA has been
/// in the field for a release without regressions. The TabView shell
/// stays — macOS Settings idiom is tabs; each tab maps onto one
/// (or two) buckets:
///
/// - **Cameras** — `SettingsCamerasBucket` + `SettingsDisplayBucket`
/// - **Notifications** — `SettingsNotificationsBucket`
/// - **Background** — `SettingsBackgroundBucket` + menu-bar mode
/// - **Privacy & Sync** — `SettingsPrivacyBucket`
/// - **Advanced** — `SettingsAdvancedBucket`
/// - **About** — `SettingsAboutBucket`
struct SettingsView: View {
    @State private var showingLog: Bool = false
    @State private var showingDiagnostics: Bool = false
    @AppStorage(MenuBarController.menuBarModeKey) private var menuBarMode: Bool = false
    @AppStorage(MenuBarController.launchAtLoginKey) private var launchAtLogin: Bool = false
    @AppStorage(AppPreferences.runAsHubKey) private var runAsHub: Bool = false
    @State private var hubEngine: HubEngine?
    @Environment(CameraStore.self) private var store

    var body: some View {
        TabView {
            camerasTab
                .tabItem { Label("Cameras", systemImage: "video") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            backgroundTab
                .tabItem { Label("Background", systemImage: "moon") }
            privacyTab
                .tabItem { Label("Privacy & Sync", systemImage: "lock.shield") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "hammer") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        .sheet(isPresented: $showingLog) {
            NavigationStack {
                NotificationLogView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingLog = false }
                        }
                    }
            }
            .frame(minWidth: 520, minHeight: 600)
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                DiagnosticsCenterView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingDiagnostics = false }
                        }
                    }
            }
            .frame(minWidth: 520, minHeight: 600)
        }
    }

    private var camerasTab: some View {
        Form {
            SettingsCamerasBucket()
            SettingsDisplayBucket()
        }
        .formStyle(.grouped)
    }

    private var notificationsTab: some View {
        Form {
            SettingsNotificationsBucket(showingLog: $showingLog)
        }
        .formStyle(.grouped)
    }

    private var backgroundTab: some View {
        Form {
            SettingsBackgroundBucket()
            hubSection
            menuBarSection
        }
        .formStyle(.grouped)
        .onAppear { hubEngine = HubController.shared.activeEngine }
    }

    private var privacyTab: some View {
        Form {
            SettingsPrivacyBucket()
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            SettingsAdvancedBucket(showingDiagnostics: $showingDiagnostics)
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            SettingsAboutBucket()
        }
        .formStyle(.grouped)
    }

    /// 0.7.0 — macOS-only "Reolens Hub" section. Designating this Mac as
    /// the Hub makes it the always-on listener: it connects every camera
    /// and publishes motion events to the user's private CloudKit
    /// database even with no window open, so their other Apple devices
    /// get notifications, Live Activities, and remote viewing without
    /// anyone keeping the app open. One Mac per home should be the Hub;
    /// others stay passive viewers. No iOS analog (iPhone/iPad can't
    /// hold a background listener) — AGENTS.md §1 carve-out.
    private var hubSection: some View {
        Section("Reolens Hub") {
            Toggle("Run this Mac as a Reolens Hub", isOn: $runAsHub)
                .onChange(of: runAsHub) { _, newValue in
                    HubController.shared.setRunAsHub(newValue, store: store)
                    hubEngine = HubController.shared.activeEngine
                    // Hub mode registers its own headless LaunchAgent, so
                    // it supersedes the foreground "Launch at login"
                    // checkbox — force that off so two login items can't
                    // both relaunch Reolens.
                    if newValue, launchAtLogin {
                        launchAtLogin = false
                        MenuBarController.shared.setLaunchAtLogin(false)
                    }
                }
            Text("New in 0.7.0. Pick one always-on Mac (a Mac mini is ideal) as your Hub. It watches every camera around the clock and relays motion to your iPhone, iPad, Apple TV, and Watch — no Reolens server, just your own iCloud. Runs headless and starts at login; turn it off here anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if runAsHub, let engine = hubEngine {
                hubStatusLine(engine)
            }
        }
    }

    /// Live "watching N of M cameras" status plus a callout for any
    /// camera whose password isn't on this Mac (so the gap is visible
    /// and fixable, never silent — AGENTS.md §4). Reads the `@Observable`
    /// `HubEngine` held in `@State`, so it refreshes as cameras connect.
    @ViewBuilder
    private func hubStatusLine(_ engine: HubEngine) -> some View {
        let total = engine.configuredCameraCount
        Label(
            "Watching \(engine.hostedCameraCount) of \(total) camera\(total == 1 ? "" : "s")",
            systemImage: "dot.radiowaves.left.and.right"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
        if !engine.unhostableCameraNames.isEmpty {
            let names = engine.unhostableCameraNames.map { "“\($0)”" }.joined(separator: ", ")
            let one = engine.unhostableCameraNames.count == 1
            Label(
                "\(names) \(one ? "has" : "have") no password on this Mac — enter \(one ? "it" : "them") on this Mac to include \(one ? "it" : "them").",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    /// macOS-only section, kept distinct from the cross-platform
    /// buckets because no iOS analog exists.
    private var menuBarSection: some View {
        Section("Run in the menu bar") {
            Toggle("Run in the menu bar when closed", isOn: $menuBarMode)
                .onChange(of: menuBarMode) { _, newValue in
                    if newValue {
                        MenuBarController.shared.install(store: store)
                    } else {
                        MenuBarController.shared.uninstall()
                        if launchAtLogin {
                            launchAtLogin = false
                            if #available(macOS 13.0, *) {
                                MenuBarController.shared.setLaunchAtLogin(false)
                            }
                        }
                    }
                }
            Text("New in 0.4.0. Closing the window keeps Reolens running in the menu bar so motion notifications keep firing. Quit from the menu bar item to fully stop the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if #available(macOS 13.0, *) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!menuBarMode)
                    .onChange(of: launchAtLogin) { _, newValue in
                        MenuBarController.shared.setLaunchAtLogin(newValue)
                    }
                Text("Reolens starts in the menu bar at login so events from the moment you sit down at the Mac aren't missed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

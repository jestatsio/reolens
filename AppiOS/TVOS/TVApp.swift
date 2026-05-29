import SwiftUI
import AppTVOS

/// 0.7.0 — Apple TV living-room viewer entry point. A thin `@main` shell
/// (mirrors `AppiOS/Watch/WatchApp.swift`) that hosts `AppTVOS.TVRootView`.
/// All viewer logic lives in the `AppTVOS` SPM library so this target
/// stays minimal and the logic is shared/testable.
@main
struct ReolensTVApp: App {
    var body: some Scene {
        WindowGroup {
            TVRootView()
        }
    }
}

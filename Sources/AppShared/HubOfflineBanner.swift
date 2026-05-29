import SwiftUI

/// 0.7.0 — the cross-platform "Hub offline — notifications paused"
/// banner. Shown on iPhone, iPad, macOS, and Apple TV when the always-on
/// Reolens Hub's CloudKit heartbeat has gone stale, so a user whose
/// alerts went quiet immediately understands why (rather than assuming
/// nothing happened).
///
/// Renders nothing in every non-outage state — including
/// `noHubEverConfigured` (don't nag a user who never set up a Hub) and
/// `roleOff` (a Hub turned off deliberately is not an alarm). Because the
/// body collapses to an empty view otherwise, hosting it in a
/// `.safeAreaInset(edge: .top)` adds zero inset until there's a genuine
/// outage. Pairs the warning color with an icon + text (AGENTS.md §9 —
/// never color alone) and uses the shared glass token (§2).
public struct HubOfflineBanner: View {
    @State private var health = HubHealth.shared

    public init() {}

    public var body: some View {
        if case .offline(let name, let lastSeen) = health.state {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hub offline — notifications paused")
                        .font(.callout.weight(.semibold))
                    Text("\(name) · last seen \(lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .reolensGlassToast()
            .padding(.horizontal)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Hub offline. Notifications paused. \(name) last seen \(lastSeen.formatted(.relative(presentation: .named)))."
            )
        }
    }
}

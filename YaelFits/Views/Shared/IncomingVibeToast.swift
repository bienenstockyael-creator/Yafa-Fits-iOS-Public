import SwiftUI

/// Top-of-screen banner that slides in when the current user
/// receives a vibe while in the app. Watches
/// `VibesIncomingManager.latest` and renders a card with:
///   - giver's avatar
///   - "{username} vibed your fit" copy
///   - flame icon, glowy blue tint
///
/// Auto-dismisses after ~3.8s. Tap dismisses immediately.
/// If the incoming vibe also pushed the user across a 5-vibe
/// milestone, the copy is upgraded to a free-gen celebration.
///
/// Rendered at the very top of the app's view tree (alongside
/// `VibesParticleLayer`) so it sits above every sheet, tab,
/// and feed card.
struct IncomingVibeToast: View {
    @Environment(VibesIncomingManager.self) private var manager
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let vibe = manager.latest {
                toastCard(vibe)
                    .transition(
                        .move(edge: .top)
                        .combined(with: .opacity)
                    )
                    .onAppear { scheduleDismiss() }
            }
            Spacer()
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: manager.latest?.id)
        .allowsHitTesting(manager.latest != nil)
    }

    private func toastCard(_ vibe: VibesIncomingManager.IncomingVibe) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            manager.dismissLatest()
        } label: {
            HStack(spacing: LayoutMetrics.small) {
                AvatarView(
                    url: vibe.giver.avatarUrl,
                    initial: vibe.giver.initial,
                    size: 40,
                    shadowRadius: 2,
                    shadowY: 1
                )
                VStack(alignment: .leading, spacing: 2) {
                    if vibe.crossedMilestone {
                        Text("You earned a free 3D fit!")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                        Text("Thanks to a vibe from \(vibe.giver.handle)")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.textMuted)
                    } else {
                        Text("\(vibe.giver.handle) vibed your fit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                AppIcon(
                    glyph: .flame,
                    size: 22,
                    color: AppPalette.uploadGlow,
                    filled: true
                )
                .shadow(color: AppPalette.uploadGlow.opacity(0.7), radius: 6)
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.vertical, LayoutMetrics.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard(cornerRadius: 16, shadowRadius: 12, shadowY: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, LayoutMetrics.xSmall)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            guard !Task.isCancelled else { return }
            manager.dismissLatest()
        }
    }
}

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
                toastPill(vibe)
                    .transition(
                        .move(edge: .top)
                        .combined(with: .opacity)
                    )
                    .onAppear { scheduleDismiss() }
            }
            Spacer()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: manager.latest?.id)
        .allowsHitTesting(manager.latest != nil)
    }

    /// InAppNoticePill's exact recipe (the "new like" pill): compact
    /// hug-width capsule, 12pt semibold single line, with the SAME
    /// blue-gradient flame the vibe button settles on.
    private func toastPill(_ vibe: VibesIncomingManager.IncomingVibe) -> some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            GradientFlameIcon(size: 15, stroked: true)
            Text(
                vibe.crossedMilestone
                    ? "You earned a free 3D fit!"
                    : "\(vibe.giver.handle) vibed your fit"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppPalette.textPrimary)
            .lineLimit(1)
        }
        .padding(.horizontal, LayoutMetrics.xSmall)
        .padding(.vertical, 8)
        .appCapsule(shadowRadius: 8, shadowY: 2)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            manager.dismissLatest()
        }
        .padding(.top, 4)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            manager.dismissLatest()
        }
    }
}

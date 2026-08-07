import SwiftUI

/// Explainer modal shown once, the first time the current user
/// gives a vibe. Tells them what they just did and that they
/// can earn a free 3D fit generation by receiving 5 vibes on
/// their own outfits.
///
/// Visibility is gated by `VibesEffectHost.firstUsePopupVisible`,
/// set from `maybeShowFirstUsePopup()` (UserDefaults-gated so it
/// only fires once per device, except in DEBUG). Dismissed by
/// the "Got it" button or by tapping the backdrop.
struct VibesFirstUseModal: View {
    @Environment(VibesEffectHost.self) private var host

    var body: some View {
        ZStack {
            if host.firstUsePopupVisible {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { host.dismissFirstUsePopup() }
                    .transition(.opacity)

                modalCard
                    .transition(
                        .scale(scale: 0.92, anchor: .center)
                        .combined(with: .opacity)
                    )
            }
        }
        // Fill the full screen so the modal card always centers
        // to the viewport regardless of the surface beneath.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(
            .spring(response: 0.42, dampingFraction: 0.82),
            value: host.firstUsePopupVisible
        )
    }

    private var modalCard: some View {
        VStack(spacing: LayoutMetrics.medium) {
            gradientFlame
                .padding(.top, LayoutMetrics.small)

            VStack(spacing: LayoutMetrics.small) {
                Text("You gave a vibe!")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                Text("Vibes are rare. 3 per week.\nReceive 5 to earn a little gift on us.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: { host.dismissFirstUsePopup() }) {
                Text("GOT IT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.top, LayoutMetrics.xSmall)
        }
        .padding(.horizontal, LayoutMetrics.large)
        .padding(.vertical, LayoutMetrics.large)
        .appCard(cornerRadius: 24, shadowRadius: 28, shadowY: 12)
        .padding(.horizontal, LayoutMetrics.medium)
    }

    /// Gradient-filled flame icon matching the morph's `.gradient`
    /// phase — rendered by the canonical component so every vibes
    /// surface stays in lockstep. Halo shadow preserved.
    private var gradientFlame: some View {
        GradientFlameIcon(size: 36)
            .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 10)
    }
}

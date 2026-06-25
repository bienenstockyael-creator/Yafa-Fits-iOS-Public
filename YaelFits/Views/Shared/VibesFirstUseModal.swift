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
    /// phase: yellow core fading through warm-white into cyan/blue.
    private var gradientFlame: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: Color(red: 1.00, green: 0.93, blue: 0.55), location: 0.0),
                .init(color: Color(red: 1.00, green: 0.97, blue: 0.78), location: 0.07),
                .init(color: Color(red: 0.96, green: 0.98, blue: 0.95), location: 0.22),
                .init(color: Color(red: 0.85, green: 0.95, blue: 1.00), location: 0.42),
                .init(color: Color(red: 0.65, green: 0.88, blue: 1.00), location: 0.68),
                .init(color: Color(red: 0.50, green: 0.82, blue: 1.00), location: 0.86),
                .init(color: AppPalette.uploadGlow, location: 1.0)
            ]),
            center: UnitPoint(x: 0.5, y: 0.65),
            startRadius: 0,
            endRadius: 22
        )
        .frame(width: 36, height: 36)
        .mask(AppIcon(glyph: .flame, size: 36, color: .white, filled: true))
        .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 10)
    }
}

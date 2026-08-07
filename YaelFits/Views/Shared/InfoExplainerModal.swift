import SwiftUI

/// Generic centered explainer modal for the profile credit chips.
/// Rendered at the ROOT of the app's view tree (in `YaelFitsApp`),
/// driven by `VibesEffectHost.activeInfoModal`. Root-level
/// placement is required because the chips live inside the
/// Settings sheet — a local `.overlay` would be bounded by the
/// sheet's frame and render in the sheet's lower half instead of
/// being centered to the full viewport.
struct InfoExplainerModal: View {
    @Environment(VibesEffectHost.self) private var host

    var body: some View {
        ZStack {
            if let kind = host.activeInfoModal {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { host.dismissInfoModal() }
                    .transition(.opacity)

                modalCard(for: kind)
                    .transition(
                        .scale(scale: 0.92, anchor: .center)
                        .combined(with: .opacity)
                    )
            }
        }
        // Fill the full screen so the modal card stays perfectly
        // centered in the viewport regardless of the host
        // ScrollView/sheet's frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(
            .spring(response: 0.42, dampingFraction: 0.82),
            value: host.activeInfoModal
        )
    }

    @ViewBuilder
    private func modalCard(for kind: VibesEffectHost.InfoModalKind) -> some View {
        VStack(spacing: LayoutMetrics.medium) {
            iconHeader(for: kind)
                .padding(.top, LayoutMetrics.small)

            VStack(spacing: LayoutMetrics.small) {
                Text(title(for: kind))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                Text(message(for: kind))
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: { host.dismissInfoModal() }) {
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

    // MARK: - Per-kind content

    private func title(for kind: VibesEffectHost.InfoModalKind) -> String {
        switch kind {
        case .vibes: return "Vibes"
        case .gen3D: return "3D fits"
        }
    }

    private func message(for kind: VibesEffectHost.InfoModalKind) -> String {
        switch kind {
        case .vibes:
            return "A rare reaction for outfits you love. 3 per week. Receive 5 to earn a free 3D fit."
        case .gen3D:
            return "6 free 3D fits per month. Earn a bonus every 5 vibes you receive."
        }
    }

    @ViewBuilder
    private func iconHeader(for kind: VibesEffectHost.InfoModalKind) -> some View {
        switch kind {
        case .vibes:
            // Same gradient flame as the morph's `.gradient` phase
            // and the first-use popup — visually unifies the
            // Vibes system across surfaces.
            gradientFlame
        case .gen3D:
            AppIcon(
                glyph: .sparkles,
                size: 36,
                color: AppPalette.uploadGlow,
                filled: true
            )
            .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 10)
        }
    }

    private var gradientFlame: some View {
        // The canonical vibes flame — single source of truth so every
        // surface stays in lockstep. Halo shadow preserved from the
        // previous inline rendering.
        GradientFlameIcon(size: 36)
            .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 10)
    }
}

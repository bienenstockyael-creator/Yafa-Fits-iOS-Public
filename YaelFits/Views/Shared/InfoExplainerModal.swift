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
            .buttonStyle(.plain)
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
        case .gen3D: return "3D Generations"
        }
    }

    private func message(for kind: VibesEffectHost.InfoModalKind) -> String {
        switch kind {
        case .vibes:
            return "A rare reaction for outfits you love. 3 per week. Receive 5 to earn a free 3D generation."
        case .gen3D:
            return "3 free generations per month. Earn a bonus every 5 vibes you receive."
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

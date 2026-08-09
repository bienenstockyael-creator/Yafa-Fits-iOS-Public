import SwiftUI

/// Vibes flame rendered with the same yellow-hot-core →
/// cyan/blue glow radial gradient used by the particle burst
/// (`VibesEffectHost.VibeBurstView`). Keeping the static chip /
/// profile-stat icons visually consistent with the in-flight
/// burst means a user who sees a particle erupt from a button
/// and lands on the same colored flame in their profile chip
/// reads it as "the same vibe", not two unrelated affordances.
///
/// Implementation mirrors the particle's symbol layer in
/// `VibesEffectHost.swift` (the RadialGradient stops are
/// identical) so a tweak in either location should be mirrored
/// here too. The center is pushed DOWN to (0.5, 0.65) because
/// the flame glyph is teardrop-shaped — the visual mass sits in
/// the lower 60% of the bbox, so centering the gradient at the
/// geometric middle leaves the yellow core hidden on a thin
/// strip of the icon.
struct GradientFlameIcon: View {
    /// Rendered size in points. The gradient stops are
    /// scale-invariant (positioned by location, not absolute
    /// radius) so the same color story holds at any size from
    /// chip (14pt) to badge (40pt+).
    var size: CGFloat = 14
    /// When true, overlays a thin white outline on top of the
    /// gradient fill. Useful at small sizes (≤16pt) where the
    /// radial gradient compresses to mostly the cool outer band
    /// and the silhouette gets hard to read against a light
    /// backdrop. Off by default so larger / animated uses
    /// (particle burst, hero flames) keep the soft gradient-
    /// only look they're designed for.
    var stroked: Bool = false
    /// Draw the flame mask/outline with the Path-based AppIcon variant
    /// so the icon survives ImageRenderer snapshots (story export).
    var rendererSafe: Bool = false

    var body: some View {
        ZStack {
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
                endRadius: size * 0.6
            )
            .frame(width: size, height: size)
            .mask(
                Group {
                    if rendererSafe {
                        AppIcon(glyph: .flame, size: size, color: .white, filled: true)
                            .rendererSafe
                    } else {
                        AppIcon(glyph: .flame, size: size, color: .white, filled: true)
                    }
                }
            )

            if stroked {
                // Hairline white outline. ~3% of diameter (min
                // 0.4pt) so it reads as a delicate highlight on
                // the gradient rather than a frame around it.
                let outline = AppIcon(
                    glyph: .flame,
                    size: size,
                    color: .white,
                    filled: false,
                    strokeWidth: max(0.4, size * 0.03)
                )
                if rendererSafe {
                    outline.rendererSafe
                } else {
                    outline
                }
            }
        }
        // Whisper-soft drop shadow so the flame just barely
        // lifts off light backdrops. Tuned to be felt more than
        // seen — anything heavier reads as a deliberate halo
        // effect rather than ambient depth.
        .shadow(color: Color.black.opacity(0.08), radius: 2, y: 0.5)
    }
}

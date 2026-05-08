import SwiftUI

/// Conditionally applies the holographic card overlay (Holo.metal +
/// HoloMotionTracker). When `active` is false the modifier is a no-op
/// so non-Pro cards pay zero shader cost.
///
/// The overlay is a `Color.white`-filled rounded-rect with the holo
/// shader as a `.colorEffect`, then `.blendMode(.multiply)` so the
/// shader's near-white output composites cleanly over the card photo
/// while the chromatic edge tints come through.
struct HoloCardModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if active {
                    HoloOverlay(cornerRadius: cornerRadius)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                if active { HoloMotionTracker.shared.start() }
            }
            .onDisappear {
                if active { HoloMotionTracker.shared.stop() }
            }
    }
}

/// Max tilt in degrees at ±1 normalized roll/pitch. Subtle enough to
/// feel like a sticker pinned in space, not a wobbling toy.
private let proCardTiltDegrees: Double = 6

/// Applies a gyro-driven 3D tilt. Apply AFTER all card decoration
/// (holo shader, .appCard, shadows, overlays) so everything tilts
/// together as one unit — otherwise the fixed decoration becomes a
/// visible "ghost" behind the rotated content.
///
/// Uses a single `rotation3DEffect` (one offscreen pass) instead of
/// stacking pitch+roll rotations (two passes). The composite axis is
/// the tilt vector itself; for the small angles we use (±6°) the two
/// formulations are visually indistinguishable.
struct ProCardTiltModifier: ViewModifier {
    let active: Bool

    private let motion = HoloMotionTracker.shared

    func body(content: Content) -> some View {
        if active {
            // Tilt vector in screen-plane axis convention:
            //   pitch positive (top of phone tilts away)  → rotate around +X
            //   roll  positive (right of phone tilts away) → rotate around +Y
            // Sign on pitch is negated to match the previous behavior.
            let axisX = -motion.pitch
            let axisY = motion.roll
            let mag = max(sqrt(axisX * axisX + axisY * axisY), 1e-5)
            return AnyView(
                content.rotation3DEffect(
                    .degrees(mag * proCardTiltDegrees),
                    axis: (x: axisX / mag, y: axisY / mag, z: 0),
                    perspective: 0.6
                )
            )
        } else {
            return AnyView(content)
        }
    }
}

private struct HoloOverlay: View {
    let cornerRadius: CGFloat

    @State private var startDate = Date()

    var body: some View {
        GeometryReader { geo in
            // 30Hz cap — holo shimmer doesn't benefit from 60/120Hz on
            // ProMotion devices; capping cuts GPU work proportionally
            // while remaining visually smooth for the slow shimmer.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSince(startDate)
                let motion = HoloMotionTracker.shared
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .colorEffect(
                        ShaderLibrary.holoCard(
                            .float(Float(t)),
                            .float(Float(geo.size.width)),
                            .float(Float(geo.size.height)),
                            .float(Float(motion.roll)),
                            .float(Float(motion.pitch)),
                            .float(Float(cornerRadius))
                        )
                    )
                    .blendMode(.multiply)
            }
        }
    }
}

extension View {
    func holoCard(active: Bool, cornerRadius: CGFloat = LayoutMetrics.cardCornerRadius) -> some View {
        modifier(HoloCardModifier(active: active, cornerRadius: cornerRadius))
    }

    func proCardTilt(active: Bool) -> some View {
        modifier(ProCardTiltModifier(active: active))
    }
}

import SwiftUI

private struct BlurFadeRevealModifier: ViewModifier {
    let active: Bool
    let delay: Double
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .blur(radius: active ? 0 : blurRadius)
            .animation(
                active
                ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.98).delay(delay)
                : .timingCurve(0.4, 0, 0.2, 1, duration: 0.76).delay(delay * 0.35),
                value: active
            )
    }
}

private struct ViewportBlurFadeModifier: ViewModifier {
    let enabled: Bool
    let axis: Axis
    let blurRadius: CGFloat
    let appliesBlur: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.scrollTransition(.animated(.timingCurve(0.16, 1, 0.3, 1, duration: 0.92)), axis: axis) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0)
                    .blur(radius: appliesBlur && !phase.isIdentity ? blurRadius : 0)
            }
        } else {
            content
        }
    }
}

// MARK: - Header Proximity Fade

private struct HeaderProximityFadeModifier: ViewModifier {
    let headerBottom: CGFloat
    let fadeZone: CGFloat

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, proxy in
                let globalTop = proxy.frame(in: .global).minY
                let fadeStart = headerBottom + fadeZone
                let progress = globalTop < fadeStart
                    ? max(0, min(1, (fadeStart - globalTop) / fadeZone))
                    : 0
                return effect
                    .opacity(1 - Double(progress))
                    .blur(radius: progress * 6)
            }
    }
}

// MARK: - Anchor Transition (matchedGeometryEffect on the anchor cell only)

/// Always applies `matchedGeometryEffect` (so view identity is stable —
/// cells don't remount when the anchor flag flips, which preserves the
/// morph), but gives non-anchor cells a UNIQUE-PER-VIEW id so they
/// have no match anywhere in the namespace and don't share state with
/// any other cell. Only the actual anchor cell uses the shared
/// `outfitId`, which is what the matching anchor cell in the other
/// view also uses — so they connect and morph.
private struct AnchorTransitionModifier: ViewModifier {
    let outfitId: String
    let namespace: Namespace.ID
    let isAnchor: Bool
    let viewName: String
    let isSource: Bool

    func body(content: Content) -> some View {
        content.matchedGeometryEffect(
            id: isAnchor ? outfitId : "private-\(viewName)-\(outfitId)",
            in: namespace,
            anchor: .center,
            isSource: isSource
        )
    }
}

extension View {
    func anchorTransition(
        outfitId: String,
        namespace: Namespace.ID,
        isAnchor: Bool,
        viewName: String,
        isSource: Bool
    ) -> some View {
        modifier(AnchorTransitionModifier(
            outfitId: outfitId,
            namespace: namespace,
            isAnchor: isAnchor,
            viewName: viewName,
            isSource: isSource
        ))
    }

    func blurFadeReveal(active: Bool, delay: Double = 0, blurRadius: CGFloat = 12) -> some View {
        modifier(BlurFadeRevealModifier(active: active, delay: delay, blurRadius: blurRadius))
    }

    func viewportBlurFade(
        enabled: Bool = true,
        axis: Axis = .vertical,
        blurRadius: CGFloat = 12,
        appliesBlur: Bool = true
    ) -> some View {
        modifier(
            ViewportBlurFadeModifier(
                enabled: enabled,
                axis: axis,
                blurRadius: blurRadius,
                appliesBlur: appliesBlur
            )
        )
    }

    func headerProximityFade(headerBottom: CGFloat, fadeZone: CGFloat) -> some View {
        modifier(HeaderProximityFadeModifier(headerBottom: headerBottom, fadeZone: fadeZone))
    }
}

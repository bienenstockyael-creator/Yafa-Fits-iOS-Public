import SwiftUI

private struct BlurFadeRevealModifier: ViewModifier {
    let active: Bool
    let delay: Double
    let blurRadius: CGFloat

    /// Internal mirror of `active`, flipped inside its own
    /// `withAnimation` transaction. Driving opacity/blur straight off
    /// the external value with `.animation(_:value:)` injected the
    /// (per-index delayed) animation into the WHOLE update transaction
    /// — so when the reveal coincided with LazyVGrid layout settling
    /// or scroll restoration (tab return), cell POSITIONS animated too
    /// and the grid visibly cascaded down from the top. Mirroring
    /// through local state means the only thing that changes in the
    /// animated transaction is `shown` → opacity + blur only; geometry
    /// snaps into place unanimated.
    @State private var shown: Bool

    init(active: Bool, delay: Double, blurRadius: CGFloat) {
        self.active = active
        self.delay = delay
        self.blurRadius = blurRadius
        _shown = State(initialValue: active)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : blurRadius)
            .onChange(of: active) { _, newValue in
                let animation: Animation = newValue
                    ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.98).delay(delay)
                    : .timingCurve(0.4, 0, 0.2, 1, duration: 0.76).delay(delay * 0.35)
                withAnimation(animation) { shown = newValue }
            }
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
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, proxy in
                let globalTop = proxy.frame(in: .global).minY
                let fadeStart = headerBottom + fadeZone
                // NO lower bound on globalTop: a cell scrolled PAST
                // the band must STAY at full fade, or its tail snaps
                // back to full visibility over the status bar the
                // moment its top crosses the screen edge (tall 2-col
                // cells made this glaring). The old `globalTop > 1`
                // guard defended against "randomly disappearing"
                // mid-screen cells, but that bug was decode starvation
                // (fixed in FrameLoader usage), not stale fade
                // geometry.
                let progress = enabled && globalTop < fadeStart
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

    func headerProximityFade(headerBottom: CGFloat, fadeZone: CGFloat, enabled: Bool = true) -> some View {
        modifier(HeaderProximityFadeModifier(headerBottom: headerBottom, fadeZone: fadeZone, enabled: enabled))
    }
}

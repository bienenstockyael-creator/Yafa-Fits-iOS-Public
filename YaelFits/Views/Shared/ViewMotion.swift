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

// MARK: - Grid Transition Reveal

private struct GridTransitionRevealModifier: ViewModifier {
    let phase: ViewTransitionPhase
    let isList: Bool
    let staggerIndex: Int

    private var isRevealing: Bool {
        phase == .targetIn && isList
    }

    private var isHiding: Bool {
        phase == .sourceOut && isList
    }

    private var targetOpacity: Double {
        if isHiding { return 0 }
        return 1
    }

    private var targetBlur: CGFloat {
        if isHiding { return 8 }
        return 0
    }

    private var staggerDelay: Double {
        if isRevealing { return Double(staggerIndex) * 0.035 }
        if isHiding { return Double(staggerIndex) * 0.015 }
        return 0
    }

    func body(content: Content) -> some View {
        content
            .opacity(targetOpacity)
            .blur(radius: targetBlur)
            .animation(
                isRevealing
                    ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.7).delay(staggerDelay)
                    : .timingCurve(0.4, 0, 0.2, 1, duration: 0.4).delay(staggerDelay),
                value: phase
            )
    }
}

extension View {
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

    func gridTransitionReveal(phase: ViewTransitionPhase, isList: Bool, staggerIndex: Int) -> some View {
        modifier(GridTransitionRevealModifier(phase: phase, isList: isList, staggerIndex: staggerIndex))
    }

    func headerProximityFade(headerBottom: CGFloat, fadeZone: CGFloat) -> some View {
        modifier(HeaderProximityFadeModifier(headerBottom: headerBottom, fadeZone: fadeZone))
    }
}

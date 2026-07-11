import SwiftUI
import UIKit

/// Fire-icon "vibe" reaction button. Lives on the bottom-right
/// of every feed card. Three visible states:
///   - active: user has quota left and hasn't vibed this outfit
///   - vibed:  user already vibed this outfit (final, no undo)
///   - locked: out of vibes this week (button still visible but
///             tapping shakes + shows an out-of-vibes toast)
///
/// Tap interaction is optimistic: the burst fires the instant
/// the user taps (haptic + particles) while the RPC is in
/// flight. If the RPC ultimately fails, we revert the count.
///
/// The particle burst is NOT rendered inside the button — it's
/// routed through `VibesEffectHost` so the root view can render
/// it above all feed cards (otherwise particles would be clipped
/// by the card boundaries / scroll view).
struct VibeButton: View {
    let outfitId: String
    @Binding var vibeCount: Int
    @Binding var isVibedByMe: Bool
    @Binding var remainingThisWeek: Int

    @Environment(VibesEffectHost.self) private var burstHost
    /// Global-coordinate center of the FLAME ICON itself (not the
    /// button's bounding frame). Captured by a `GeometryReader` on
    /// the 40×40 flame container, so the particle burst + wave
    /// shader spawn from the exact pixel the icon sits on. The
    /// previous implementation used the button's outer frame
    /// center, which is offset from the icon (the un-vibed chrome
    /// sits to one side, the vibed layout has the flame at the
    /// HStack's leading edge) — that mismatch made the burst
    /// origin drift off the icon.
    @State private var iconGlobalCenter: CGPoint = .zero
    @State private var shakeOffset: CGFloat = 0
    /// Local flag, true while THIS button's morph is in flight.
    /// Set synchronously at tap time, cleared when host clears.
    @State private var isMorphingThisButton = false

    // Hero morph state has moved to `VibesEffectHost` /
    // `VibesMorphLayer`. The button itself only renders its
    // resting form (outline when un-vibed, filled when vibed);
    // the bloom + phase morph happens at the root level above
    // the wave shader snapshot.

    private enum VibeState {
        case active
        case vibed
        case locked
    }

    private var state: VibeState {
        if isVibedByMe { return .vibed }
        if remainingThisWeek <= 0 { return .locked }
        return .active
    }

    var body: some View {
        Button(action: handleTap) {
            flameContainer
                .contentShape(Rectangle())
                .offset(x: shakeOffset)
        }
        .buttonStyle(SolidPressButtonStyle())
        .frame(minHeight: LayoutMetrics.touchTarget)
        .onChange(of: isVibedByMe) { _, vibed in
            // Re-anchor the morph at multiple points throughout
            // the reflow window. GeometryReader's `onChange` is
            // unreliable about firing on intermediate frames of a
            // `withAnimation` reflow, and the layout's final
            // position depends on the inline count's width
            // (which changes when the count crosses a digit
            // boundary — e.g., 9→10 makes the count text wider,
            // pushing the flame further left). Sampling
            // `iconGlobalCenter` at multiple post-reflow times
            // guarantees we catch the truly-settled value.
            guard vibed else { return }
            Task { @MainActor in
                // Relative delays (cumulative) — updates fire at
                // absolute times 100, 250, 400, 600ms after tap.
                // 600ms is well past the 250ms reflow window AND
                // gives the morph's .animation(0.35) plenty of
                // time to settle before the morph clears at
                // 1132ms.
                let relativeDelaysMs: [UInt64] = [100, 150, 150, 200]
                for delay in relativeDelaysMs {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                    burstHost.updateMorphCenter(iconGlobalCenter)
                }
            }
        }
        .onChange(of: vibeCount) { _, _ in
            // Whenever the count value itself changes during a
            // morph (digit-boundary crossing), the layout
            // reflows and the icon's global position shifts.
            // Re-anchor immediately on the next layout pass.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                burstHost.updateMorphCenter(iconGlobalCenter)
            }
        }
        .onChange(of: burstHost.morphBurst?.id) { _, newId in
            // Morph ended — reveal the live button by clearing
            // the local flag (opacity snaps to 1, instant). The
            // morph's own scale-down curve has already done the
            // spring settle, so there's nothing else to animate
            // here — the live button just appears at scale 1.0
            // matching the morph's final frame.
            if newId == nil && isMorphingThisButton {
                isMorphingThisButton = false
            }
        }
    }

    /// 40×40 ZStack holding the flame icon. Position of the flame
    /// is identical whether the button is unvibed, mid-animation,
    /// or settled-vibed — that consistency is what fixes the
    /// "icon morph drifts off-center" issue from the previous
    /// hero-overlay implementation.
    private var flameContainer: some View {
        ZStack(alignment: .topTrailing) {
            // Layer 1: chrome (blur + tint + border). Only present
            // when unvibed. Conditional render (rather than opacity
            // 0) so the ZStack's intrinsic size shrinks once vibed.
            //
            // No `.transition(.opacity)` — the chrome's removal is
            // instant. Adding a transition fade meant the chrome
            // was at ~13% opacity in the wave-shader snapshot
            // (which fires 32ms into the 0.25s transition),
            // leaving a faint ghost chrome visible for the wave's
            // entire 1.1s lifetime.
            if !isVibedByMe {
                chromeBackground
            }

            // Layer 2: the flame icon. 40×40 padded when unvibed
            // (so it sits centered inside the chrome circle); tight
            // 18×40 when vibed (no chrome to fill, count goes
            // right next to it). The frame change is what causes
            // the icon's global position to shift on tap, which
            // the morph layer follows via `updateMorphCenter`.
            flameView
                .frame(width: isVibedByMe ? 26 : 40, height: 40)

            // Layer 3: small count badge in the upper-right when
            // unvibed + count > 0.
            if showBadge {
                badgeView
                    .offset(x: isVibedByMe ? 10 : 4, y: -2)
                    .transition(.opacity.animation(.easeIn(duration: 0.28)))
            }
        }
        // Hide the entire flame container (chrome + icon + badge)
        // while the morph is active for THIS button — opacity is
        // computed DIRECTLY from `isMorphActive` so the change
        // lands in the SAME body render that observes the new
        // `morphBurst`. An indirection through @State+onChange
        // would split this across two renders, leaving the
        // wave-shader snapshot to catch the button still visible
        // in the first.
        //
        // Fade-out: instant (no animation when isMorphActive
        // becomes true).
        // Fade-in: 0.18s easeInOut (when the morph clears).
        // Conditional animation lets us pick per-direction.
        .opacity(isMorphActive ? 0 : 1)
        // Opacity instant in both directions. No scale animation
        // here — the morph's own scale-down curve now has a
        // spring-like undershoot built in, settling at 1.0 by
        // the time the morph clears. The live button takes over
        // at scale 1.0 with no further spring (which would have
        // been the "second bounce" you saw).
        .animation(nil, value: isMorphActive)
        .frame(height: 40)
        .background(
            // Capture the flame's actual on-screen center so the
            // particle burst + wave shader spawn from the icon
            // position itself, not the outer button frame.
            GeometryReader { geo in
                Color.clear
                    .onAppear { updateIconCenter(geo) }
                    .onChange(of: geo.frame(in: .global)) { old, new in
                        updateIconCenter(geo)
                        // Feed scrolled: dismiss any anchored pill
                        // so it doesn't trail behind the scrolling
                        // content. VERTICAL movement only — the
                        // out-of-vibes shake offsets this very
                        // button horizontally, and dismissing on
                        // any frame change killed that pill the
                        // same frame it appeared (haptic + shake
                        // played, pill never seen).
                        if abs(old.midY - new.midY) > 0.5,
                           burstHost.anchoredPill != nil {
                            burstHost.anchoredPill = nil
                        }
                    }
            }
        )
    }

    /// Matches the chrome of the heart / comment / bookmark
    /// buttons via the shared `.appCircle()` modifier.
    private var chromeBackground: some View {
        Color.clear
            .frame(width: 40, height: 40)
            .appCircle(shadowRadius: 0, shadowY: 0)
    }

    /// Resting flame icon — outline when un-vibed/locked, filled
    /// when vibed. The bloom + phase morph during a tap happens
    /// at the root level via `VibesMorphLayer`, not here.
    @ViewBuilder
    private var flameView: some View {
        if isVibedByMe {
            // Post-vibe ("you vibed this, can't again") state. Uses
            // the exact same gradient flame as the profile vibes
            // stat (`GradientFlameIcon(size: 24, stroked: true)` in
            // ProfileHeader / UserProfileSheet) so a fit you've
            // vibed on the feed reads as the same affordance as the
            // vibe count on a profile — one shared visual identity,
            // not a flat-blue lookalike. `stroked` keeps the
            // silhouette legible at this smaller size.
            GradientFlameIcon(size: 26, stroked: true)
        } else {
            let color = state == .locked
                ? AppPalette.textFaint
                : AppPalette.iconPrimary
            AppIcon(
                glyph: .flame,
                size: 18,
                color: color,
                filled: false,
                strokeWidth: 2.4
            )
        }
    }

    /// Small count badge in the upper-right corner.
    private var badgeView: some View {
        VibeCountBadge(count: vibeCount)
    }

    /// Badge shows in BOTH states — same top-right treatment as
    /// the heart/comment buttons, so counts read consistently
    /// across the action row. (The vibed state used to put the
    /// count inline beside the flame, which was both a different
    /// visual language AND a layout reflow the morph had to chase.)
    private var showBadge: Bool {
        // Held back while the morph is in flight so the number
        // FADES IN once the flame has settled, instead of being
        // baked into the reveal frame.
        vibeCount > 0 && !isMorphActive
    }

    /// True when THIS button's morph is in flight. Read from the
    /// local `isMorphingThisButton` flag — set synchronously at
    /// tap time, cleared when the host's morphBurst clears.
    /// Local flag avoids the position-matching fragility of the
    /// previous implementation, which could flicker false when
    /// the button reflowed during the morph.
    private var isMorphActive: Bool {
        isMorphingThisButton
    }

    private func updateIconCenter(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .global)
        let newCenter = CGPoint(x: frame.midX, y: frame.midY)
        iconGlobalCenter = newCenter
        // If a morph is currently in flight for this button (the
        // button just reflowed because `isVibedByMe` flipped and
        // the inline count appeared), re-anchor it to the new
        // flame position. The morph view animates this position
        // change, so the morphing icon slides smoothly into its
        // final vibed-state spot rather than cutting after the
        // morph finishes.
        burstHost.updateMorphCenter(newCenter)
    }

    // MARK: - Tap handling

    private func handleTap() {
        switch state {
        case .vibed:
            return
        case .locked:
            Analytics.log("vibe_out_of_vibes_tapped")
            triggerShakeAndToast()
            return
        case .active:
            optimisticallyVibe()
        }
    }

    private func optimisticallyVibe() {
        Analytics.log(
            "vibe_given",
            properties: ["outfit_id": .string(outfitId)]
        )

        // Mark this button as morphing FIRST, synchronously.
        // The flame container + inline count read this flag to
        // set opacity 0 in the same render pass — well before
        // the wave-shader snapshot fires.
        isMorphingThisButton = true

        // Orchestrate the whole burst.
        burstHost.startVibeBurst(at: iconGlobalCenter)

        // Data state changes — the chrome fade + inline count
        // appearance animate in sync with the morph.
        withAnimation(.easeOut(duration: 0.25)) {
            isVibedByMe = true
            vibeCount += 1
            remainingThisWeek = max(0, remainingThisWeek - 1)
        }

        // Haptic fires IMMEDIATELY (caller's responsibility) —
        // provides instant tactile feedback during the 32ms
        // window before the visual effect kicks in.
        VibeHapticPlayer.shared.playWaveBurst()

        // First-vibe explainer modal — appears partway through
        // the burst (not after it fully clears) so the user
        // doesn't perceive a long awkward delay between their
        // tap and the explainer. Dimmed backdrop covers the
        // remaining wave/burst visuals underneath.
        // UserDefaults-gated so it only fires the very first time.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            burstHost.maybeShowFirstUsePopup()
        }

        Task {
            let result = await VibesService.giveVibe(outfitId: outfitId)
            switch result {
            case .success(let remaining):
                await MainActor.run { remainingThisWeek = remaining }
            case .alreadyVibed:
                await MainActor.run { vibeCount = max(0, vibeCount - 1) }
            case .quotaExhausted:
                await MainActor.run {
                    isVibedByMe = false
                    vibeCount = max(0, vibeCount - 1)
                    remainingThisWeek = 0
                    triggerShakeAndToast()
                }
            case .selfVibe, .outfitNotFound, .unauthenticated, .networkError:
                await MainActor.run {
                    isVibedByMe = false
                    vibeCount = max(0, vibeCount - 1)
                    remainingThisWeek = min(3, remainingThisWeek + 1)
                }
            }
        }
    }

    /// Hero animation timeline (cuts, not crossfades):
    ///
    ///   t=0      outline icon, scale 1.0, scale animation kicks off
    ///   t=0.08s  CUT outline → gradient   (mid scale-up, fast motion)
    ///   t=0.18s  scale peaks at 2.0; spring-down kicks off
    ///   t=0.30s  CUT gradient → filled    (mid scale-down, fast motion)
    ///   t=0.58s  scale settles at 1.0
    ///   t=0.58s  opacity fade kicks off
    ///   t=0.98s  fade complete, hero torn down
    ///
    /// The discrete swaps land while the scale animation is moving
    /// fastest, so the perceptual motion blur masks the swap and
    /// the icon reads as one continuous "flash-through" rather than
    /// three separate states blending. Crossfading the swaps
    /// instead produced a muddy in-between state — that's what the
    /// previous implementation was doing.
    private func triggerShakeAndToast() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        withAnimation(.interpolatingSpring(stiffness: 800, damping: 6)) {
            shakeOffset = -8
        }
        withAnimation(.interpolatingSpring(stiffness: 800, damping: 6).delay(0.06)) {
            shakeOffset = 8
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.18)) {
            shakeOffset = 0
        }
        // Pop a small pill ABOVE the tapped button. Rendered at
        // root via the host so the scroll view can't clip it,
        // but anchored at the button's screen position so it
        // visually belongs to this button.
        burstHost.showAnchoredPill(
            "You're out of vibes",
            at: iconGlobalCenter
        )
    }
}

/// Read-only vibes display for the author's OWN posts. You can't
/// vibe yourself (the RPC blocks it), so this is not a button —
/// but you should still see what your post received. Mirrors the
/// settled-vibed VibeButton exactly (26pt gradient flame +
/// top-right count badge) so vibes read identically everywhere;
/// wire a long-press at the call site to open the vibers list,
/// matching the other action icons.
struct VibeCountDisplay: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GradientFlameIcon(size: 26, stroked: true)
                .frame(width: 26, height: 40)

            VibeCountBadge(count: count)
                .offset(x: 10, y: -2)
        }
        .frame(height: 40)
    }
}

/// Count bubble for vibe icons, styled to match the generation
/// tab's in-flight badge: 18pt circle, uploadGlow numeral on a
/// white blur fill with a soft uploadGlow halo, hairline border.
struct VibeCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(AppPalette.uploadGlow)
            .frame(width: 18, height: 18)
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .fill(Color.white.opacity(0.96))
                            .shadow(
                                color: AppPalette.uploadGlow.opacity(0.55),
                                radius: 8,
                                y: 0
                            )
                    )
            }
            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .contentTransition(.numericText(value: Double(count)))
    }
}

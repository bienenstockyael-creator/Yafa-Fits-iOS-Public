import SwiftUI

/// Holds active vibe-burst events so the root view can render
/// them above all feed cards. Without this portal, particles
/// rendered locally inside `VibeButton` get clipped by the
/// feed card / scroll view boundaries — and the user wants
/// the burst "above everything on the viewport."
///
/// Injected once at the root via `.environment(VibesEffectHost())`
/// and consumed by both `VibeButton` (which appends bursts on
/// tap) and `VibesParticleLayer` (which renders them).
@Observable
final class VibesEffectHost {
    /// Currently-on-screen bursts. Each one auto-removes from
    /// the array after its lifetime.
    var activeBursts: [Burst] = []
    /// Anchored pill currently shown above a specific button
    /// (typically "You're out of vibes"). Rendered globally
    /// from the root layer at the button's screen-global
    /// position so it isn't clipped by the scroll view.
    var anchoredPill: AnchoredPill?
    /// Currently-active wave shader burst. When set, the root
    /// `.layerEffect` runs the `vibeWave` Metal shader,
    /// distorting + glowing the underlying UI. Cleared after
    /// the burst's lifetime.
    var waveShader: WaveShaderBurst?
    /// Currently-active hero morph (the gradient-flame bloom on
    /// the tapped vibe button). Rendered at the ROOT level, above
    /// the wave shader's static snapshot — that's why the morph
    /// is hosted here instead of inside `VibeButton`. The button
    /// itself is hidden behind the wave-shader snapshot during
    /// the burst, so any in-button morph is invisible.
    var morphBurst: MorphBurst?
    /// Pre-snapshot "vibe is starting" position. Set the instant
    /// the user taps, BEFORE the snapshot fires. The morph and
    /// particles don't start rendering until AFTER the snapshot
    /// is captured (so neither is baked into the snapshot as a
    /// frozen ghost) — but the tapped button still needs to know
    /// it should hide itself for the snapshot. This flag bridges
    /// that window. Cleared once `morphBurst` is set (the morph
    /// then drives button-hide via position match).
    var pendingVibeAt: CGPoint?
    /// First-use popup visibility — true while the explanatory
    /// modal "you gave a vibe! get 5 to earn a free 3D fit" is on
    /// screen. Shown once per device (UserDefaults-gated).
    var firstUsePopupVisible = false

    /// UserDefaults key tracking whether this device has already
    /// seen the first-vibe explainer popup.
    private static let firstUsePopupKey = "hasShownVibeFirstUseModal"
    /// One-shot migration key. Devices that triggered the
    /// first-use popup under the old DEBUG override (which fired
    /// the popup on EVERY vibe and also set
    /// `firstUsePopupKey = true` each time) ended up with the
    /// flag latched, blocking the popup on the next legitimate
    /// first vibe. Bumping this key clears the latched flag once
    /// so those devices get a clean first-vibe experience again.
    /// Bump the version suffix to re-run the migration in a
    /// future release.
    private static let firstUseMigrationKey = "vibeFirstUseMigration_v1"

    init() {
        Self.runFirstUseMigrationIfNeeded()
    }

    /// One-time clear of the legacy popup-seen flag. No-op after
    /// the first call per device (per migration version).
    private static func runFirstUseMigrationIfNeeded() {
        if UserDefaults.standard.bool(forKey: firstUseMigrationKey) { return }
        UserDefaults.standard.removeObject(forKey: firstUsePopupKey)
        UserDefaults.standard.set(true, forKey: firstUseMigrationKey)
    }

    /// Call after a successful first vibe. Shows the explainer
    /// modal if it hasn't been shown on this device before;
    /// otherwise no-op. Idempotent — second call is a no-op.
    func maybeShowFirstUsePopup() {
        if UserDefaults.standard.bool(forKey: Self.firstUsePopupKey) { return }
        firstUsePopupVisible = true
        UserDefaults.standard.set(true, forKey: Self.firstUsePopupKey)
    }

    /// Dismiss the first-use popup. Called from the modal's
    /// "Got it" button or backdrop tap.
    func dismissFirstUsePopup() {
        firstUsePopupVisible = false
    }

    /// Identifies which info-explainer modal (if any) is currently
    /// open. These are presented at the root of the app's view
    /// tree (via `InfoExplainerModal`), so they sit above any
    /// sheet, tab, or feed card and stay centered to the viewport
    /// regardless of which surface initiated them.
    enum InfoModalKind: Identifiable, Equatable {
        case vibes
        case gen3D
        var id: Self { self }
    }
    var activeInfoModal: InfoModalKind?

    func showInfoModal(_ kind: InfoModalKind) {
        activeInfoModal = kind
    }

    func dismissInfoModal() {
        activeInfoModal = nil
    }

    struct Burst: Identifiable {
        let id = UUID()
        /// Screen-global center where particles spawn.
        let center: CGPoint
        /// Wall-clock start so the renderer can compute progress.
        let startDate: Date
    }

    struct AnchoredPill: Identifiable {
        let id = UUID()
        let text: String
        /// Screen-global point the pill should anchor ABOVE.
        /// Typically the center of the button the user tapped.
        let anchor: CGPoint
    }

    struct MorphBurst: Identifiable {
        let id: UUID
        /// Screen-global pixel where the morph should render. NOT
        /// constant — the tapped button's layout reflows when the
        /// inline count appears (HStack grows, leading edge shifts
        /// left). The morph view animates its position whenever
        /// this center updates, so the morphing icon slides
        /// smoothly into its final vibed-state position rather
        /// than cutting after the morph completes.
        var center: CGPoint
        /// Wall-clock start; the morph view computes its current
        /// scale + phase from elapsed time via a `TimelineView`.
        let startDate: Date

        init(center: CGPoint) {
            self.id = UUID()
            self.center = center
            self.startDate = Date()
        }
    }

    struct WaveShaderBurst: Identifiable {
        let id = UUID()
        /// Screen-global tap point passed into the shader as
        /// the wave origin.
        let tapPoint: CGPoint
        /// Wall-clock start so the `TimelineView` driving the
        /// shader can compute elapsed time and feed `progress`
        /// in [0, 1].
        let startDate: Date
        /// Snapshot of the UI captured at tap time. The wave
        /// distortion shader operates on this static bitmap
        /// (because the live view tree can't be sampled — it
        /// has UIViewRepresentables that break flattening).
        /// Image is rasterized so layerEffect works on it.
        let snapshot: UIImage?
    }

    /// Burst lifetime in seconds. Aligned with morphBurstLifetime
    /// below so the wave halo, snapshot, and morph icon all clear
    /// in the same render frame for a seamless hand-off to the
    /// live button.
    static let waveShaderLifetime: TimeInterval = 1.05

    static let lifetime: TimeInterval = 1.25

    /// Morph burst lifetime — matches `waveShaderLifetime`, so
    /// morph + wave clear together in the atomic-clear Task in
    /// `startVibeBurst`. The internal morph animation (0.62s)
    /// settles well before this; the extra ~430ms lets the icon
    /// rest at scale 1.0 while the wave finishes its halo fade.
    static let morphBurstLifetime: TimeInterval = 1.05

    /// Unified entry point for a vibe burst. Solves the
    /// "snapshot contains a ghost copy of the morph/particles"
    /// problem by sequencing the effects:
    ///
    ///   t=0    Set `pendingVibeAt`. The tapped button observes
    ///          this and hides itself (opacity 0) immediately.
    ///          Haptic fires (caller's responsibility) for
    ///          instant tactile feedback.
    ///   t=32ms Capture window snapshot. By now SwiftUI has
    ///          rendered with the button hidden — and the morph
    ///          + particle layers are still empty (we haven't
    ///          triggered them yet). Snapshot is clean.
    ///   t=32ms Start morph + particles + wave shader (sharing
    ///          the snapshot we just took). Clear
    ///          `pendingVibeAt`; `morphBurst` now drives button
    ///          hide via position-match.
    ///   t=...  Each effect auto-clears at the end of its
    ///          lifetime (morph 1.1s, wave 1.0s, particles 1.2s).
    func startVibeBurst(at point: CGPoint) {
        pendingVibeAt = point
        Task { @MainActor in
            // Two-frame wait + `afterScreenUpdates: true` on the
            // snapshot gives SwiftUI plenty of time to commit the
            // button-hide render.
            try? await Task.sleep(nanoseconds: 32_000_000)
            let snapshot = WindowSnapshot.capture()

            let now = Date()
            // Particle burst — emerges at `point` (the same flame
            // the morph is about to bloom from).
            let particle = Burst(center: point, startDate: now)
            activeBursts.append(particle)

            // Wave shader — uses the just-captured snapshot for
            // the distortion. Snapshot is clean (no morph, no
            // particles, hidden button), so there's nothing for
            // the wave to "leave behind" as a ghost.
            let wave = WaveShaderBurst(
                tapPoint: point,
                startDate: now,
                snapshot: snapshot
            )
            waveShader = wave

            // Hero morph at root level, above the wave's
            // snapshot.
            let morph = MorphBurst(center: point)
            morphBurst = morph
            // Clear the pre-snapshot signal — morphBurst now
            // drives button hiding.
            pendingVibeAt = nil

            // Atomic clear of morph + wave in a SINGLE Task so
            // they disappear in the same render frame. Previously
            // separate Tasks could fire a few ms apart, briefly
            // leaving the morph icon visible without the wave's
            // halo backdrop (or vice versa) — visible as a
            // micro-flicker at the very end of the burst.
            // Particles use their own (longer) lifetime since
            // they trail off naturally rather than ending in sync.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.morphBurstLifetime * 1_000_000_000))
                if morphBurst?.id == morph.id { morphBurst = nil }
                if waveShader?.id == wave.id { waveShader = nil }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
                activeBursts.removeAll { $0.id == particle.id }
            }
        }
    }

    /// Trigger the hero morph at the tapped vibe button's flame
    /// center. The morph view (`VibesMorphLayer`) walks the icon
    /// through outline → gradient → filled with a scale bloom,
    /// driven by elapsed time off `startDate`.
    func triggerMorph(at point: CGPoint) {
        let burst = MorphBurst(center: point)
        let id = burst.id
        morphBurst = burst
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.morphBurstLifetime * 1_000_000_000)
            )
            if morphBurst?.id == id {
                morphBurst = nil
            }
        }
    }

    /// Re-anchor the active morph burst to a new screen-global
    /// position. Called by `VibeButton` when its flame-container
    /// frame shifts after the post-tap layout reflow — the morph
    /// view then animates its position from the old anchor to
    /// the new one, so the morphing icon slides smoothly into
    /// its final vibed-state position.
    func updateMorphCenter(_ point: CGPoint) {
        guard var burst = morphBurst else { return }
        guard burst.center != point else { return }
        burst.center = point
        morphBurst = burst
    }

    func trigger(at point: CGPoint) {
        let burst = Burst(center: point, startDate: Date())
        activeBursts.append(burst)
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.lifetime * 1_000_000_000)
            )
            activeBursts.removeAll { $0.id == burst.id }
        }
    }

    /// Fire the wave-distortion shader burst at the given
    /// screen-global tap point. Auto-clears after the shader's
    /// lifetime. Replaces any in-flight burst (you can only
    /// have one wave shader running at a time — running two
    /// would be visually incoherent).
    ///
    /// Captures a UIKit snapshot of the live window first —
    /// the distortion shader operates on that static bitmap
    /// while it overlays the live UI for the burst duration.
    func triggerWaveShader(at point: CGPoint) {
        // Wait TWO frames (~32ms) before capturing the snapshot,
        // not just a `Task.yield()`. The caller has just set
        // `morphBurst` (which triggers the vibe button to hide
        // itself via `.opacity(isMorphActive ? 0 : 1)`) and
        // toggled `isVibedByMe` (which fades chrome / swaps to
        // filled icon). One `Task.yield()` resumes before SwiftUI
        // has committed those visual changes to the screen —
        // the snapshot would catch the "before" frame and leave
        // a static "ghost" outline button visible in the wave
        // shader for its entire ~1s lifetime. Two frames is
        // enough for SwiftUI's commit + the next CADisplayLink
        // tick, after which the screen state matches the
        // post-tap state.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 32_000_000)
            let snapshot = WindowSnapshot.capture()
            let burst = WaveShaderBurst(
                tapPoint: point,
                startDate: Date(),
                snapshot: snapshot
            )
            waveShader = burst
            try? await Task.sleep(
                nanoseconds: UInt64(Self.waveShaderLifetime * 1_000_000_000)
            )
            if waveShader?.id == burst.id {
                waveShader = nil
            }
        }
    }

    /// Show a transient pill anchored above a specific point
    /// (e.g., the tapped vibe button). Rendered at the app
    /// root so it isn't clipped, but visually appears to be
    /// "from" the button via its anchor position.
    func showAnchoredPill(
        _ text: String,
        at anchor: CGPoint,
        duration: TimeInterval = 2.0
    ) {
        let pill = AnchoredPill(text: text, anchor: anchor)
        anchoredPill = pill
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(duration * 1_000_000_000)
            )
            if anchoredPill?.id == pill.id {
                anchoredPill = nil
            }
        }
    }
}

/// Top-level overlay that draws every active burst above all
/// other content. Should be placed at the very top of the app's
/// view tree (above tabs, sheets, etc.) so particles aren't
/// clipped by any container.
struct VibesParticleLayer: View {
    @Environment(VibesEffectHost.self) private var host

    var body: some View {
        ZStack {
            ForEach(host.activeBursts) { burst in
                VibeBurstView(
                    center: burst.center,
                    startDate: burst.startDate
                )
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Small pill anchored above a specific button (typically the
/// vibe button the user just tapped while out of quota).
/// Rendered at the root so it can't be clipped by the scroll
/// view, but visually appears local — popping out above the
/// button it refers to.
///
/// Chrome matches the generation chip pill: blur background +
/// `cardFill` overlay + `cardBorder` stroke + soft shadow.
///
/// Position is clamped to the screen width so the pill doesn't
/// extend off either edge when the anchor button is near the
/// left or right of the viewport.
struct VibesBannerLayer: View {
    @Environment(VibesEffectHost.self) private var host
    @State private var pillWidth: CGFloat = 140

    private static let cornerRadius: CGFloat = 14
    private static let edgeMargin: CGFloat = 12

    var body: some View {
        GeometryReader { screen in
            ZStack(alignment: .topLeading) {
                if let pill = host.anchoredPill {
                    pillView(pill, screenWidth: screen.size.width)
                    // Window-level tap listener that dismisses
                    // the pill on any tap anywhere on screen
                    // WITHOUT consuming the tap — the tap also
                    // reaches whatever button/scrollview/tab
                    // was tapped. Only active while a pill is
                    // visible.
                    WindowTapListener {
                        host.anchoredPill = nil
                    }
                    .frame(width: 0, height: 0)
                }
            }
            .frame(width: screen.size.width, height: screen.size.height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: host.anchoredPill?.id)
        // CRUCIAL: ignore safe areas so the .position
        // coordinates are interpreted in window (screen) space
        // rather than safe-area-inset space — otherwise the
        // pill ends up offset by the status-bar height and
        // renders LOWER than the button instead of above it.
        .ignoresSafeArea()
        // Layer never consumes touches — even with the
        // WindowTapListener active, that listener is a
        // non-consuming UIKit gesture (cancelsTouchesInView =
        // false), so the user's tap still hits whatever they
        // intended.
        .allowsHitTesting(false)
    }

    private func pillView(
        _ pill: VibesEffectHost.AnchoredPill,
        screenWidth: CGFloat
    ) -> some View {
        let halfWidth = pillWidth / 2
        let clampedX = max(
            halfWidth + Self.edgeMargin,
            min(pill.anchor.x, screenWidth - halfWidth - Self.edgeMargin)
        )
        return Text(pill.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppPalette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: Self.cornerRadius,
                                style: .continuous
                            )
                        )
                    RoundedRectangle(
                        cornerRadius: Self.cornerRadius,
                        style: .continuous
                    )
                    .fill(AppPalette.cardFill)
                }
            }
            .overlay(
                RoundedRectangle(
                    cornerRadius: Self.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
            .fixedSize()
            // Measure ourselves and feed our width upstream so
            // the next render can clamp x. First render uses
            // the @State default (140pt); next render uses the
            // measured value.
            .background(
                GeometryReader { textGeo in
                    Color.clear
                        .onAppear { pillWidth = textGeo.size.width }
                        .onChange(of: textGeo.size.width) { _, w in
                            pillWidth = w
                        }
                }
            )
            .position(
                x: clampedX,
                // Float ~46pt above the button center so the
                // pill clearly hovers above the tapped icon.
                y: pill.anchor.y - 46
            )
            .transition(.vibePillSlideUp)
    }
}

/// Custom transition that slides the pill up by 12pt and fades
/// in. Replaces the previous `.scale + .position` combo: SwiftUI
/// can't anchor `.scale` on the view's own center when the
/// outer layer is positioned via `.position`, because the scale
/// uses the layout frame (which `.position` expands to the
/// whole parent). A pure offset transition sidesteps the issue.
private extension AnyTransition {
    static var vibePillSlideUp: AnyTransition {
        .modifier(
            active: VibePillSlideUpModifier(progress: 0),
            identity: VibePillSlideUpModifier(progress: 1)
        )
    }
}

private struct VibePillSlideUpModifier: ViewModifier {
    /// 0 = entry/exit (offset 12 below, opacity 0)
    /// 1 = identity (offset 0, opacity 1)
    let progress: Double

    func body(content: Content) -> some View {
        content
            .offset(y: (1 - progress) * 12)
            .opacity(progress)
    }
}

/// Attaches a UITapGestureRecognizer to the containing window
/// with `cancelsTouchesInView = false`, so taps fire our
/// callback AND propagate to the underlying button / scroll /
/// tab bar as normal. Used to dismiss the out-of-vibes pill on
/// any user interaction without blocking that interaction.
///
/// The recognizer is added when the view installs and removed
/// when it goes away (i.e., when the pill disappears) — so we
/// never have a stale tap-listener running.
struct WindowTapListener: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // Defer until the view is in a window — needed because
        // `view.window` is nil at `makeUIView` time.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleTap)
            )
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            window.addGestureRecognizer(tap)
            context.coordinator.tap = tap
            context.coordinator.window = window
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onTap: () -> Void
        weak var window: UIWindow?
        weak var tap: UITapGestureRecognizer?

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func handleTap() { onTap() }

        // Let every other gesture in the app recognize alongside
        // ours so we never steal touches from buttons or
        // scroll views.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        deinit {
            if let tap, let window {
                window.removeGestureRecognizer(tap)
            }
        }
    }
}

/// Renders one radial-burst-of-fire-glyphs particle effect at
/// a screen-global position. ~15 particles, each a stroked
/// flame glyph (from the AppIcon library) drawn into a Canvas
/// with an `uploadGlow`-colored shadow filter — same glow tone
/// used by the generation sparkles and the disco-ball sparkles.
///
/// Particles burst outward radially AND drift upward, fading
/// in the last 30% of their lifetime.
struct VibeBurstView: View {
    let center: CGPoint
    let startDate: Date

    /// 14 particles around the burst. Cluster avoidance now
    /// relies on wide birth-time stagger (0–0.30s) + variable
    /// per-particle lifetimes — adjacent angular particles are
    /// rarely alive at the same time, so close angular spacing
    /// doesn't read as a static cluster. This unlocks much
    /// denser bursts with particles emerging at varied radii.
    private static let particleCount = 14
    private static let duration: Double = VibesEffectHost.lifetime
    /// Diameter of the burst area in pt; particles can travel
    /// roughly maxRadius from center.
    private static let burstFrame: CGFloat = 400

    private let particles: [Particle]

    init(center: CGPoint, startDate: Date) {
        self.center = center
        self.startDate = startDate
        var rng = SystemRandomNumberGenerator()
        // Pass the index + total into each particle so it can
        // pick an evenly-distributed base angle. Fully random
        // angles let two particles land within a few degrees of
        // each other, producing the "random cluster" the user
        // saw. Even distribution + small angular jitter avoids
        // bunching while keeping the burst from looking robotic.
        self.particles = (0..<Self.particleCount).map { index in
            Particle(index: index, total: Self.particleCount, rng: &rng)
        }
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(startDate)
            Canvas { gc, _ in
                guard let flame = gc.resolveSymbol(id: "flame") else { return }
                let localCenter = CGPoint(
                    x: Self.burstFrame / 2,
                    y: Self.burstFrame / 2
                )
                for p in particles {
                    draw(particle: p, t: t, center: localCenter, flame: flame, in: &gc)
                }
            } symbols: {
                // Gradient-filled flame: light yellow hot core in
                // the flame body, transitioning into the cyan/blue
                // glow toward the edges.
                //
                // Center pushed DOWN to UnitPoint(0.5, 0.65) — the
                // flame glyph has its visual mass in the lower
                // ~60% (teardrop with the point at the top), so a
                // gradient centred at the bounding-box middle lands
                // on a thin part of the icon. Pushing the center
                // down places the yellow inside the bulky body of
                // the flame.
                //
                // Yellow window widened (0.0 → 0.45) so the core
                // reads as a clearly visible hot region, not a
                // pinpoint hidden by the surrounding blue and the
                // 6pt uploadGlow shadow filter.
                RadialGradient(
                    gradient: Gradient(stops: [
                        // Tiny saturated yellow hot core — pulled
                        // in even tighter (0 → 0.07) so it reads
                        // as a small bright pinpoint, then quickly
                        // transitions out through warm-white into
                        // the blue palette.
                        .init(color: Color(red: 1.00, green: 0.93, blue: 0.55), location: 0.0),
                        .init(color: Color(red: 1.00, green: 0.97, blue: 0.78), location: 0.07),
                        // Transition through a warm-neutral white
                        // rather than jumping straight to cyan —
                        // avoids the muddy gray spot you'd get
                        // crossing yellow→blue through the middle
                        // of the colour wheel.
                        .init(color: Color(red: 0.96, green: 0.98, blue: 0.95), location: 0.22),
                        .init(color: Color(red: 0.85, green: 0.95, blue: 1.00), location: 0.42),
                        .init(color: Color(red: 0.65, green: 0.88, blue: 1.00), location: 0.68),
                        .init(color: Color(red: 0.50, green: 0.82, blue: 1.00), location: 0.86),
                        .init(color: AppPalette.uploadGlow, location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.65),
                    startRadius: 0,
                    endRadius: 13
                )
                .frame(width: 22, height: 22)
                .mask(
                    AppIcon(
                        glyph: .flame,
                        size: 22,
                        color: .white,
                        filled: true
                    )
                )
                .tag("flame")
            }
            .drawingGroup()
            .frame(width: Self.burstFrame, height: Self.burstFrame)
            // Anchor the burst at the screen-global tap point.
            .position(center)
            .opacity(t < Self.duration ? 1 : 0)
        }
    }

    private func draw(
        particle p: Particle,
        t: Double,
        center: CGPoint,
        flame: GraphicsContext.ResolvedSymbol,
        in gc: inout GraphicsContext
    ) {
        guard t < Self.duration else { return }
        // Each particle waits its `birthTime` before appearing,
        // then lives for its own `lifeDuration`. Wide ranges on
        // both (birth 0–0.30s, life 0.45–0.85s) mean particles
        // emerge and fade out at very different times — at any
        // given moment, only 3–5 are visible across various
        // ages, breaking up any "synchronized ring" appearance.
        guard t >= p.birthTime else { return }
        let localT = t - p.birthTime
        guard localT < p.lifeDuration else { return }
        let progress = localT / p.lifeDuration

        // `pow(1-p, 1.4)` ease — particles stay visibly moving
        // through ~95% of their life. Stronger decel (e.g. 2.5)
        // freezes them while still 30% opaque, which reads as
        // floating debris rather than a burst.
        let radialEase = 1 - pow(1 - progress, 1.4)
        let radius = p.initialRadius
                   + (p.maxRadius - p.initialRadius) * radialEase

        // Upward drift, accelerating with time so the trailing
        // motion suggests rising fire/smoke.
        let upwardDrift = p.upwardSpeed * progress * progress * 80

        let x = center.x + cos(p.angle) * radius
        let y = center.y + sin(p.angle) * radius - upwardDrift

        // Start the opacity fade EARLIER (0.45 instead of 0.7) so
        // particles fade out while still moving noticeably,
        // rather than lingering at slow/almost-static positions
        // in the 0.7-1.0 progress window. By the time a particle
        // is moving slowly, it's already mostly invisible.
        let opacity: Double = progress < 0.45
            ? 1.0
            : max(0, 1.0 - (progress - 0.45) / 0.55)
        let scale = p.scale * (1.0 - 0.3 * progress)
        let rotation = Angle.radians(p.rotationSpeed * progress)

        var localGC = gc
        localGC.translateBy(x: x, y: y)
        localGC.rotate(by: rotation)
        localGC.scaleBy(x: scale, y: scale)
        localGC.opacity = opacity
        localGC.addFilter(.shadow(
            color: AppPalette.uploadGlow.opacity(0.85),
            radius: 6
        ))
        localGC.draw(flame, at: .zero)
    }

    private struct Particle {
        let angle: Double
        /// Per-particle birth offset (0–0.30s) — wider stagger
        /// so particles emerge throughout the burst, not all at
        /// once. Some appear very late.
        let birthTime: Double
        /// Per-particle life duration (0.45–0.85s) — particles
        /// have INDIVIDUAL lifespans, decoupled from the burst's
        /// total duration. Some die early, some late, breaking
        /// up any "ring" of synchronized particles.
        let lifeDuration: Double
        /// Distance from the burst centre at which this particle
        /// first appears (28–62pt, much wider range than before).
        /// Low end (~28pt) places some particles RIGHT at the
        /// edge of the morphing icon's max-scale footprint
        /// (~24pt) — gives the feel of particles spawning from
        /// the icon itself, not from a distant ring.
        let initialRadius: CGFloat
        let maxRadius: CGFloat
        let upwardSpeed: CGFloat
        let scale: CGFloat
        let rotationSpeed: Double

        init(
            index: Int,
            total: Int,
            rng: inout SystemRandomNumberGenerator
        ) {
            // Evenly-distributed angles with ±5.7° jitter.
            // Cluster avoidance comes from staggered birth + life,
            // not just angular gaps.
            let baseAngle = (Double(index) / Double(total)) * 2 * .pi
            let jitter = Double.random(in: -0.10...0.10, using: &rng)
            self.angle = baseAngle + jitter
            self.birthTime = Double.random(in: 0...0.30, using: &rng)
            self.lifeDuration = Double.random(in: 0.45...0.85, using: &rng)
            self.initialRadius = CGFloat.random(in: 28...62, using: &rng)
            self.maxRadius = CGFloat.random(in: 110...200, using: &rng)
            self.upwardSpeed = CGFloat.random(in: 0.4...1.2, using: &rng)
            self.scale = CGFloat.random(in: 0.60...1.05, using: &rng)
            self.rotationSpeed = Double.random(in: -2.0...2.0, using: &rng)
        }
    }
}

// MARK: - Morph layer

/// Renders the hero icon morph at root level, above the wave-shader
/// snapshot. Without this, the morph happens INSIDE the tapped
/// `VibeButton` — but the button is hidden behind the static
/// snapshot for the entire wave duration, so the user sees no
/// morph at all (just outline → suddenly filled at the end).
struct VibesMorphLayer: View {
    @Environment(VibesEffectHost.self) private var host

    var body: some View {
        ZStack {
            if let burst = host.morphBurst {
                MorphFlameView(startDate: burst.startDate)
                    .position(burst.center)
                    // Animate position changes so the morph slides
                    // smoothly when the tapped button reflows.
                    // Duration tightened to 0.22s so each re-anchor
                    // update from `VibeButton` (fired throughout
                    // the reflow window) settles well before the
                    // next one arrives — and the FINAL update at
                    // t=600ms has a clear 320ms to land exactly
                    // before the morph clears at t=1132ms.
                    .animation(
                        .easeInOut(duration: 0.22),
                        value: burst.center
                    )
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Time-driven hero morph. All visual state (scale, phase opacities)
/// is computed from elapsed time off `startDate` via a
/// `TimelineView(.animation)`. No SwiftUI `@State` to synchronize,
/// no `withAnimation` blocks to interfere with each other — just
/// pure functions of progress. This was rewritten from a
/// state-machine inside `VibeButton` because the snapshot-occlusion
/// problem couldn't be solved in-button and the state-driven approach
/// was fragile to SwiftUI's animation-context quirks.
private struct MorphFlameView: View {
    let startDate: Date

    /// Total morph duration. Shorter feels snappier — bloom +
    /// settle all happen within 620ms, then the icon sits at
    /// rest scale (1.0) until the morphBurst clears.
    private static let duration: TimeInterval = 0.62

    var body: some View {
        TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(startDate)
            let progress = max(0, min(1.0, elapsed / Self.duration))

            ZStack {
                outlineFlame.opacity(outlineOpacity(progress))
                gradientFlame.opacity(gradientOpacity(progress))
                filledFlame.opacity(filledOpacity(progress))
            }
            .scaleEffect(scaleFor(progress: progress), anchor: .center)
        }
        .frame(width: 60, height: 60)  // headroom for scale 3.2 × 18pt = 57.6pt
    }

    // MARK: - Animation curves

    /// Bloom (1.0 → 3.2) then damped-spring settle to 1.0 via
    /// `1.0 + 2.2 × e^(−3.2t) × cos(1.5πt)` — one clean
    /// undershoot at ~26% below target, fully settled by t=1.0.
    private func scaleFor(progress p: Double) -> CGFloat {
        if p < 0.33 {
            // Bloom: 1.0 → 3.2 over first 33%.
            let t = p / 0.33
            let eased = 1 - pow(1 - t, 2)
            return 1.0 + eased * 2.2
        }
        // Damped spring oscillation in [0.33, 1.0]:
        //   amplitude = 2.2 (initial delta from rest = 3.2 - 1.0)
        //   decay e^(−3.2t)  — controls how quickly oscillation dies
        //   cos(1.5πt)        — 3/4-cycle: peaks at t=0, zeros at
        //                        t=1/3 (passes through rest),
        //                        −1 at t=2/3 (undershoot), 0 at t=1
        let t = (p - 0.33) / 0.67
        let decay = exp(-3.2 * t)
        let oscillation = cos(1.5 * .pi * t)
        return CGFloat(1.0 + 2.2 * decay * oscillation)
    }

    /// Outline visible 0 → 0.20; quick fade 0.15 → 0.20.
    private func outlineOpacity(_ p: Double) -> Double {
        if p < 0.15 { return 1 }
        if p < 0.20 { return 1 - (p - 0.15) / 0.05 }
        return 0
    }

    /// Gradient visible 0.15 → 0.55, with quick fade-in + fade-out.
    private func gradientOpacity(_ p: Double) -> Double {
        if p < 0.15 { return 0 }
        if p < 0.20 { return (p - 0.15) / 0.05 }
        if p < 0.50 { return 1 }
        if p < 0.55 { return 1 - (p - 0.50) / 0.05 }
        return 0
    }

    /// Filled visible from 0.50 onward; quick fade-in 0.50 → 0.55.
    private func filledOpacity(_ p: Double) -> Double {
        if p < 0.50 { return 0 }
        if p < 0.55 { return (p - 0.50) / 0.05 }
        return 1
    }

    // MARK: - Icon forms (mirror VibeButton's flame views)

    private var outlineFlame: some View {
        AppIcon(
            glyph: .flame,
            size: 18,
            color: AppPalette.iconPrimary,
            filled: false,
            strokeWidth: 2.4
        )
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
            endRadius: 11
        )
        .frame(width: 18, height: 18)
        .mask(AppIcon(glyph: .flame, size: 18, color: .white, filled: true))
    }

    private var filledFlame: some View {
        AppIcon(
            glyph: .flame,
            size: 18,
            color: AppPalette.iconActive,
            filled: true
        )
    }
}

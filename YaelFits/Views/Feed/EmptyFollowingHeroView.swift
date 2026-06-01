import SwiftUI
import Lottie

/// Shared scroll-offset model for the empty-following hero. Holding
/// the offset on an `@Observable` lets the leaf avatar + button
/// subviews read it directly — when the value changes, only those
/// leaves re-evaluate, not the parent hero body. Previously the
/// hero took `scrollOffset` as a prop, which meant every scroll
/// tick re-evaluated the entire hero body and rebuilt all 5
/// AvatarBubble structs + closures. Now the hero body is stable
/// during scroll; only the leaves update their modifier chains.
@Observable
final class HeroScrollState {
    var offset: CGFloat = 0
}

/// Top half of the empty-friends feed: four organic avatar bubbles
/// surround a "Find your friends" capsule. Tapping the "+" badge on
/// an avatar follows that user (animate out + refill from a queued
/// candidate list). Tapping the avatar body opens that user's
/// profile sheet — both routed up via callbacks so the parent owns
/// the presentation surface.
struct EmptyFollowingHeroView: View {
    @Environment(OutfitStore.self) private var store

    let onFindFriendsTap: () -> Void
    let onProfileTap: (Profile) -> Void
    /// Scroll state shared with the leaf avatar + button subviews.
    /// The hero body itself does NOT read `scrollState.offset` —
    /// only `AvatarSlotView` and `FriendsButtonView` do — so the
    /// hero body never re-evaluates on scroll. Each scroll-tick
    /// invalidation is contained to the leaves.
    @Bindable var scrollState: HeroScrollState
    /// When the parent supplies a non-empty list, the floating
    /// avatars are replaced with these profiles (used after the
    /// user shares their contacts and we match them to existing
    /// Yafa users). When `nil`, the hero falls back to its own
    /// `getSuggestedProfiles` fetch.
    var seedProfiles: [Profile]? = nil

    /// The 5 currently-rendered bubble slots. Nil entries mid-animation
    /// while a follow plays its exit before the next candidate slides in.
    @State private var slots: [Profile?] = Array(repeating: nil, count: 5)
    /// Tail of candidates queued to refill slots as the user follows.
    @State private var candidates: [Profile] = []
    @State private var hasLoaded = false
    /// Per-element entry progress (5 avatars then the button). Each
    /// fires its own spring ~70ms after the previous one so the
    /// cluster pops in like a chain reaction rather than a single
    /// flash. Index 5 is the button.
    @State private var entryProgresses: [CGFloat] = Array(repeating: 0, count: 6)
    /// Disco-ball pop-in state. `scale` overshoots 1.0 via a
    /// spring; `opacity` fades from 0→1.
    @State private var discoBallScale: CGFloat = 0
    @State private var discoBallOpacity: Double = 0
    /// Lottie playback speed for the disco ball. Held constant at
    /// 1.0 — the spin-up ramp was contributing main-thread overhead
    /// during the avatar entry window (per-frame Task writes +
    /// disco-ball Lottie running at 3× speed competed with the
    /// staggered avatar springs and dropped frames).
    @State private var discoBallSpeed: Double = 1.0
    /// Bumped at the instant the disco ball pops in. Applied as
    /// `.id()` on the sparkle Lottie so SwiftUI recreates it,
    /// which restarts the Lottie from frame 0 — and since all
    /// three sparkles fire in the first ~0.2s of the loop, they
    /// pop in alongside the disco ball.
    @State private var sparkleResetId: Int = 0
    /// Guard so the pop-in only fires once per view instance,
    /// even if `.task` re-fires from a LazyVStack reload.
    @State private var hasStartedDiscoEntry = false
    /// Animatable driver for the per-bubble `FloatEffect`. Set to a
    /// large value inside `withAnimation(.linear.repeatForever)` so
    /// SwiftUI interpolates it continuously between frames — each
    /// `FloatEffect.effectValue` reads the interpolated value via
    /// `animatableData` without re-evaluating any view body.
    @State private var floatTime: Double = 0
    /// Guard so the float animation only ever starts once per view
    /// instance. `EmptyFollowingHeroView` lives in a LazyVStack;
    /// without this guard, scrolling the hero off-screen and back
    /// re-fires `.task`, stacking another `repeatForever` animation
    /// on top of the existing one — which is why the drift sped up
    /// on every scroll cycle.
    @State private var hasStartedFloat = false

    // Per-avatar / per-button visibility math has moved into the
    // leaf views (AvatarSlotView, FriendsButtonView) so reading
    // `scrollState.offset` only invalidates those leaves, not the
    // hero body. The `.allowsHitTesting(scrollOffset < 400)` gate
    // and the `.offset(y: scrollOffset)` pin also moved up to the
    // parent (`PinnedHero` in EmptyFollowingView) — both read the
    // scroll state, but neither passes through the hero body.

    var body: some View {
        // GeometryReader so we can lay out each bubble at its slot
        // via `.position` instead of `.offset`. `.scaleEffect` uses
        // the view's **layout** bounds centre as its anchor — and in
        // a ZStack all children share the parent's origin as their
        // layout centre, so plain `.offset` made every bubble appear
        // to scale outward from the button. `.position` actually
        // moves the layout centre to the slot point, so scaling
        // anchors on each bubble's own circle centre.
        GeometryReader { geo in
            let offsets = slotOffsets(for: geo.size.width)
            ZStack {
                ForEach(0..<offsets.count, id: \.self) { index in
                    AvatarSlotView(
                        scrollState: scrollState,
                        index: index,
                        slotX: offsets[index].width,
                        slotY: offsets[index].height,
                        diameter: slotDiameters[index],
                        entryProgress: entryProgresses[index],
                        floatTime: floatTime,
                        driftAmplitude: driftAmplitude,
                        containerSize: geo.size,
                        profile: slots[index],
                        onProfileTap: {
                            if let profile = slots[index] {
                                onProfileTap(profile)
                            }
                        },
                        onFollow: {
                            if let profile = slots[index] {
                                handleFollow(profile, at: index)
                            }
                        }
                    )
                }

                FriendsButtonView(
                    scrollState: scrollState,
                    entryProgress: entryProgresses.last ?? 0,
                    discoBallScale: discoBallScale,
                    discoBallOpacity: discoBallOpacity,
                    discoBallSpeed: discoBallSpeed,
                    sparkleResetId: sparkleResetId,
                    containerSize: geo.size,
                    onTap: onFindFriendsTap
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .task {
            // Order matters: button entry fires immediately so the
            // page isn't blank during the network fetch. THEN we
            // await the suggestion load. THEN we animate the avatars
            // in. The float animation must start LAST — kicking it
            // off before the bubbles are rendered caused
            // `withAnimation.repeatForever` to get invalidated when
            // the view tree changed (bubbles appearing). That was
            // the actual regression from the "appear faster" split.
            animateButtonEntry()
            animateDiscoBallEntry()

            if !hasLoaded {
                hasLoaded = true
                await reloadSuggestions()
            }
            animateAvatarsEntry()
            startFloatAnimation()
        }
        .onAppear {
            // Replays on subsequent re-appears of the same view
            // instance. Skipped on the very first appear (where
            // hasLoaded is still false) so we don't burn the
            // animations before there are avatars to render —
            // `.task` handles that case.
            if hasLoaded {
                animateButtonEntry()
                animateAvatarsEntry()
            }
        }
        .onChange(of: store.currentView) { _, newView in
            // Replay the full hero entry every time the user
            // navigates back to the friends tab: avatar pop-in,
            // button pop-in, AND the disco-ball pop-in + speed
            // ramp (reset its guard so it can fire fresh).
            // `.onAppear` alone isn't reliable here — the hero
            // view often stays mounted across tab switches, so
            // the appear event doesn't re-fire. Community cards
            // underneath are left alone; only the hero re-animates.
            guard newView == .feed, hasLoaded else { return }
            animateButtonEntry()
            animateAvatarsEntry()
            hasStartedDiscoEntry = false
            animateDiscoBallEntry()
        }
        .onChange(of: seedProfiles) { _, newSeeds in
            // Parent dropped a contact-match result in. Merge with
            // existing slot occupants so a small match pool (e.g.
            // 1-2 matched contacts) doesn't blank the other slots
            // — we always want all five bubbles populated.
            guard let newSeeds, !newSeeds.isEmpty else { return }
            let existing = slots.compactMap { $0 } + candidates
            var merged: [Profile] = []
            var seen = Set<UUID>()
            for profile in newSeeds + existing {
                if seen.insert(profile.id).inserted {
                    merged.append(profile)
                }
            }
            let firstFive = Array(merged.prefix(5))
            slots = firstFive.map { Optional($0) }
                + Array(repeating: nil, count: max(0, 5 - firstFive.count))
            candidates = Array(merged.dropFirst(5))
            animateAvatarsEntry()
        }
    }

    /// Continuous floating animation. SwiftUI interpolates
    /// `floatTime` between every frame and `FloatEffect.animatableData`
    /// reads the interpolated value — no view body re-render per
    /// frame, just GPU transform updates. Started LAST in `.task`
    /// (after suggestions load + avatars animate in) so the in-flight
    /// `withAnimation.repeatForever` isn't invalidated by view-tree
    /// changes when bubbles appear.
    ///
    /// Guarded so it only ever fires once per view instance — without
    /// the guard, scrolling the hero out of the LazyVStack's visible
    /// range and back re-fires `.task`, which stacked another
    /// `repeatForever` animation on top of the existing one and made
    /// the drift visibly accelerate on every scroll cycle.
    private func startFloatAnimation() {
        guard !hasStartedFloat else { return }
        hasStartedFloat = true
        Task { @MainActor in
            floatTime = 0
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(.linear(duration: 200).repeatForever(autoreverses: false)) {
                floatTime = 200
            }
        }
    }

    /// Spins the globe glyph in the "Find your people" button up to
    /// peak velocity with an `.easeIn` curve (velocity is zero at
    /// t=0 and maximum at t=duration for ease-in), then swaps the
    /// glyph for the disco-ball Lottie at exactly that peak moment.
    /// The Lottie's own continuous rotation picks up where the
    /// globe left off, so the cut reads as one continuous spin that
    /// changes identity mid-rotation.
    ///
    /// A brief pre-spin pause lets the button's pop-in spring
    /// settle before the rotation begins, so the two animations
    /// don't fight for attention.
    /// Disco-ball entry: pops in via a bouncy scale+fade spring
    /// while spinning at 3× speed. A short-lived Task ramps
    /// `discoBallSpeed` from 3.0 → 1.0 over one second using an
    /// ease-out curve, then stops — so once the ramp completes
    /// the button stops re-rendering entirely. Three sparkles
    /// pop in alongside the ball: the sparkle Lottie is reset by
    /// bumping `sparkleResetId`, which forces SwiftUI to recreate
    /// the overlay and restart playback from frame 0 (where all
    /// three sparkles fire in a tight 0.2s burst).
    private func animateDiscoBallEntry() {
        guard !hasStartedDiscoEntry else { return }
        hasStartedDiscoEntry = true

        Task { @MainActor in
            discoBallScale = 0
            discoBallOpacity = 0

            try? await Task.sleep(nanoseconds: 300_000_000)

            // Restart the sparkle Lottie and spring the scale/
            // opacity in on the same frame so they read as one
            // unified pop.
            sparkleResetId &+= 1
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                discoBallScale = 1.0
                discoBallOpacity = 1.0
            }
        }
    }

    /// Fires the button's pop-in immediately, decoupled from the
    /// avatars so the page has something on screen during the
    /// suggestion-fetch network round-trip.
    private func animateButtonEntry() {
        let buttonIndex = entryProgresses.count - 1
        entryProgresses[buttonIndex] = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                entryProgresses[buttonIndex] = 1
            }
        }
    }

    /// Staggered pop-in for the five avatars. Called once the
    /// suggestion data has landed so the springs animate visible
    /// bubbles rather than empty slots.
    ///
    /// Animations are issued in a single synchronous loop using
    /// `.delay()` on each spring's animation curve, instead of
    /// awaiting between iterations. Two reasons:
    ///   1. Each `withAnimation { entryProgresses[i] = 1 }` triggers
    ///      a body invalidation. Issuing them in the same run-loop
    ///      tick lets SwiftUI batch all 5 into a single body
    ///      re-evaluation rather than 5 sequential re-evaluations.
    ///   2. The visual stagger is preserved by `.delay(i * 0.08)`,
    ///      which is interpreted by SwiftUI's animation system —
    ///      the springs still kick off 80ms apart.
    private func animateAvatarsEntry() {
        for i in 0..<5 { entryProgresses[i] = 0 }
        Task { @MainActor in
            // One run-loop tick so the 0-reset above commits before
            // we animate to 1 (otherwise the spring sees no delta
            // and the bubbles snap in flat).
            try? await Task.sleep(nanoseconds: 16_000_000)
            for i in 0..<5 {
                withAnimation(
                    .spring(response: 0.5, dampingFraction: 0.7)
                        .delay(Double(i) * 0.08)
                ) {
                    entryProgresses[i] = 1
                }
            }
        }
    }

    // MARK: - Layout

    /// Five organic bubble positions, accounting for the wider
    /// "Find your people" button (~200pt × 48pt now that the disco
    /// ball is in it). The bottom three sit further out from the
    /// button than before so neither the avatar circles (radius 50)
    /// nor their `+` badges (centre offset (40, −40), radius 14)
    /// overlap the button's footprint:
    ///
    ///   - Slot 2 pushed from (120, 75) → (135, 80) — avatar gap to
    ///     button corner is now 16.8pt instead of 5pt.
    ///   - Slot 3 pushed from (−100, 80) → (−115, 85) — same idea
    ///     for the left side, badge clearance is 17pt now instead
    ///     of 2pt.
    ///
    /// Inter-avatar gaps stay ≥28pt edge-to-edge so the bubbles
    /// don't collide with each other either.
    ///
    /// Returns offsets responsive to the container width: on
    /// narrower screens (iPhone SE / mini) the horizontal
    /// offsets clamp inward so the 100pt-diameter avatars never
    /// clip off-screen. Reference design is 390pt wide (iPhone
    /// 14/15); wider screens reuse the reference layout.
    private func slotOffsets(for width: CGFloat) -> [CGSize] {
        let baseOffsets: [CGSize] = [
            CGSize(width:  -70, height: -115),
            CGSize(width:   80, height: -110),
            CGSize(width:  135, height:   80),
            CGSize(width: -115, height:   85),
            CGSize(width:    5, height:  130),
        ]
        // Clamp x so each 100pt avatar stays inside the
        // container with a 16pt edge margin. y is independent
        // of width so leave alone.
        let avatarRadius: CGFloat = 50
        let edgeMargin: CGFloat = 16
        let maxX = max(0, width / 2 - avatarRadius - edgeMargin)
        return baseOffsets.map { offset in
            CGSize(
                width: min(max(offset.width, -maxX), maxX),
                height: offset.height
            )
        }
    }

    /// Per-axis amplitude (pt) of the idle floating drift. Picked so
    /// the worst-case combined approach between two neighbouring
    /// bubbles (≈ `2 × √2 × driftAmplitude`) plus a 64pt badge
    /// buffer still fits in the smallest clearance pair (Slot 4's
    /// badge → Slot 2 = 76.5pt at the new positions).
    private let driftAmplitude: CGFloat = 3.0

    /// Diameter per slot. Index aligns with `slotOffsets`.
    private var slotDiameters: [CGFloat] {
        Array(repeating: 100, count: 5)
    }

    // MARK: - Subviews

    // `findYourFriendsButton` and `avatarSlot(at:)` moved into
    // `FriendsButtonView` and `AvatarSlotView` below — both leaf
    // views own their own scroll-offset reads so the hero body
    // doesn't observe `scrollState.offset`.

    // MARK: - Data

    private func reloadSuggestions() async {
        guard let userId = store.userId else { return }
        do {
            let suggestions = try await SocialService.getSuggestedProfiles(
                excluding: store.followingIds,
                currentUserId: userId,
                limit: 20
            )
            let shuffled = suggestions.shuffled()
            let displayed = Array(shuffled.prefix(slots.count))

            // Decode the 5 displayed avatars BEFORE setting slot
            // @state, so when the bubbles mount their
            // `CachedRemoteImage`s hit the sync cache path on
            // first render — no placeholder→image swap, no body
            // re-evaluation per bubble mid-spring.
            //
            // Capped at 700ms so a single slow image can't block
            // the entire hero — if a URL is still in flight past
            // the cap, we proceed; that bubble falls back to the
            // placeholder→image swap (one bubble, not all five).
            await prewarmAvatarImages(for: displayed, timeoutNanos: 700_000_000)

            await MainActor.run {
                for i in 0..<slots.count where i < shuffled.count {
                    slots[i] = shuffled[i]
                }
                candidates = Array(shuffled.dropFirst(slots.count))
            }
        } catch {
            // Silent failure — the empty hero still renders (just
            // button + drift). User can still tap into discovery.
        }
    }

    /// Pre-warm `RemoteImageCache` for the displayed avatars and
    /// `await` the decodes (with a hard time cap) before returning.
    /// Matches the `maxPixelSize` `AvatarView` uses
    /// (`max(size, 80) * scale`) so the cache hit doesn't trigger a
    /// re-decode at a different size. Bubble diameter is 100pt; on
    /// @3× devices that's 300px.
    ///
    /// `timeoutNanos` bounds the total wait so one slow URL can't
    /// delay the entire hero render — decodes that haven't finished
    /// when the timeout fires continue running in the background and
    /// will be picked up by the bubble's own `CachedRemoteImage`
    /// `.task` on the next render.
    private func prewarmAvatarImages(
        for profiles: [Profile],
        timeoutNanos: UInt64
    ) async {
        let scale = UIScreen.main.scale
        let maxPixelSize = max(100, 80) * scale
        let urls = profiles.compactMap { profile -> URL? in
            guard let urlString = profile.avatarUrl else { return nil }
            return URL(string: urlString)
        }
        guard !urls.isEmpty else { return }

        // Race "all decodes done" against "timeout fired". Whichever
        // wins returns; the loser is cancelled. Underlying
        // URLSession requests keep running on cancellation, so a
        // slow image still lands in the cache for the bubble's own
        // `CachedRemoteImage.task` on the next render.
        let decodeAll = Task(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask(priority: .userInitiated) {
                        _ = await RemoteImageCache.shared.load(
                            url,
                            maxPixelSize: maxPixelSize
                        )
                    }
                }
                for await _ in group {}
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await decodeAll.value }
            group.addTask { await timeout.value }
            await group.next()
            group.cancelAll()
        }
        decodeAll.cancel()
        timeout.cancel()
    }

    private func handleFollow(_ profile: Profile, at index: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.toggleFollow(profile.id)

        // Shrink the current bubble in place via the same
        // `scaleEffect` channel the entry animation uses — which is
        // anchored on the avatar's own centre. The slot stays
        // occupied during the shrink so the view tree doesn't change
        // and the bubble visually collapses at its own location.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            entryProgresses[index] = 0
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !candidates.isEmpty else { return }
            // Swap the profile silently while the bubble is at
            // `scaleEffect ≈ 0` (invisible). The new profile's `id`
            // changes, but with no `.transition` modifier the swap
            // is instantaneous — the user only sees the next
            // animation, the grow-up from this same slot.
            slots[index] = candidates.removeFirst()
            // Grow the new bubble back to full size, again via
            // `entryProgresses` for a centre-anchored scale.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                entryProgresses[index] = 1
            }
        }
    }
}

// MARK: - AvatarSlotView

/// One avatar slot in the floating hero. Reads `scrollState.offset`
/// directly to compute its own scale + opacity fade, so a scroll
/// tick only invalidates this leaf (not the surrounding hero body).
///
/// Layout responsibility:
///   - Positions itself at the slot offset within the container,
///   - Applies the entry-spring scale/opacity via `entryProgress`,
///   - Multiplies that by `avatarVisibility()` for scroll fade,
///   - Applies the `FloatEffect` drift modifier last so the
///     position is already resolved.
private struct AvatarSlotView: View {
    @Bindable var scrollState: HeroScrollState
    let index: Int
    let slotX: CGFloat
    let slotY: CGFloat
    let diameter: CGFloat
    let entryProgress: CGFloat
    let floatTime: Double
    let driftAmplitude: CGFloat
    let containerSize: CGSize
    let profile: Profile?
    let onProfileTap: () -> Void
    let onFollow: () -> Void

    var body: some View {
        let scrollVis = avatarVisibility()
        avatarBody
            .frame(width: diameter, height: diameter)
            .scaleEffect(entryProgress * scrollVis, anchor: .center)
            .opacity(entryProgress * scrollVis)
            .position(
                x: containerSize.width / 2 + slotX,
                y: containerSize.height / 2 + slotY
            )
            .modifier(FloatEffect(
                time: floatTime,
                phase: Double(index) * 1.7,
                amplitude: driftAmplitude
            ))
    }

    @ViewBuilder
    private var avatarBody: some View {
        if let profile {
            AvatarBubble(
                profile: profile,
                diameter: diameter,
                onAvatarTap: onProfileTap,
                onFollowTap: onFollow
            )
            .id(profile.id)
        }
    }

    /// Same fade math as the previous hero-body version. Reads
    /// `scrollState.offset` here so only this leaf re-evaluates
    /// when the offset changes — the hero body is unaware.
    private func avatarVisibility() -> CGFloat {
        let cardY = 190 - scrollState.offset
        let distance = cardY - slotY
        let triggerDistance: CGFloat = 50
        let fadeRange: CGFloat = 60
        if distance >= triggerDistance { return 1 }
        if distance <= triggerDistance - fadeRange { return 0 }
        return (distance - (triggerDistance - fadeRange)) / fadeRange
    }
}

// MARK: - FriendsButtonView

/// "Find your people" pill button with disco-ball Lottie. Reads
/// `scrollState.offset` directly to drive its scroll-fade scale +
/// opacity AND to pause the two Lotties (`animationSpeed = 0`)
/// once the button has scrolled fully behind the community
/// section. By owning these reads internally, scroll ticks
/// invalidate this leaf only.
private struct FriendsButtonView: View {
    @Bindable var scrollState: HeroScrollState
    let entryProgress: CGFloat
    let discoBallScale: CGFloat
    let discoBallOpacity: Double
    let discoBallSpeed: Double
    let sparkleResetId: Int
    let containerSize: CGSize
    let onTap: () -> Void

    var body: some View {
        let buttonVis = buttonScrollVisibility()
        let offScreen = buttonVis == 0

        Button(action: onTap) {
            HStack(spacing: 2) {
                Text("Find your people")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)

                LottieView(animation: .named("DiscoBall"))
                    .looping()
                    .animationSpeed(offScreen ? 0 : discoBallSpeed)
                    .overlay(
                        LottieView(animation: .named("disco-ball-sparkles"))
                            .looping()
                            .animationSpeed(offScreen ? 0 : 1.0)
                            .frame(width: 150, height: 150)
                            .shadow(color: AppPalette.uploadGlow.opacity(0.8), radius: 6)
                            .allowsHitTesting(false)
                            .id(sparkleResetId)
                    )
                    .frame(width: 32, height: 32)
                    .scaleEffect(discoBallScale)
                    .opacity(discoBallOpacity)
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 48)
            .appCapsule(shadowRadius: 8, shadowY: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(entryProgress * buttonVis)
        .opacity(entryProgress * buttonVis)
        .position(
            x: containerSize.width / 2,
            y: containerSize.height / 2
        )
    }

    /// Quicker fade than the avatars — matches the snappy fade of
    /// the "Find your people" search pill on the populated friends
    /// feed.
    private func buttonScrollVisibility() -> CGFloat {
        let cardY = 190 - scrollState.offset
        let distance = cardY  // button at y = 0
        let triggerDistance: CGFloat = 60
        let fadeRange: CGFloat = 30
        if distance >= triggerDistance { return 1 }
        if distance <= triggerDistance - fadeRange { return 0 }
        return (distance - (triggerDistance - fadeRange)) / fadeRange
    }
}

// MARK: - AvatarBubble

/// A single bubble: large circular avatar with a small "+" follow
/// badge in the top-right corner. Tap targets are split — the badge
/// triggers follow, the avatar itself opens the profile.
private struct AvatarBubble: View {
    let profile: Profile
    var diameter: CGFloat = 110
    let onAvatarTap: () -> Void
    let onFollowTap: () -> Void

    var body: some View {
        // ZStack frame == avatar frame so `.scaleEffect` (default
        // anchor `.center`) anchors on the avatar's centre. The
        // curved pill, badge, and avatar all share this centre.
        ZStack {
            Button(action: onAvatarTap) {
                AvatarView(
                    url: profile.avatarUrl,
                    initial: profile.initial,
                    size: diameter,
                    shadowRadius: 12,
                    shadowY: 6
                )
            }
            .buttonStyle(.plain)

            // Curved username pill hugging the avatar's bottom arc.
            // Drawn before the badge so the badge ends up on top of
            // any incidental shadow overlap in the upper-right.
            // `.drawingGroup()` rasterizes the Canvas-based pill to
            // a Metal texture once per profile, so the pill (which
            // contains the glyph arc work) doesn't redraw on every
            // float-modifier tick. Safe to use here because Canvas
            // draws synchronously and contains no async-loading
            // content — unlike `AvatarBubble` (which has
            // `CachedRemoteImage` and broke under drawingGroup).
            CurvedUsernamePill(
                username: profile.handle,
                avatarRadius: diameter / 2
            )
            .drawingGroup()
            .onTapGesture { onAvatarTap() }
            .allowsHitTesting(true)

            Button(action: onFollowTap) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppPalette.iconActive)
                    .frame(width: 28, height: 28)
                    .appCircle(shadowRadius: 4, shadowY: 2)
            }
            .buttonStyle(.plain)
            // Pull the badge inward so it overlaps the avatar's
            // upper-right edge — Instagram/Snap-style "stuck on"
            // look. Centre-to-centre distance is `45 √2 ≈ 63.6`,
            // sum-of-radii is `55 + 14 = 69`, so the two circles
            // overlap by ~5pt rather than floating apart.
            .offset(x: diameter / 2 - 10, y: -diameter / 2 + 10)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Username label that arcs along the bottom edge of the avatar
/// circle. Self-sizes its angular footprint to the text length, with
/// rounded end caps so it reads as a pill rather than a clipped
/// arc. Glyphs are rotated per-character so the text follows the
/// curve.
private struct CurvedUsernamePill: View {
    let username: String
    let avatarRadius: CGFloat

    /// Gap between the avatar's outer edge and the pill's inner edge.
    private static let avatarGap: CGFloat = 4
    /// Radial thickness of the pill (the "height" of the capsule).
    private static let pillThickness: CGFloat = 22
    private static let fontSize: CGFloat = 10
    /// Pt of slack on each end of the text so glyphs don't kiss the
    /// rounded caps.
    private static let endPadding: CGFloat = 6
    /// Negative tracking applied per glyph so the curved text reads
    /// tight rather than airy. Real path-text effects (After Effects
    /// etc.) typically dial in similar small negative tracking when
    /// the curve radius is small relative to the glyph height.
    private static let perGlyphTighten: CGFloat = 0.85

    /// UIKit font used both for measuring per-glyph advances and as
    /// the actual rendering font. Keeping these in sync is essential
    /// — a measured width that differs from the rendered glyph's
    /// advance would show up as drift along the arc.
    private static let measuringFont: UIFont =
        .systemFont(ofSize: fontSize, weight: .medium)

    // Cached per-instance values. Computing `glyphAdvances` runs
    // `NSString.size(withAttributes:)` per character — at ~5
    // avatars × ~10 chars each that's ~50 string-measurement calls
    // we don't want to repeat on every TimelineView tick (which
    // caused the floating animation to read as jittery). Caching
    // these in `init` collapses the cost to once per bubble.
    private let characters: [Character]
    private let displayText: String
    private let glyphAdvances: [CGFloat]
    private let measuredArcLength: CGFloat

    init(username: String, avatarRadius: CGFloat) {
        self.username = username
        self.avatarRadius = avatarRadius

        let text = "@" + username
        let chars = Array(text)
        self.displayText = text
        self.characters = chars

        let attrs: [NSAttributedString.Key: Any] = [.font: Self.measuringFont]
        let advances = chars.map { char -> CGFloat in
            let width = (String(char) as NSString).size(withAttributes: attrs).width
            return width * Self.perGlyphTighten
        }
        self.glyphAdvances = advances
        self.measuredArcLength = advances.reduce(0, +) + Self.endPadding * 2
    }

    /// Inner / outer radii of the pill ring.
    private var pillInnerRadius: CGFloat { avatarRadius + Self.avatarGap }
    private var pillOuterRadius: CGFloat { pillInnerRadius + Self.pillThickness }
    /// Radius along which the text baseline sits (midline of the pill).
    private var textRadius: CGFloat { (pillInnerRadius + pillOuterRadius) / 2 }

    /// Angular footprint of the pill measured at `textRadius`. Driven
    /// by `measuredArcLength` (sum of real glyph advances) rather
    /// than a per-character approximation, so wide and narrow letters
    /// contribute their actual share of the arc.
    private var totalAngle: CGFloat {
        // Clamp so a pathological username doesn't try to wrap more
        // than a half-circle (which would visually collide with the
        // avatar's top).
        min(.pi, measuredArcLength / textRadius)
    }

    /// Trim parameters for the Circle().trim().stroke() background.
    /// SwiftUI's Circle path starts at 3 o'clock and proceeds
    /// counterclockwise (math-CCW = screen-CW), so trim parameter
    /// 0.25 lands at 6 o'clock — directly below the avatar centre.
    /// (0.5 would be 9 o'clock, which is the bug that put the pill
    /// on the side instead of the bottom in the first pass.)
    private var trimAmount: CGFloat { totalAngle / (2 * .pi) }
    private var trimFrom: CGFloat { 0.25 - trimAmount / 2 }
    private var trimTo: CGFloat { 0.25 + trimAmount / 2 }

    /// Side length of the host view. Must contain the pill's full
    /// outer circle plus a few pt of slack for the drop shadow.
    private var canvasSize: CGFloat { (pillOuterRadius + 4) * 2 }

    var body: some View {
        // Single Canvas — draws the curved pill background + every
        // glyph in one Core Graphics pass. Replaces what used to be
        // ~15 individual `Text` views with `.position` + `.rotationEffect`
        // per pill (and ~75 total across all 5 bubbles), which was
        // the main re-evaluation cost killing the float animation.
        // The Canvas's draw closure has no `@State` dependencies, so
        // SwiftUI caches its output — the `FloatModifier` can offset
        // the cached render every frame without redrawing.
        Canvas { context, _ in
            let center = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
            drawPillBackground(context: &context, center: center)
            drawGlyphs(context: &context, center: center)
        }
        .frame(width: canvasSize, height: canvasSize)
    }

    private func drawPillBackground(context: inout GraphicsContext, center: CGPoint) {
        // SwiftUI's `Path.addArc` takes math angles (0 = +x = right,
        // CCW math = CW screen because y is flipped). To land the
        // pill at the bottom (6 o'clock), the arc runs from
        // ~lower-right (math π/4-ish) through bottom (π/2) to
        // ~lower-left (3π/4-ish).
        let startAngle = Double(trimFrom) * 2 * .pi
        let endAngle = Double(trimTo) * 2 * .pi

        var path = Path()
        path.addArc(
            center: center,
            radius: textRadius,
            startAngle: .radians(startAngle),
            endAngle: .radians(endAngle),
            clockwise: false
        )

        context.stroke(
            path,
            with: .color(AppPalette.cardBorder),
            style: StrokeStyle(
                lineWidth: Self.pillThickness + 1.5,
                lineCap: .round
            )
        )
        context.stroke(
            path,
            with: .color(.white),
            style: StrokeStyle(
                lineWidth: Self.pillThickness,
                lineCap: .round
            )
        )
    }

    private func drawGlyphs(context: inout GraphicsContext, center: CGPoint) {
        let totalAdvance = glyphAdvances.reduce(0, +)
        guard totalAdvance > 0 else { return }
        // Cumulative advance up to each glyph so we can compute the
        // glyph's centre-of-advance position along the arc in a
        // single pass.
        var runningAdvance: CGFloat = 0
        for (index, char) in characters.enumerated() {
            let advance = glyphAdvances[index]
            let centerAdvance = runningAdvance + advance / 2
            runningAdvance += advance

            let progress = centerAdvance / totalAdvance
            let t = trimTo - progress * (trimTo - trimFrom)
            let angle = Double(t) * 2 * .pi
            let rotation = angle - .pi / 2

            let position = CGPoint(
                x: center.x + textRadius * CGFloat(cos(angle)),
                y: center.y + textRadius * CGFloat(sin(angle))
            )

            let resolved = context.resolve(
                Text(String(char))
                    .font(.system(size: Self.fontSize, weight: .medium))
                    .foregroundStyle(AppPalette.textPrimary)
            )

            context.drawLayer { layer in
                layer.translateBy(x: position.x, y: position.y)
                layer.rotate(by: .radians(rotation))
                layer.draw(resolved, at: .zero, anchor: .center)
            }
        }
    }

}

/// Compact pill that shows `@username` under each avatar bubble.
/// Sizes itself to the text content (no fixed width); falls back to a
/// gentle marquee scroll only when the handle exceeds the soft cap so
/// the bubble cluster doesn't end up dominated by one long username.
private struct UsernameMarqueePill: View {
    let username: String

    /// Soft cap — pills wider than this clip + marquee instead of
    /// stretching past the avatar's footprint.
    private let maxInnerWidth: CGFloat = 96
    private let horizontalPadding: CGFloat = 10

    @State private var textWidth: CGFloat = 0
    @State private var animOffset: CGFloat = 0

    var body: some View {
        let needsScroll = textWidth > maxInnerWidth
        let visibleWidth = min(textWidth, maxInnerWidth)

        return Text("@\(username)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppPalette.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in textWidth = new }
                }
            }
            .offset(x: animOffset)
            .frame(width: visibleWidth, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
            .padding(.horizontal, horizontalPadding)
            .frame(height: 24)
            .appCapsule(shadowRadius: 4, shadowY: 2)
            .onChange(of: needsScroll) { _, scroll in
                startOrStopMarquee(scroll: scroll)
            }
            .onAppear { startOrStopMarquee(scroll: needsScroll) }
    }

    private func startOrStopMarquee(scroll: Bool) {
        guard scroll else {
            animOffset = 0
            return
        }
        let overflow = textWidth - maxInnerWidth
        guard overflow > 0 else { return }
        animOffset = 0
        let duration = max(2.5, Double(textWidth) / 28)
        withAnimation(
            .linear(duration: duration).repeatForever(autoreverses: true)
        ) {
            animOffset = -overflow
        }
    }
}

// MARK: - FloatEffect

/// Render-server-side bubble drift. Reads the parent's `floatTime`
/// state via `animatableData` — SwiftUI interpolates that Double
/// between every frame of the `withAnimation.linear.repeatForever`,
/// and `effectValue` returns a translation transform for each
/// interpolated value. The wrapped view never re-renders; only the
/// `ProjectionTransform` updates. This is the only animation pattern
/// in this view that's smooth on device — TimelineView-based
/// alternatives all forced view-tree re-evaluation per tick.
private struct FloatEffect: GeometryEffect {
    var time: Double
    let phase: Double
    let amplitude: CGFloat

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Original frequencies (0.55 / 0.47) that worked before the
        // ordering regression. Cycle is ~11–13 seconds.
        let driftX = sin(time * 0.55 + phase) * Double(amplitude)
        let driftY = sin(time * 0.47 + phase * 1.3) * Double(amplitude)
        return ProjectionTransform(
            CGAffineTransform(translationX: CGFloat(driftX), y: CGFloat(driftY))
        )
    }
}


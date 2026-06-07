import SwiftUI

/// Other-user profile screen. Same layout as the profile-as-home
/// (avatar / display name / bio / "X outfits · Y followers"), but
/// presented full-screen via `.fullScreenCover` with a back-arrow in
/// place of the Yafa logo and a FOLLOW button below the stats.
///
/// File name is `UserProfileSheet.swift` for legacy reasons — kept to
/// avoid an Xcode project re-shuffle. The struct is `UserProfileView`.
///
/// The carousel-from-grid hero transition mirrors the one in
/// `OutfitGridView` (shared types live in `CarouselHeroSupport.swift`).
/// The carousel itself is mounted with `viewOnly: true` so the
/// owner-only affordances (publish, delete, edit, add-tag,
/// add-product) are hidden — viewers can still scrub, swipe, like,
/// and share.
struct UserProfileView: View {
    let userId: UUID
    /// Triggered when the user taps the back arrow. Caller binds this
    /// to the `isPresented` flag on the `.fullScreenCover`.
    let onDismiss: () -> Void

    @Environment(OutfitStore.self) private var store

    @State private var profile: Profile?
    @State private var outfits: [Outfit] = []
    @State private var isLoading = true
    @State private var followerIds: [UUID] = []
    @State private var followingIds: [UUID] = []
    @State private var showFollowers = false
    @State private var showFollowing = false
    @State private var vibesReceived: Int = 0
    /// Public-outfit count for this profile. Computed server-side via
    /// `public_outfit_count` RPC so it's correct even when the
    /// viewer is a non-follower of a private user (RLS would hide
    /// the outfit rows themselves, but the COUNT should still be
    /// shown as a social signal — see
    /// `project_yafa_outfit_count_display.md`). Falls back to
    /// `outfits.count` if the RPC fails.
    @State private var publicOutfitCount: Int = 0

    // Carousel + hero-transition state. Same shape as OutfitGridView.
    @State private var outfitFrames: [String: CGRect] = [:]
    @State private var outfitFrameIndices: [String: Int] = [:]
    @State private var outfitFrameImages: [String: UIImage] = [:]
    @State private var showCarousel = false
    @State private var carouselBackdropVisible = false
    @State private var carouselChromeVisible = false
    @State private var carouselIndex = 0
    @State private var activeCarouselFrameIndex = 0
    @State private var activeCarouselDisplayedFrame: Int?
    @State private var heroTransition: HeroTransition?
    @State private var heroOpacity: Double = 1
    @State private var showCurrentCarouselLiveSlide = false
    @State private var showCarouselEntryOverlay = false
    @State private var carouselEntryFrame: CarouselEntryFrame?
    @State private var carouselEntryImage: UIImage?
    @State private var heroFrame: CGRect = .zero
    @State private var carouselTargetFrame: CGRect = .null
    @State private var carouselTransitionTask: Task<Void, Never>?

    // Swipe-down-to-dismiss state.
    @State private var scrollOffset: CGFloat = 0
    @State private var dismissDragOffset: CGFloat = 0
    @State private var isDismissDragging = false

    private let heroTransitionDuration: Double = 0.32
    private let heroFadeInDuration: Double = 0.12
    private let heroFadeOutDuration: Double = 0.08
    private let carouselBackdropFadeInDuration: Double = 0.22
    private let carouselBackdropFadeOutDuration: Double = 0.12
    private let carouselChromeFadeInDuration: Double = 0.28
    private let carouselChromeFadeOutDuration: Double = 0.1

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
    ]

    private var isOwnProfile: Bool { userId == store.userId }
    private var isFollowing: Bool { store.followingIds.contains(userId) }

    var body: some View {
        // Base canvas that stays fixed when the swipe-down dismiss
        // pulls the inner content off the top. Without this, sliding
        // the contents down reveals the fullScreenCover's default
        // black backdrop at the top edge.
        ZStack {
            AppPalette.pageBackground.ignoresSafeArea()
            bodyContent
        }
        // Same fix as OutfitGridView: opt the whole surface out of
        // keyboard avoidance so focusing the carousel card's
        // location/tag fields doesn't shove the carousel up. The
        // shift was happening because SwiftUI applies the keyboard
        // safe area inset at the parent ZStack here; lower
        // `.ignoresSafeArea(.keyboard)` calls inside CarouselView
        // only expanded its subtree without un-shifting the parent.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var bodyContent: some View {
        GeometryReader { geometry in
            let viewportFrame = geometry.frame(in: .global)
            let heroDisplayFrame = displayedHeroFrame(in: viewportFrame)

            ZStack(alignment: .top) {
                AppPalette.pageBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Emit the scroll's top-edge offset in the
                        // named coord space. Positive = at top or
                        // overscrolled past it (bounce); negative =
                        // content has scrolled up. Gates the dismiss
                        // gesture below so we only tear the view off
                        // when there's nothing left to scroll.
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: UserProfileScrollOffsetKey.self,
                                value: proxy.frame(in: .named("userProfileScroll")).minY
                            )
                        }
                        .frame(height: 0)

                        // Just clear the safe area — the X button sits
                        // in the top-left corner and the avatar is
                        // centered, so they don't visually collide.
                        // Anything more pushes the avatar lower than
                        // necessary on first load.
                        Color.clear.frame(height: LayoutMetrics.safeTop)

                        if isLoading {
                            ProgressView()
                                .padding(.top, LayoutMetrics.xLarge)
                                .frame(maxWidth: .infinity)
                        } else {
                            header
                            sectionHeader
                            if outfits.isEmpty {
                                emptyState
                            } else {
                                outfitGrid
                            }
                            Color.clear.frame(height: LayoutMetrics.screenPadding)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.small)
                }
                .coordinateSpace(name: "userProfileScroll")
                .onPreferenceChange(UserProfileScrollOffsetKey.self) { scrollOffset = $0 }
                .scrollDisabled(showCarousel)
                .allowsHitTesting(!showCarousel)
                .simultaneousGesture(swipeDownDismissGesture)

                topBar

                if showCarousel {
                    CarouselView(
                        outfits: outfits,
                        currentIndex: $carouselIndex,
                        backdropOpacity: carouselBackdropVisible ? 1 : 0,
                        showsChrome: carouselChromeVisible,
                        showsCurrentLiveSlide: showCurrentCarouselLiveSlide,
                        showsEntryOverlay: showCarouselEntryOverlay,
                        entryFrame: carouselEntryFrame,
                        entryImage: carouselEntryImage,
                        onHeroTargetFrameChange: { frame in
                            carouselTargetFrame = frame
                        },
                        onCurrentFrameChange: { frameIndex in
                            activeCarouselFrameIndex = frameIndex
                            if let entryFrame = carouselEntryFrame,
                               outfits[safe: carouselIndex]?.id == entryFrame.outfitId,
                               frameIndex != entryFrame.frameIndex {
                                hideCarouselEntryOverlay()
                            }
                        },
                        onCurrentDisplayedFrameChange: { frameIndex in
                            activeCarouselDisplayedFrame = frameIndex
                        },
                        onCurrentScrubBegan: {
                            hideCarouselEntryOverlay()
                        },
                        onDeleteOutfit: { _ in
                            // Viewers can't delete someone else's
                            // outfit. Hidden via viewOnly anyway.
                        },
                        onDismiss: { dismissCarousel() },
                        viewOnly: true
                    )
                    .compositingGroup()
                    .zIndex(1)
                }

                if let heroTransition, !heroDisplayFrame.isNull {
                    HeroOutfitImageView(
                        outfit: heroTransition.outfit,
                        frameIndex: heroTransition.frameIndex,
                        initialImage: heroTransition.image
                    )
                        .opacity(heroOpacity)
                        .frame(width: heroDisplayFrame.width, height: heroDisplayFrame.height)
                        .position(x: heroDisplayFrame.midX, y: heroDisplayFrame.midY)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
            .onPreferenceChange(ListOutfitFramePreferenceKey.self) { frames in
                outfitFrames = frames
            }
            .offset(y: dismissDragOffset)
            .opacity(isDismissDragging ? max(0.3, 1.0 - dismissDragOffset / 500) : 1)
        }
        .task { await loadProfile() }
        .onChange(of: store.carouselDismissTrigger) { _, _ in
            // Mirrors OutfitGridView — the global X button in the
            // top bar bumps this trigger; only act if our carousel
            // is the one currently showing.
            guard showCarousel else { return }
            dismissCarousel()
        }
        .onDisappear { carouselTransitionTask?.cancel() }
        .sheet(isPresented: $showFollowers) {
            FollowListSheet(title: "Followers", userIds: followerIds)
                .environment(store)
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.groupedBackground)
        }
        .sheet(isPresented: $showFollowing) {
            FollowListSheet(title: "Following", userIds: followingIds)
                .environment(store)
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.groupedBackground)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if showCarousel {
                    dismissCarousel()
                } else {
                    onDismiss()
                }
            } label: {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
        .frame(maxHeight: .infinity, alignment: .top)
        .zIndex(3)
    }

    // MARK: - Header (avatar / name / bio / stats / follow)

    private var header: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            avatar

            Text(displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.top, LayoutMetrics.xxSmall)

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.large)
            }

            statsRow.padding(.top, LayoutMetrics.xxSmall)

            if !isOwnProfile {
                followButton.padding(.top, LayoutMetrics.xSmall)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, LayoutMetrics.medium)
    }

    private var avatar: some View {
        // Avatar is read-only here — only the user's own ProfileHeader
        // exposes the PhotosPicker + crop flow. Keep the visual shape
        // (88pt circle, soft shadow) consistent across both views.
        AvatarView(
            url: profile?.avatarUrl,
            initial: profile?.initial ?? String(displayName.prefix(1)).uppercased(),
            size: 88,
            shadowRadius: 10,
            shadowY: 4
        )
    }

    private var displayName: String {
        if let name = profile?.displayName, !name.isEmpty { return name }
        if let username = profile?.username, !username.isEmpty { return username }
        return "User"
    }

    private var statsRow: some View {
        HStack(spacing: LayoutMetrics.small) {
            statSegment(count: publicOutfitCount, label: publicOutfitCount == 1 ? "outfit" : "outfits")

            Text("·")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textFaint)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showFollowers = true
            } label: {
                statSegment(count: followerIds.count, label: followerIds.count == 1 ? "follower" : "followers")
            }
            .buttonStyle(.plain)

            if vibesReceived > 0 {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textFaint)

                statSegment(
                    count: vibesReceived,
                    label: vibesReceived == 1 ? "vibe" : "vibes"
                )
            }
        }
    }

    private func statSegment(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textMuted)
        }
    }

    private var followButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.18)) {
                store.toggleFollow(userId)
            }
        } label: {
            Text(isFollowing ? "FOLLOWING" : "FOLLOW")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(isFollowing ? AppPalette.textMuted : AppPalette.textPrimary)
                .frame(maxWidth: 200)
                .frame(height: 36)
                .appCapsule(shadowRadius: 4, shadowY: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section header + grid

    /// "outfits" label only — no grid/calendar toggle on other-user
    /// profiles (calendar view is intentionally absent here).
    private var sectionHeader: some View {
        HStack {
            Text("outfits")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.leading, LayoutMetrics.xxSmall)
            Spacer()
        }
        .padding(.top, LayoutMetrics.xSmall)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    private var outfitGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 42) {
            ForEach(Array(outfits.enumerated()), id: \.element.id) { index, outfit in
                gridItem(outfit: outfit, index: index)
            }
        }
    }

    private func gridItem(outfit: Outfit, index: Int) -> some View {
        OutfitCardView(
            outfit: outfit,
            eagerLoad: index < 9,
            syncFrameIndex: outfitFrameIndices[outfit.id],
            syncImage: outfitFrameImages[outfit.id],
            onTap: { frameIndex, image in
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                store.feedOutfitCache[outfit.id] = outfit
                presentCarousel(for: outfit, at: index, frameIndex: frameIndex, image: image)
            }
        )
        // Emit the cell's screen-space frame so presentCarousel knows
        // where to start the hero morph from.
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ListOutfitFramePreferenceKey.self,
                    value: [outfit.id: proxy.frame(in: .global)]
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            Text("No public outfits yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
        }
        .padding(.top, LayoutMetrics.large)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero present / dismiss

    private func presentCarousel(for outfit: Outfit, at index: Int, frameIndex: Int, image: UIImage?) {
        carouselTransitionTask?.cancel()
        let entryFrameIndex = frameIndex
        carouselTransitionTask = Task { @MainActor in
            let entryImage: UIImage?
            if let image {
                entryImage = image
            } else {
                entryImage = await FrameLoader.shared.frame(for: outfit, index: entryFrameIndex)
            }
            guard !Task.isCancelled else { return }

            carouselIndex = index
            activeCarouselFrameIndex = entryFrameIndex
            activeCarouselDisplayedFrame = nil
            heroOpacity = 1
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            outfitFrameIndices[outfit.id] = entryFrameIndex
            if let entryImage {
                outfitFrameImages[outfit.id] = entryImage
            }
            carouselEntryFrame = CarouselEntryFrame(outfitId: outfit.id, frameIndex: entryFrameIndex)
            carouselEntryImage = entryImage
            carouselChromeVisible = false
            carouselTargetFrame = .null

            guard let sourceFrame = outfitFrames[outfit.id] else {
                showCarousel = true
                heroTransition = nil
                showCurrentCarouselLiveSlide = true
                withAnimation(.easeInOut(duration: carouselBackdropFadeInDuration)) {
                    carouselBackdropVisible = true
                }
                _ = await waitForCarouselDisplayedFrame(entryFrameIndex, outfitId: outfit.id)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: carouselChromeFadeInDuration)) {
                    carouselChromeVisible = true
                }
                return
            }

            heroTransition = HeroTransition(outfit: outfit, frameIndex: entryFrameIndex, image: entryImage)
            heroFrame = sourceFrame
            showCarousel = true
            withAnimation(.easeInOut(duration: carouselBackdropFadeInDuration)) {
                carouselBackdropVisible = true
            }

            let targetFrame = await waitForCarouselTargetFrame(fallback: sourceFrame)
            guard !Task.isCancelled else { return }

            withAnimation(.timingCurve(0.22, 0.84, 0.18, 1, duration: heroTransitionDuration)) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            _ = await waitForCarouselDisplayedFrame(entryFrameIndex, outfitId: outfit.id)
            guard !Task.isCancelled else { return }

            showCurrentCarouselLiveSlide = true
            withAnimation(.easeOut(duration: heroFadeInDuration)) {
                showCarouselEntryOverlay = carouselEntryImage != nil
                heroOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(Int(heroFadeInDuration * 1000)))
            guard !Task.isCancelled else { return }

            heroTransition = nil
            heroOpacity = 1

            withAnimation(.easeInOut(duration: carouselChromeFadeInDuration)) {
                carouselChromeVisible = true
            }
        }
    }

    private func dismissCarousel() {
        carouselTransitionTask?.cancel()

        guard
            showCarousel,
            let currentOutfit = outfits[safe: carouselIndex]
        else {
            resetCarouselState()
            return
        }

        let startFrame = carouselTargetFrame.isNull ? heroFrame : carouselTargetFrame
        let exitFrameIndex = activeCarouselDisplayedFrame ?? activeCarouselFrameIndex

        carouselTransitionTask = Task { @MainActor in
            let targetFrame = outfitFrames[currentOutfit.id]
            let exitImage = await FrameLoader.shared.frame(for: currentOutfit, index: exitFrameIndex)
            guard !Task.isCancelled else { return }

            heroOpacity = 1
            outfitFrameIndices[currentOutfit.id] = exitFrameIndex
            if let exitImage {
                outfitFrameImages[currentOutfit.id] = exitImage
            }

            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            withAnimation(.easeInOut(duration: carouselChromeFadeOutDuration)) {
                carouselChromeVisible = false
            }
            withAnimation(.easeInOut(duration: carouselBackdropFadeOutDuration)) {
                carouselBackdropVisible = false
            }

            guard let targetFrame, !targetFrame.isEmpty else {
                try? await Task.sleep(for: .milliseconds(Int(carouselBackdropFadeOutDuration * 1000)))
                resetCarouselState()
                return
            }

            heroTransition = HeroTransition(outfit: currentOutfit, frameIndex: exitFrameIndex, image: exitImage)
            heroFrame = startFrame

            withAnimation(.timingCurve(0.22, 0.84, 0.18, 1, duration: heroTransitionDuration)) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: heroFadeOutDuration)) {
                heroOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(Int(heroFadeOutDuration * 1000)))
            guard !Task.isCancelled else { return }

            resetCarouselState()
        }
    }

    private func resetCarouselState() {
        showCarousel = false
        carouselBackdropVisible = false
        carouselChromeVisible = false
        heroTransition = nil
        heroOpacity = 1
        showCurrentCarouselLiveSlide = false
        showCarouselEntryOverlay = false
        carouselEntryFrame = nil
        carouselEntryImage = nil
        heroFrame = .zero
        carouselTargetFrame = .null
        activeCarouselFrameIndex = 0
        activeCarouselDisplayedFrame = nil
    }

    private func hideCarouselEntryOverlay() {
        guard showCarouselEntryOverlay else { return }
        withAnimation(.easeOut(duration: heroFadeOutDuration)) {
            showCarouselEntryOverlay = false
        }
    }

    @MainActor
    private func waitForCarouselTargetFrame(fallback: CGRect) async -> CGRect {
        for _ in 0 ..< 30 {
            if !carouselTargetFrame.isNull {
                return carouselTargetFrame
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return fallback
    }

    @MainActor
    private func waitForCarouselDisplayedFrame(_ frameIndex: Int, outfitId: String) async -> Bool {
        for _ in 0 ..< 24 {
            if outfits[safe: carouselIndex]?.id == outfitId,
               activeCarouselDisplayedFrame == frameIndex {
                return true
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }

    private func displayedHeroFrame(in viewportFrame: CGRect) -> CGRect {
        guard heroTransition != nil else { return .null }
        return CGRect(
            x: heroFrame.minX - viewportFrame.minX,
            y: heroFrame.minY - viewportFrame.minY,
            width: heroFrame.width,
            height: heroFrame.height
        )
    }

    // MARK: - Swipe-down dismiss

    /// Activated when the user drags downward while the inner
    /// ScrollView is at (or bouncing past) the top. Translates the
    /// whole view down with the finger and fades the page out; on
    /// release past the distance/velocity threshold, calls
    /// `onDismiss`. Otherwise springs back to the resting position
    /// so an aborted drag doesn't accidentally tear the view.
    private var swipeDownDismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let vertical = value.translation.height
                let horizontal = value.translation.width
                let canEngage = scrollOffset >= -1 && vertical > 0 && abs(vertical) > abs(horizontal)
                guard canEngage else {
                    // Drag turned horizontal or pulled back up — let
                    // any in-progress dismiss snap back.
                    if isDismissDragging {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dismissDragOffset = 0
                            isDismissDragging = false
                        }
                    }
                    return
                }
                if !isDismissDragging, vertical > 20 {
                    isDismissDragging = true
                }
                if isDismissDragging {
                    dismissDragOffset = max(0, vertical * 0.7)
                }
            }
            .onEnded { value in
                guard isDismissDragging else { return }
                let velocity = value.predictedEndTranslation.height
                if dismissDragOffset > 100 || velocity > 500 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDismiss()
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dismissDragOffset = 0
                    isDismissDragging = false
                }
            }
    }

    // MARK: - Data

    private func loadProfile() async {
        do {
            async let profileTask = SocialService.getProfile(userId: userId)
            async let outfitsTask = ContentSource.getPublicOutfits(forUser: userId)
            async let followerIdsTask = try SocialService.getFollowerIds(userId: userId)
            async let followingIdsTask = try SocialService.getFollowingIds(userId: userId)
            async let vibesReceivedTask = VibesService.receivedCount(userId: userId)
            async let publicCountTask = try SocialService.publicOutfitCount(userId: userId)

            let p = try await profileTask
            let userOutfits = await outfitsTask
            let frs = (try? await followerIdsTask) ?? []
            let fng = (try? await followingIdsTask) ?? []
            let vibes = await vibesReceivedTask
            // Fall back to the locally-loaded outfit array if the
            // RPC fails (network blip, function not deployed yet,
            // etc.). For a public-profile viewer this falls back
            // to the right number; for a private-profile non-
            // follower it'd fall back to 0 — same as today's
            // behavior, so no regression.
            let publicCount = (try? await publicCountTask) ?? userOutfits.count

            await MainActor.run {
                profile = p
                outfits = userOutfits
                followerIds = Array(frs)
                followingIds = Array(fng)
                vibesReceived = vibes
                publicOutfitCount = publicCount
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

private struct UserProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

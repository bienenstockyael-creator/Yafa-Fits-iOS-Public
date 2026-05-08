import SwiftUI
import Lottie

struct RootView: View {
    @Environment(OutfitStore.self) private var store

    private let headerContentInset: CGFloat = 0

    @State private var loaderMounted = true
    @State private var loaderVisible = true
    @State private var loaderDismissTask: Task<Void, Never>?
    @State private var showsFavoritesSheet = false
    @State private var showsVirtualCloset = false
    @State private var showsAvatarOnboarding = false
    /// Standardized closet avatar. Hydrated from disk on appear so a returning
    /// user doesn't have to redo onboarding. Cross-device sync via Supabase
    /// Storage is a follow-up.
    @State private var closetAvatar: UIImage?
    @State private var hydratedAvatarForUserId: UUID?
    @State private var feedHasAppeared = false
    // In-app notification banner
    @State private var showReviewBanner = false
    @State private var bannerDismissTask: Task<Void, Never>?

    // Hero transition state
    @State private var heroTransitioning = false
    @State private var heroOutfit: Outfit?
    @State private var heroImage: UIImage?
    @State private var heroFrame: CGRect = .zero
    @State private var heroOpacity: Double = 0
    @State private var heroFrameIndex: Int = 0
    @State private var viewTransitionTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        ZStack(alignment: .top) {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                switch store.currentView {
                case .list, .calendar:
                    ZStack {
                        OutfitGridView()
                            .opacity(listViewOpacity)
                            .blur(radius: listViewBlur)
                            .allowsHitTesting(store.currentView == .list && !heroTransitioning)

                        CalendarMonthView()
                            .opacity(calendarViewOpacity)
                            .blur(radius: calendarViewBlur)
                            .allowsHitTesting(store.currentView == .calendar && !heroTransitioning)
                    }
                case .upload:
                    UploadPipelineView()
                case .profile:
                    ProfileView()
                default:
                    EmptyView()
                }

                // Feed stays mounted so scroll position is preserved across tab switches
                if store.currentView == .feed || feedHasAppeared {
                    PublicFeedListView()
                        .opacity(store.currentView == .feed ? 1 : 0)
                        .allowsHitTesting(store.currentView == .feed)
                        .frame(maxWidth: store.currentView == .feed ? .infinity : 0,
                               maxHeight: store.currentView == .feed ? .infinity : 0)
                        .onAppear { feedHasAppeared = true }
                }
            }
            .padding(.top, headerContentInset)

            if store.currentView != .feed {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }
                .zIndex(90)
            }

            CalendarDetailOverlayHost()
                .zIndex(140)

            if let heroOutfit, heroTransitioning {
                viewTransitionHero(outfit: heroOutfit)
                    .zIndex(200)
            }

            if showsFloatingButtons {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Spacer()
                        floatingFavoritesButton
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .zIndex(65)
            }

            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
            .zIndex(60)

            if loaderMounted {
                loadingOverlay
                    .zIndex(999)
            }

            // In-app review notification banner
            if showReviewBanner {
                VStack {
                    reviewBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .zIndex(500)
            }
        }
        .safeAreaInset(edge: .bottom) {
            tabBar
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onAppear {
            store.restorePersistedPendingReviewIfNeeded()
            syncLoadingOverlay(isLoading: store.isLoading)
            hydrateClosetAvatarIfNeeded()
            Task {
                await PushNotificationCoordinator.shared.requestAuthorization()
            }
        }
        .onChange(of: store.userId) { _, _ in
            hydrateClosetAvatarIfNeeded()
        }
        .onChange(of: store.isLoading) { _, isLoading in
            syncLoadingOverlay(isLoading: isLoading)
        }
        .onChange(of: store.generationReadyForReview) { _, ready in
            guard ready else { return }
            store.generationReadyForReview = false
            if store.currentView != .upload {
                presentReviewBanner()
            }
        }
        .onDisappear {
            loaderDismissTask?.cancel()
            viewTransitionTask?.cancel()
            bannerDismissTask?.cancel()
        }
        .sheet(isPresented: $showsFavoritesSheet) {
            FavoritesSheetView()
                .environment(store)
        }
        .fullScreenCover(isPresented: $showsVirtualCloset) {
            if let userId = store.userId {
                VirtualClosetView(
                    userId: userId,
                    avatar: closetAvatar
                ) {
                    showsVirtualCloset = false
                }
                .environment(store)
            }
        }
        .fullScreenCover(isPresented: $showsAvatarOnboarding) {
            AvatarOnboardingView(
                onAccept: { avatar in
                    closetAvatar = avatar
                    if let userId = store.userId {
                        ClosetAvatarStorage.save(avatar, userId: userId)
                        hydratedAvatarForUserId = userId
                    }
                    showsAvatarOnboarding = false
                    // Hand off to the closet after the cover dismisses so
                    // the second presentation animates cleanly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showsVirtualCloset = true
                    }
                },
                onClose: { showsAvatarOnboarding = false }
            )
            .environment(store)
        }
    }

    private var showsFloatingButtons: Bool {
        !store.isLoading
            && store.selectedOutfitId == nil
            && (store.currentView == .list || store.currentView == .calendar)
    }

    private var topBar: some View {
        HStack {
            logoView
            Spacer()
            HStack(spacing: 8) {
                if store.currentView == .list || store.currentView == .calendar {
                    if store.isCarouselOpen {
                        tempToggle
                    } else {
                        viewModeToggle
                        if canAccessVirtualCloset {
                            closetButton
                        }
                    }
                } else if store.currentView == .profile {
                    tempToggle
                }
            }
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
        .contentShape(Rectangle())
    }

    private var isCalendarActive: Bool {
        store.currentView == .calendar
    }

    // Cinematic crossfade: source blurs out, target blurs in
    private var listViewOpacity: Double {
        switch store.viewTransitionPhase {
        case .idle: return store.currentView == .list ? 1 : 0
        case .sourceOut: return store.currentView == .list ? 0 : 0  // source fading out, target not yet in
        case .targetIn: return store.currentView == .list ? 1 : 0   // target fading in
        }
    }

    private var listViewBlur: CGFloat {
        // Constant zero. Previously: blur was conditionally 8 only when
        // the source was list — but `currentView` flips mid-transition,
        // so the blur value abruptly jumped from 8→0 at the same time
        // the opacity was animating, causing visible flicker. The
        // opacity crossfade alone is enough; blur added more cost than
        // visual benefit.
        0
    }

    private var calendarViewOpacity: Double {
        switch store.viewTransitionPhase {
        case .idle: return store.currentView == .calendar ? 1 : 0
        case .sourceOut: return store.currentView == .calendar ? 0 : 0
        case .targetIn: return store.currentView == .calendar ? 1 : 0
        }
    }

    private var calendarViewBlur: CGFloat { 0 }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            viewModeOption(glyph: .grid, isSelected: !isCalendarActive) {
                guard isCalendarActive else { return }
                performViewTransition()
            }
            viewModeOption(glyph: .calendar, isSelected: isCalendarActive) {
                guard !isCalendarActive else { return }
                performViewTransition()
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
        )
        .overlay(
            Capsule()
                .stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8)
        )
        .padding(8)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: isCalendarActive)
    }

    /// Loads the persisted avatar for the current user if we haven't already
    /// hydrated for that ID this session. Returning users skip onboarding.
    private func hydrateClosetAvatarIfNeeded() {
        guard let userId = store.userId, hydratedAvatarForUserId != userId else { return }
        hydratedAvatarForUserId = userId
        if let stored = ClosetAvatarStorage.load(userId: userId) {
            closetAvatar = stored
        }
    }

    /// Gates the Virtual Closet entry point to Pro accounts (`profile.isPro`)
    /// or the archive owner. While Pro is being rolled out, only the owner
    /// sees the closet — every other account gets the standard list/calendar
    /// toggle without the closet shortcut.
    private var canAccessVirtualCloset: Bool {
        if store.userId?.uuidString.lowercased() == AppConfig.archiveOwnerUserId {
            return true
        }
        return store.currentProfile?.isPro == true
    }

    /// Entry point into the Virtual Closet. Sits next to the grid/calendar
    /// toggle on the List & Calendar tabs. First time in: routes through
    /// avatar onboarding. Subsequent visits go straight to the closet.
    private var closetButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if closetAvatar == nil {
                showsAvatarOnboarding = true
            } else {
                showsVirtualCloset = true
            }
        } label: {
            AppIcon(glyph: .tshirt, size: 12, color: AppPalette.iconPrimary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
                )
                .overlay(
                    Circle()
                        .stroke(
                            Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9),
                            lineWidth: 0.8
                        )
                )
                .padding(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero View Transition

    private func performViewTransition() {
        // 1. Cancel + reset prior state synchronously. Stale heroOutfit /
        // heroFrame from a previous transition was leaking into the next
        // one, causing the "recalls the first outfit" bug — the new
        // transition would briefly inherit heroAnchorOutfitId before
        // replacing it, leading to flicker.
        viewTransitionTask?.cancel()
        cleanupHero()

        let goingToCalendar = !isCalendarActive
        let sourceFrames = goingToCalendar ? store.listOutfitFrames : store.calendarOutfitFrames

        // 2. Compute anchor FRESHLY from current frame data. Don't trust
        // store.centeredListOutfitId — with LazyVGrid the cached value
        // can lag behind actual scroll position and recall a previously-
        // centered outfit even after the user has scrolled past it.
        let freshAnchor = mostCenteredOutfit(in: sourceFrames)
        let anchorId = freshAnchor
            ?? store.centeredListOutfitId
            ?? store.sortedOutfits.first?.id

        // 3. Validate source frame BEFORE starting the hero. If it's
        // missing or zero-sized (cold first attempt, items not yet
        // mounted in the LazyVGrid), bail to a clean instant switch
        // instead of running a hero with no source — that's what was
        // causing "lands nowhere and disappears".
        guard let anchorId,
              let outfit = store.outfitById[anchorId],
              let sourceFrame = sourceFrames[anchorId],
              sourceFrame.width > 0,
              sourceFrame.height > 0 else {
            store.selectedOutfitId = nil
            if let anchorId, goingToCalendar {
                store.pendingCalendarScrollOutfitId = anchorId
            }
            store.currentView = goingToCalendar ? .calendar : .list
            return
        }

        let frameIndex = store.listOutfitFrameIndices[anchorId] ?? 0

        viewTransitionTask = Task { @MainActor in
            // Step 1: Load hero image, hide anchor outfit
            // === Web-repo flow port ==================================
            // The web version's order is:
            //   1. Set view + pre-scroll (no hero yet, no card hidden)
            //   2. Wait ~180ms for layout
            //   3. Re-read source rect FRESH at kickoff (don't trust the
            //      snapshot from tap time — layout may have shifted)
            //   4. NOW position hero, hide source card, show hero
            //   5. Poll for STABLE target rect (require 2+ consecutive
            //      reads matching at single-pixel precision)
            //   6. Animate hero to stable target
            //   7. End: clear anchor → next frame → fade hero (rAF
            //      handoff so real anchor paints before hero disappears)
            //
            // iOS now follows the same shape. The previous version was
            // hiding the source card immediately (causing flicker) and
            // using a snapshot source rect (causing position errors).
            heroOutfit = outfit
            heroFrameIndex = frameIndex
            heroImage = await FrameLoader.shared.frame(for: outfit, index: frameIndex)
            guard !Task.isCancelled else { return }

            // Step 2: Source-out animation (no hero yet). Don't hide the
            // source card or show the hero; just start fading the source
            // view itself via the phase change.
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.30)) {
                store.viewTransitionPhase = .sourceOut
            }

            // Step 3: Switch view + trigger calendar pre-scroll. This
            // gives the calendar time to scroll the target into view
            // BEFORE the hero appears, mirroring web's pre-scroll step.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return /* let new task own cleanup */ }

            store.selectedOutfitId = nil
            if goingToCalendar {
                store.pendingCalendarScrollOutfitId = anchorId
            }
            store.currentView = goingToCalendar ? .calendar : .list

            // Step 4: Wait for calendar to settle before polling target.
            if goingToCalendar {
                let scrollWaitStart = Date()
                while store.pendingCalendarScrollOutfitId != nil,
                      Date().timeIntervalSince(scrollWaitStart) < 0.55 {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return /* let new task own cleanup */ }
                }
            } else {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return /* let new task own cleanup */ }

            // Step 5: Re-read the SOURCE frame fresh from the store. The
            // source view has been fading + the user may have scrolled
            // slightly between tap and this point; the snapshot we
            // captured at tap may be stale. Falls back to the snapshot
            // if the live read is gone (LazyVGrid unmounted it).
            let liveSourceFrames = goingToCalendar ? store.listOutfitFrames : store.calendarOutfitFrames
            let kickoffSourceFrame: CGRect = {
                if let live = liveSourceFrames[anchorId],
                   live.width > 0, live.height > 0 {
                    return live
                }
                return sourceFrame
            }()

            // Step 6: NOW position hero, hide source card, make hero
            // visible. Doing this AFTER pre-scroll (and after the source
            // re-read) eliminates the "card pops, hero appears at wrong
            // spot" flicker the previous order produced.
            heroFrame = kickoffSourceFrame
            store.heroAnchorOutfitId = anchorId
            heroOpacity = 1
            heroTransitioning = true

            // Step 7: Poll for STABLE on-screen target. rAF-style 16ms
            // intervals, require two consecutive matching reads (sub-px),
            // up to 400ms. If never stable, abort the hero and crossfade.
            let viewportRect = UIScreen.main.bounds
            var targetFrame: CGRect?
            var lastFrame: CGRect?
            let pollStart = Date()
            while Date().timeIntervalSince(pollStart) < 0.40 {
                let frames = goingToCalendar ? store.calendarOutfitFrames : store.listOutfitFrames
                if let frame = frames[anchorId],
                   frame.width > 0, frame.height > 0,
                   frame.intersects(viewportRect) {
                    if let last = lastFrame,
                       abs(last.minX - frame.minX) < 0.5,
                       abs(last.minY - frame.minY) < 0.5,
                       abs(last.width - frame.width) < 0.5,
                       abs(last.height - frame.height) < 0.5 {
                        targetFrame = frame
                        break
                    }
                    lastFrame = frame
                }
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return /* let new task own cleanup */ }
            }
            if targetFrame == nil { targetFrame = lastFrame }
            guard !Task.isCancelled else { return /* let new task own cleanup */ }

            guard let targetFrame else {
                // No usable target landed — abort hero, do a clean
                // opacity crossfade for the view, settle to idle.
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)) {
                    store.viewTransitionPhase = .targetIn
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    heroOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(160))
                store.heroAnchorOutfitId = nil
                withAnimation(.easeOut(duration: 0.18)) {
                    store.viewTransitionPhase = .idle
                }
                cleanupHero()
                return
            }

            // Step 6: Hero flight + concurrent target reveal.
            let flightDuration: Double = 0.65
            startHeroRotation(outfit: outfit, startFrame: frameIndex)
            withAnimation(.timingCurve(0.32, 0, 0.24, 1, duration: flightDuration)) {
                heroFrame = targetFrame
            }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)) {
                store.viewTransitionPhase = .targetIn
            }

            // Wait for hero to finish its arc.
            try? await Task.sleep(for: .milliseconds(Int(flightDuration * 1000)))
            guard !Task.isCancelled else { return /* let new task own cleanup */ }

            // Step 8: rAF-style handoff (web pattern):
            //   (a) Clear heroAnchorOutfitId — the real destination cell
            //       becomes visible at full opacity, BEHIND the hero.
            //   (b) Wait one frame so the real cell has actually painted.
            //   (c) Fade the hero clone away over the now-visible cell.
            // This eliminates the "double image" flicker the previous
            // order produced (hero faded first → momentary blank where
            // the cell hadn't appeared yet).
            store.heroAnchorOutfitId = nil
            try? await Task.sleep(for: .milliseconds(16))  // ~one frame
            withAnimation(.easeOut(duration: 0.14)) {
                heroOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(160))

            // Step 9: Settle to idle.
            withAnimation(.easeOut(duration: 0.18)) {
                store.viewTransitionPhase = .idle
            }
            cleanupHero()
        }
    }

    private func startHeroRotation(outfit: Outfit, startFrame: Int) {
        let frameCount = outfit.frameCount
        guard frameCount > 1 else { return }

        Task { @MainActor in
            let startTime = CACurrentMediaTime()
            // Match the hero flight duration so rotation finishes as it
            // lands. Was 0.9s when flight was 1.0s; now 0.6s for 0.65s flight.
            let duration: Double = 0.6

            while heroTransitioning {
                let elapsed = CACurrentMediaTime() - startTime
                let progress = min(elapsed / duration, 1.0)

                // Smoothstep easing: 65% linear + 35% hermite
                let smoothStep = progress * progress * (3 - 2 * progress)
                let eased = progress + (smoothStep - progress) * 0.35

                let frameOffset = Int(eased * Double(frameCount))
                let newIndex = ((startFrame + frameOffset) % frameCount + frameCount) % frameCount

                if newIndex != heroFrameIndex {
                    heroFrameIndex = newIndex
                    heroImage = await FrameLoader.shared.frame(for: outfit, index: newIndex)
                }

                if progress >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Picks the outfit whose card center is closest to the screen
    /// center. Computed freshly at tap time from the most recent
    /// frame data — this avoids the staleness problem of relying on
    /// `store.centeredListOutfitId`, which can lag behind LazyVGrid
    /// scroll state and cause the wrong (previously-centered) outfit
    /// to be used as the transition anchor.
    private func mostCenteredOutfit(in frames: [String: CGRect]) -> String? {
        guard !frames.isEmpty else { return nil }
        let screenBounds = UIScreen.main.bounds
        let center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        let valid = frames.filter { _, frame in
            frame.width > 0 && frame.height > 0
        }
        guard !valid.isEmpty else { return nil }
        return valid.min { lhs, rhs in
            let lc = CGPoint(x: lhs.value.midX, y: lhs.value.midY)
            let rc = CGPoint(x: rhs.value.midX, y: rhs.value.midY)
            return distSq(from: lc, to: center) < distSq(from: rc, to: center)
        }?.key
    }

    private func distSq(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func cleanupHero() {
        heroTransitioning = false
        heroOutfit = nil
        heroImage = nil
        heroOpacity = 0
        heroFrame = .zero
        heroFrameIndex = 0
        store.heroAnchorOutfitId = nil
        if store.viewTransitionPhase != .idle {
            store.viewTransitionPhase = .idle
        }
    }

    private func viewTransitionHero(outfit: Outfit) -> some View {
        GeometryReader { geometry in
            let viewportFrame = geometry.frame(in: .global)
            let displayFrame = CGRect(
                x: heroFrame.minX - viewportFrame.minX,
                y: heroFrame.minY - viewportFrame.minY,
                width: heroFrame.width,
                height: heroFrame.height
            )

            Group {
                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: displayFrame.width, height: displayFrame.height)
            .position(x: displayFrame.midX, y: displayFrame.midY)
            .opacity(heroOpacity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var logoView: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.selectedOutfitId = nil
            store.currentView = .list
        } label: {
            Group {
                if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
                   let data = try? Data(contentsOf: logoURL),
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 34)
                        .colorMultiply(.black)
                        .opacity(0.82)
                } else {
                    Text("YAFA")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textPrimary.opacity(0.82))
                }
            }
        }
        .frame(minHeight: 44)
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
                tabItem(icon: .grid, iconSize: 22, label: "Home", tab: .list)
                tabItem(icon: .plusCircle, iconSize: 26, label: "Upload", tab: .upload)
                tabItem(icon: .globe, iconSize: 24, label: "Public", tab: .feed)
                tabItem(icon: .person, iconSize: 22, label: "Profile", tab: .profile)
            }
            .padding(.horizontal, LayoutMetrics.large)
            .padding(.vertical, LayoutMetrics.xxSmall)
            .background {
                ZStack {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(Capsule(style: .continuous))
                    Capsule(style: .continuous).fill(AppPalette.cardFill)
                }
            }
            .overlay(Capsule(style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)
            .shadow(color: Color.black.opacity(0.06), radius: 6, y: 3)
            .padding(.horizontal, LayoutMetrics.xLarge)
            .padding(.bottom, LayoutMetrics.xxSmall)
    }

    private func tabItem(icon: AppIconGlyph, iconSize: CGFloat = 24, label: String, tab: AppView) -> some View {
        let isActive = store.currentView == tab || (tab == .list && store.currentView == .calendar)
        let showsUploadActivity = tab == .upload && store.isUploadInProgress
        return Button {
            let targetTab = (tab == .list && store.currentView == .calendar) ? AppView.list : tab
            if store.currentView == targetTab {
                // Already on this tab — refresh feed if on feed
                if tab == .feed {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    store.feedScrollToTopTrigger += 1
                }
                return
            }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()

            store.selectedOutfitId = nil
            store.currentView = targetTab
        } label: {
            VStack(spacing: LayoutMetrics.xxxSmall) {
                ZStack(alignment: .topTrailing) {
                    if tab == .upload {
                        UploadTabIconView(
                            isActive: isActive,
                            isAnimating: showsUploadActivity,
                            progress: store.uploadIndicatorProgress
                        )
                    } else {
                        AppIcon(
                            glyph: icon,
                            size: iconSize,
                            color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
                        )
                        .frame(width: 36, height: 36)
                    }

                    if tab == .feed && store.unreadNotificationCount > 0 {
                        Text("\(store.unreadNotificationCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppPalette.uploadGlow.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background {
                                LightBlurView(style: .systemThinMaterialLight)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .fill(Color.white.opacity(0.96))
                                    )
                            }
                            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                            .shadow(color: AppPalette.uploadGlow.opacity(0.2), radius: 3, y: 1)
                            .offset(x: 8, y: -5)
                    }

                    if showsUploadActivity {
                        Text("1")
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
                            .offset(x: 8, y: -5)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var tempToggle: some View {
        HStack(spacing: 2) {
            temperatureOption(label: "°F", isSelected: store.useFahrenheit) {
                setTemperatureUnit(true)
            }
            temperatureOption(label: "°C", isSelected: !store.useFahrenheit) {
                setTemperatureUnit(false)
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
        )
        .overlay(
            Capsule()
                .stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8)
        )
        .padding(8)
        .contentShape(Rectangle())
    }

    private func viewModeOption(glyph: AppIconGlyph, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            AppIcon(glyph: glyph, size: 12, color: isSelected ? AppPalette.textPrimary : AppPalette.textFaint)
                .frame(width: 40, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func temperatureOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textFaint)
                .frame(width: 40, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func setTemperatureUnit(_ useFahrenheit: Bool) {
        guard store.useFahrenheit != useFahrenheit else { return }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        withAnimation(.easeInOut(duration: 0.18)) {
            store.useFahrenheit = useFahrenheit
        }
    }


    private var floatingFavoritesButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showsFavoritesSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon(
                    glyph: .heart,
                    size: 16,
                    color: AppPalette.iconPrimary,
                    filled: store.likedIds.contains(where: { id in store.outfits.contains { $0.id == id } })
                )
                    .frame(width: 48, height: 48)
                    .appCircle()
                let ownLikedCount = store.likedIds.filter { id in store.outfits.contains { $0.id == id } }.count
                if ownLikedCount > 0 {
                    Text("\(ownLikedCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 20, height: 20)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(Circle().fill(AppPalette.cardFill))
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .shadow(color: AppPalette.cardShadow, radius: 4, y: 2)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            Group {
                if Bundle.main.url(forResource: "Loader", withExtension: "json") != nil {
                    LottieView(animation: .named("Loader"))
                        .looping()
                        .frame(width: 98, height: 98)
                } else {
                    VStack(spacing: LayoutMetrics.xSmall) {
                        ProgressView()
                        Text("LOADING ARCHIVE")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
            }
        }
        .opacity(loaderVisible ? 1 : 0)
        .allowsHitTesting(loaderVisible)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: AppConfig.loaderFadeDuration), value: loaderVisible)
    }

    private func syncLoadingOverlay(isLoading: Bool) {
        loaderDismissTask?.cancel()

        if isLoading {
            loaderMounted = true
            loaderVisible = true
            return
        }

        loaderVisible = false
        loaderDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(AppConfig.loaderFadeDuration * 1000)))
            guard !Task.isCancelled else { return }
            loaderMounted = false
        }
    }

    // MARK: - Review Notification Banner

    private var reviewBanner: some View {
        Button {
            dismissReviewBanner()
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.currentView = .upload
        } label: {
            HStack(spacing: 6) {
                AppIcon(glyph: .check, size: 12, color: AppPalette.uploadGlow)
                Text("Your fit is ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.uploadGlow)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .appCapsule()
            .shadow(color: AppPalette.uploadGlow.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.top, 54)
        .scaleEffect(showReviewBanner ? 1 : 0.85)
    }

    private func presentReviewBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showReviewBanner = true
        }
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismissReviewBanner()
        }
    }

    private func dismissReviewBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
            showReviewBanner = false
        }
    }

    private var backgroundColor: Color {
        store.currentView == .feed ? AppPalette.groupedBackground : AppPalette.pageBackground
    }
}

private struct UploadTabIconView: View {
    let isActive: Bool
    let isAnimating: Bool
    let progress: Double

    var body: some View {
        ZStack {
            if isAnimating {
                ZStack {
                    // Outer halo — wide soft diffuse glow
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(AppPalette.uploadGlow.opacity(0.18), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .blur(radius: 5)
                        .rotationEffect(.degrees(-90))

                    // Mid glow
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(AppPalette.uploadGlow.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .blur(radius: 1.5)
                        .rotationEffect(.degrees(-90))

                    // Soft white core
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                        .blur(radius: 0.2)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 1.2, y: 0)
                }
                .frame(width: 36, height: 36)
                .animation(.easeInOut(duration: 1.1), value: progress)
            }

            AppIcon(
                glyph: .plusCircle,
                size: 26,
                color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
            )
            .frame(width: 36, height: 36)
        }
    }
}

private struct FavoritesSheetView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var favoriteOutfits: [Outfit] {
        store.sortedOutfits.filter { store.likedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.medium) {
                    Text("Your liked outfits live here.")
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)

                    if favoriteOutfits.isEmpty {
                        VStack(spacing: LayoutMetrics.small) {
                            AppIcon(
                                glyph: .heart,
                                size: 18,
                                color: AppPalette.textMuted.opacity(0.92)
                            )
                                .frame(width: 48, height: 48)
                                .appCircle(shadowRadius: 0, shadowY: 0)

                            Text("No favorites yet")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)

                            Text("Tap the heart on an outfit and it will show up here.")
                                .font(.system(size: 12))
                                .foregroundStyle(AppPalette.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LayoutMetrics.xLarge)
                    } else {
                        LazyVStack(spacing: LayoutMetrics.small) {
                            ForEach(favoriteOutfits) { outfit in
                                favoriteOutfitRow(outfit)
                            }
                        }
                    }
                }
                .padding(LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.large)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppPalette.groupedBackground)
    }

    private func favoriteOutfitRow(_ outfit: Outfit) -> some View {
        HStack(spacing: LayoutMetrics.small) {
            RotatableOutfitImage(
                outfit: outfit,
                height: 126,
                eagerLoad: true
            )
            .frame(width: 94)

            VStack(alignment: .leading, spacing: 6) {
                Text(outfit.fullDateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                if let weather = outfit.weather {
                    WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
                }

                if let tags = outfit.tags, tags.isEmpty == false {
                    Text(tags.prefix(3).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppPalette.textMuted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.small)
        .appCard(cornerRadius: 20, shadowRadius: 0, shadowY: 0)
    }
}

#Preview {
    RootView()
        .environment(OutfitStore())
}

import SwiftUI
import Lottie

struct RootView: View {
    @Environment(OutfitStore.self) private var store

    private let headerContentInset: CGFloat = 0

    /// Shared namespace for matchedGeometryEffect cross-view transitions.
    @Namespace private var listCalendarNamespace

    @State private var loaderMounted = true
    @State private var loaderVisible = true
    @State private var loaderDismissTask: Task<Void, Never>?
    @State private var showsFavoritesSheet = false
    @State private var showsVirtualCloset = false
    @State private var showsAvatarOnboarding = false
    /// Profile-as-home: the gear button on the right of the top bar
    /// presents the full ProfileView (theme toggles, follow stats,
    /// edit fields, sign out, Virtual Closet entry, etc.) in a sheet
    /// instead of taking a tab slot of its own.
    @State private var showsSettingsSheet = false
    /// Stub flag for the "add me on Yafa" share button. UI surface
    /// only for now — share-content rendering is a separate task.
    @State private var showsShareProfileSheet = false
    /// Standardized closet avatar. Hydrated from disk on appear so a returning
    /// user doesn't have to redo onboarding. Cross-device sync via Supabase
    /// Storage is a follow-up.
    @State private var closetAvatar: UIImage?
    @State private var hydratedAvatarForUserId: UUID?
    @State private var feedHasAppeared = false

    /// Drives the floating picker (camera roll + camera squares
    /// above the tab bar). Tapping the upload tab toggles this
    /// instead of navigating to a separate page.
    @State private var showGenerationPicker = false

    /// Job id of the currently expanded card. Non-nil = card is
    /// mounted. Goes nil only after the dismiss morph completes
    /// (via `withAnimation` completion callback) so the morphing
    /// view stays in the tree throughout the animation.
    @State private var expandedJobId: String?

    /// Drives the morph between pill-shape (false) and card-shape
    /// (true). Flipped inside `withAnimation` after the card mounts
    /// — that's what the card's `.frame + .position + .clipShape`
    /// interpolate against.
    @State private var isCardExpanded: Bool = false

    /// Bottom-relative index of the tapped pill (0 = bottom/newest,
    /// 1 = above it, etc). The card uses this to compute the
    /// pill-state rect at the correct Y, so the morph appears to
    /// originate from the *specific* pill the user tapped — not
    /// just the bottom of the stack.
    @State private var expandedPillIndex: Int = 0

    /// Cold-path expand defers the morph one runloop tick so the
    /// card has a chance to mount at pill rect before .frame /
    /// .position start interpolating. Held in @State so a rapid
    /// tap → dismiss can cancel it before it fires (otherwise
    /// the card jumps open right as the user's closing it).
    @State private var morphPrepTask: Task<Void, Never>?

    /// Captured reference to the currently-expanded job. The card
    /// renders off this rather than looking up `expandedJobId` in
    /// the queue, so when the job is cancelled (and removed from
    /// the queue async, outside any `withAnimation` block) the
    /// card stays mounted until the dismiss completion explicitly
    /// clears it. Without this, the queue-side removal snaps the
    /// card off mid-morph via the `job(withId:)` lookup failing.
    @State private var expandedJob: PipelineJob?


    /// When the queue has 2+ jobs, the pill stack defaults to a
    /// collapsed "chip" form (`GenerationChipPill`) showing
    /// overlapping thumbnails + count. Tapping the chip flips
    /// this true and the chip explodes into the full
    /// `GenerationPillStack`. Opening a card flips it false so
    /// the stack re-collapses into the chip behind the card —
    /// the card + chip are the two visible elements in card
    /// state, never the full stack. Swiping the card down or
    /// tapping the chip flips it true again on the way back.
    @State private var isChipExpanded: Bool = false

    /// Shared namespace for the chip ↔ stack matched-geometry
    /// pairing. The bottom pill in the stack and the chip claim
    /// the same `"compact-pill"` id so their frames morph into
    /// each other rather than crossfading. Each pill's thumbnail
    /// and the chip's corresponding thumbnail are also paired by
    /// `"thumb-<jobId>"`, so upper pills' thumbs fly into the
    /// chip's thumbnail slots on collapse (and back out on
    /// expand).
    @Namespace private var pillsNamespace


    /// Per-view opacities for the list↔calendar crossfade. Both views
    /// stay mounted in a ZStack; opacity controls which is visible.
    @State private var listOpacity: Double = 1
    @State private var calendarOpacity: Double = 0

    /// Drives the list↔calendar transition end-to-end: pre-scrolls the
    /// destination to the anchor, runs the animated swap, then clears
    /// `transitionAnchorOutfitId` once the morph settles. Held in
    /// @State so rapid taps cancel the in-flight task cleanly.
    @State private var transitionTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        ZStack(alignment: .top) {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                switch store.currentView {
                case .list, .calendar:
                    // Both views stay mounted simultaneously; opacity
                    // controls which one is visible. Keeping both in
                    // the hierarchy preserves their scroll positions
                    // and lets `matchedGeometryEffect` connect the
                    // anchor cells across the two layouts.
                    ZStack {
                        OutfitGridView(
                            transitionNamespace: listCalendarNamespace,
                            onToggleToCalendar: { switchView(to: .calendar) },
                            onExpandGenerationJob: { job in expandPill(job: job) },
                            onScrollBegan: { dismissOverlaysOnScroll() }
                        )
                            .opacity(listOpacity)
                            .allowsHitTesting(store.currentView == .list)
                        CalendarMonthView(
                            transitionNamespace: listCalendarNamespace,
                            onExpandGenerationJob: { job in expandPill(job: job) },
                            onScrollBegan: { dismissOverlaysOnScroll() }
                        )
                            .opacity(calendarOpacity)
                            .allowsHitTesting(store.currentView == .calendar)
                    }
                case .upload:
                    // Dead branch — the upload tab no longer routes
                    // to a navigation target; tapping it opens the
                    // floating `GenerationPicker` above the tab
                    // bar. Kept for the `AppView` enum exhaustiveness.
                    EmptyView()
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

            // Floating camera-roll / camera picker — sits above the
            // tab bar with a tap-outside scrim.
            if showGenerationPicker {
                GenerationPicker(
                    isPresented: $showGenerationPicker,
                    onImagePicked: handlePickedImage
                )
                .zIndex(600)
            }

            // Tap-outside backdrop for the expanded chip stack OR
            // expanded card. Lives at the outer ZStack level so it
            // stays full-screen regardless of the card's
            // interpolated frame. Visible whenever the stack is
            // exploded (chip → pills) or the card is open;
            // tapping it fully collapses everything back to the
            // chip — distinct from swipe-down or tap-chip which
            // both go through `returnCardToStack` and only undo
            // one level at a time.
            if isChipExpanded || isCardExpanded {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { fullyCollapse() }
                    .transition(.opacity)
                    .zIndex(605)
            }

            // Generation expanded card. Mounted whenever
            // `expandedJob` is set; unmounted after dismiss
            // animation completes. Morph state driven by
            // `isCardExpanded`.
            if let job = expandedJob {
                // Chip is hidden when there's only one job in the
                // queue (the one being expanded). With >1 job the
                // chip stays visible behind the card as a queue
                // indicator — so the card needs to know whether
                // there's a chip below to anchor against, or
                // whether to center in the viewport.
                let totalJobs = store.generationQueue.activeJobs.count + store.generationQueue.waitingJobs.count
                GenerationExpandedCard(
                    job: job,
                    phase: store.generationQueue.phase(for: job),
                    isExpanded: isCardExpanded,
                    pillIndexFromBottom: expandedPillIndex,
                    hasChipBehind: totalJobs > 1,
                    onCancel: {
                        // Dismiss the card first, then cancel the
                        // orchestrator + remove the job from the
                        // queue after the morph has settled. The
                        // delay keeps the chip behind visible
                        // throughout the morph so the snap unmount
                        // lands on matching chrome (instead of an
                        // empty space when the queue suddenly
                        // empties mid-morph).
                        returnCardToStack()
                        store.generationOrchestrator.cancel(job)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            await store.generationQueue.cancel(job)
                        }
                    },
                    onSave2D: {
                        returnCardToStack()
                        store.generationOrchestrator.saveAs2D(job)
                    },
                    onMake3D: {
                        // Don't dismiss — the user wants to stay
                        // on the card to watch the 3D render. The
                        // orchestrator advances the job's phase,
                        // which flips the card's content from
                        // `decisionContent` to `inProgressContent`
                        // (rendering3D) automatically.
                        store.generationOrchestrator.make3D(job)
                    },
                    onAccept: {
                        returnCardToStack()
                        store.generationOrchestrator.accept(job)
                    },
                    onAcceptAndPublish: {
                        returnCardToStack()
                        store.generationOrchestrator.acceptAndPublish(job)
                    },
                    onRetake: {
                        store.generationOrchestrator.retake(job)
                    },
                    onReverseRotation: {
                        // Toggle on the job AND mirror to the
                        // staged outfit so `RotatableOutfitImage`
                        // (which reads from the outfit) actually
                        // reverses. Just toggling the job had no
                        // visible effect.
                        guard var staged = job.stagedOutfit else { return }
                        let newValue = !job.isRotationReversed
                        job.isRotationReversed = newValue
                        staged.isRotationReversed = newValue
                        job.stagedOutfit = staged
                    },
                    // Swipe-down: card → pill in stack. Different
                    // from tapping the backdrop, which goes all
                    // the way to the chip via `fullyCollapse`.
                    onDismiss: { returnCardToStack() }
                )
                .zIndex(610)
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Pill area + tab bar live in the safe-area inset.
            // The pill area is wrapped in a *fixed-height* slot
            // (`Color.clear.frame(height: 52)`) so the inset
            // doesn't reflow when the chip toggles between
            // collapsed (52pt) and expanded stack (52-164pt).
            // Anything anchored to the safe area (the floating
            // bookmark button, the bottom gradient) used to
            // bounce up and down on every chip ↔ stack swap;
            // with the slot pinned, the inset height stays
            // constant and the expanded stack extends *upward*
            // over the main content via `.overlay(alignment:
            // .bottom)` — it overlays the grid rather than
            // pushing the safe area up.
            let hasJobs = !store.generationQueue.activeJobs.isEmpty
                || !store.generationQueue.waitingJobs.isEmpty
            VStack(spacing: LayoutMetrics.xxSmall) {
                if hasJobs {
                    Color.clear
                        .frame(height: 52)
                        .overlay(alignment: .bottom) {
                            pillsArea
                        }
                        // Scale + opacity removal so the chip / pill
                        // inside the slot softly shrinks and fades
                        // as the last job leaves the queue — no
                        // hard cut. Anchored .bottom so the shrink
                        // collapses toward the tab bar, mirroring
                        // the slot's bottom-aligned overlay.
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity)
                            )
                        )
                }
                tabBar
            }
            // Animate the inset's 1 ↔ 0 jobs reflow. Without
            // this, canceling the last in-flight job (where the
            // queue update lands async, outside any withAnimation
            // block) would snap the safe-area inset's height —
            // and everything anchored to the safe area (the
            // bookmark button, the bottom gradient) along with it.
            // Scoped to `hasJobs` so other state changes inside
            // the VStack (chip ↔ stack swap, opacity toggles)
            // run on their own curves.
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasJobs)
            .opacity(store.isCarouselOpen ? 0 : 1)
            .allowsHitTesting(!store.isCarouselOpen)
        }
        // Has to sit AFTER `.safeAreaInset(.bottom)` — applied
        // before it, the inset re-wraps the view and re-introduces
        // keyboard avoidance (the inset's tab-bar content wants to
        // stay above the keyboard, which pulls the whole content
        // up). Applied after, this modifier opts out everything
        // including the inset, so the carousel detail card stays
        // anchored when its location/tag TextFields gain focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onAppear {
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
        .onDisappear {
            loaderDismissTask?.cancel()
            transitionTask?.cancel()
            morphPrepTask?.cancel()
        }
        .sheet(isPresented: $showsFavoritesSheet) {
            FavoritesSheetView()
                .environment(store)
        }
        .sheet(isPresented: $showsSettingsSheet) {
            // The full settings/profile screen — theme toggles, follow
            // stats, profile editing, Virtual Closet, sign out. Lives
            // here as a sheet now that Profile is no longer a tab.
            NavigationStack {
                ProfileView()
                    .environment(store)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsSettingsSheet = false }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppPalette.textPrimary)
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsShareProfileSheet) {
            // Placeholder for the "add me on Yafa" flow. Surface only
            // — actual share content (card render, deep link, copy) is
            // a separate task.
            NavigationStack {
                VStack(spacing: LayoutMetrics.medium) {
                    Text("Share your profile")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Coming soon — a shareable card so people can find you on Yafa.")
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LayoutMetrics.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppPalette.groupedBackground)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showsShareProfileSheet = false }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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

    /// Picker callback. Encodes the selected `UIImage` to JPEG data
    /// and enqueues a new generation. Weather + location are stamped
    /// later by `RealGenerationOrchestrator` via `UploadWeatherService`.
    private func handlePickedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 1) else { return }

        // Take the user to where the new placeholder will appear.
        // If on Calendar, swap to the index first; if on Feed,
        // Profile, etc., the user is on the relevant surface
        // already (the placeholder lives in the archive grid).
        // Leave non-archive surfaces alone — the brief said only
        // the index/calendar should be affected.
        if store.currentView == .calendar {
            switchView(to: .list)
        }
        // Wrap enqueue in withAnimation so the chip's first
        // appearance (queue going from empty to 1 job, which
        // triggers both the safe-area inset's slot to appear and
        // the chip's `.transition(.opacity)` to fade in) is
        // smooth. Without this, the enqueue lands as a bare
        // synchronous state change and the chip pops in with a
        // hard cut even though the chip view itself has a
        // transition modifier.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            store.generationQueue.enqueue(
                sourceImage: data,
                weather: nil,
                location: nil
            )
        }
        // Scroll to top so the new placeholder is in view. Slight
        // delay so the placeholder is mounted before the scroll
        // command fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            store.archiveScrollToTopTrigger += 1
        }
    }

    /// Single morph curve for everything — open, close, chip ↔
    /// stack reflow, backdrop fade. This curve (response 0.3,
    /// damping 0.78) was the "snappy + a bit of spring" config
    /// that felt right.
    /// Spring curve the user explicitly preferred earlier in
    /// development — "ok nicer!!" with response 0.3, damping
    /// 0.78. Has a tiny natural bounce that reads as fluid rather
    /// than mechanical. The shorter `.snappy` / `.smooth` curves
    /// we tried later felt clipped.
    private static let cardMorphAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.78)

    /// Chip ↔ stack conditional. The chip is the default
    /// "minimized" form and handles 1+ jobs — for 1 job it
    /// renders like a single pill (one thumb + status text), and
    /// for 2+ it grows additional thumbnails and switches to
    /// `+N` once the count exceeds 3. The stack only renders
    /// when the user explicitly expands the chip (or has a card
    /// open via the warm path). Both branches participate in
    /// the shared `pillsNamespace` matched-geometry pairing so
    /// chip ↔ stack morphs frames rather than crossfading.
    @ViewBuilder
    private var pillsArea: some View {
        let jobs = store.generationQueue.activeJobs + store.generationQueue.waitingJobs
        Group {
            if jobs.isEmpty {
                EmptyView()
            } else if isChipExpanded && jobs.count >= 2 {
                GenerationPillStack(
                    queue: store.generationQueue,
                    expandedJobId: expandedJobId,
                    isCardExpanded: isCardExpanded,
                    namespace: pillsNamespace
                ) { job in
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    expandPill(job: job)
                }
                // Fade-only transition: the matched-geometry on the
                // bottom pill ↔ chip handles the frame morph, and
                // the per-thumbnail matched-geometry handles thumb
                // movement. .opacity is the residual fade for the
                // rest of the pill chrome / upper pills which have
                // no chip counterpart.
                .transition(.opacity)
            } else {
                GenerationChipPill(
                    jobs: jobs,
                    queue: store.generationQueue,
                    namespace: pillsNamespace,
                    isHostingExpandedCard: expandedJobId != nil
                ) {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    handleChipTap(jobs: jobs)
                }
                // Scale + opacity so the chip softly shrinks out
                // when the last job completes / is cancelled,
                // instead of cutting away.
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private func expandPill(job: PipelineJob) {
        let all = store.generationQueue.activeJobs + store.generationQueue.waitingJobs
        let newPillIndex: Int
        if let arrayIndex = all.firstIndex(where: { $0.id == job.id }) {
            newPillIndex = all.count - 1 - arrayIndex
        } else {
            newPillIndex = 0
        }

        // Warm path — a card is already mounted (currently
        // expanded, mid-expand, or mid-dismiss). Swap content +
        // target in one withAnimation so we never race a stale
        // dismiss completion against the new expand. The card
        // re-renders with the new job's content and morphs to
        // card state in the same gesture.
        if expandedJobId != nil {
            morphPrepTask?.cancel()
            withAnimation(Self.cardMorphAnimation) {
                expandedJob = job
                expandedJobId = job.id
                expandedPillIndex = newPillIndex
                isCardExpanded = true
                isChipExpanded = false
            }
            return
        }

        // Cold path — mount card at pill rect sync, then schedule
        // the morph on the next runloop tick. The chip-collapse
        // (isChipExpanded = false) happens inside the same
        // withAnimation as the card morph so the stack folds back
        // into the chip in lockstep with the pill growing into
        // the card. Held in a cancellable Task so a rapid tap →
        // dismiss before the morph fires kills it cleanly.
        expandedJob = job
        expandedJobId = job.id
        expandedPillIndex = newPillIndex
        morphPrepTask?.cancel()
        morphPrepTask = Task { @MainActor in
            // 1-frame sleep (16ms) rather than `Task.yield()` —
            // yield wasn't reliable enough to guarantee SwiftUI
            // had rendered the pill-rect mount before the morph
            // started, and the card sometimes appeared at card
            // state directly with no morph visible.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, expandedJobId == job.id else { return }
            withAnimation(Self.cardMorphAnimation) {
                isCardExpanded = true
                isChipExpanded = false
            }
        }
    }

    /// Chip tap dispatch. Three cases:
    /// - Card open → behaves like swipe-down: card morphs back
    ///   to its pill and the chip explodes into the stack.
    /// - Single job in the queue → skip the stack-of-one and
    ///   open that job's card directly. There's nothing to
    ///   "expand into" when there's only one pill.
    /// - 2+ jobs → expand the chip into the full stack.
    /// Called by the grid (and other scrollable surfaces) when the
    /// user starts scrolling. Collapses an open generation card /
    /// picker / expanded stack so they don't block the content the
    /// user is reaching for — no need to tap out first.
    private func dismissOverlaysOnScroll() {
        if expandedJobId != nil {
            returnCardToStack()
            return
        }
        if showGenerationPicker {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                showGenerationPicker = false
            }
            return
        }
        if isChipExpanded {
            withAnimation(Self.cardMorphAnimation) {
                isChipExpanded = false
            }
        }
    }

    private func handleChipTap(jobs: [PipelineJob]) {
        // Picker and chip-driven UI share the same slot above the
        // tab bar — chip taps always dismiss the picker first.
        if showGenerationPicker {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                showGenerationPicker = false
            }
        }
        if expandedJobId != nil {
            returnCardToStack()
        } else if jobs.count == 1, let job = jobs.first {
            expandPill(job: job)
        } else {
            withAnimation(Self.cardMorphAnimation) {
                isChipExpanded = true
            }
        }
    }

    /// Card → pill-in-stack. Morph back to pill rect via
    /// `withAnimation`, then snap the unmount in the completion
    /// handler. Snap is invisible when there's a chip / real pill
    /// behind with matching chrome (the common case). For the
    /// cancel-last-job edge case the card just disappears at the
    /// end of the morph — handled separately by delaying the
    /// queue.remove in `onCancel`.
    ///
    /// `isChipExpanded` flips true only when 2+ jobs remain. For
    /// 1 job there's no stack to return to — the chip *is* the
    /// stack of one — so we stay in chip mode.
    private func returnCardToStack() {
        morphPrepTask?.cancel()
        let jobBeingDismissed = expandedJobId
        let jobsCount = store.generationQueue.activeJobs.count
            + store.generationQueue.waitingJobs.count
        withAnimation(Self.cardMorphAnimation) {
            isCardExpanded = false
            isChipExpanded = jobsCount >= 2
        } completion: {
            guard expandedJobId == jobBeingDismissed, !isCardExpanded else { return }
            expandedJob = nil
            expandedJobId = nil
        }
    }

    /// Card and/or stack → chip. The user's "harder" dismiss:
    /// tap anywhere outside both. Card morphs back to its pill
    /// rect and the stack folds into the chip in one motion;
    /// if only the stack was open (no card), just the chip
    /// re-collapse runs.
    ///
    /// `expandedPillIndex = 0` retargets the card's morph back
    /// to the bottom slot — the chip's position. Without this,
    /// the card would morph back to whichever slot it came from
    /// (potentially 2-3 slots above the chip), unmount in empty
    /// space, and the chip would still be sitting at slot 0
    /// below. The retarget makes the card visually "merge into"
    /// the chip.
    private func fullyCollapse() {
        morphPrepTask?.cancel()
        let jobBeingDismissed = expandedJobId
        withAnimation(Self.cardMorphAnimation) {
            isCardExpanded = false
            isChipExpanded = false
            if expandedJobId != nil {
                expandedPillIndex = 0
            }
        } completion: {
            guard expandedJobId == jobBeingDismissed, !isCardExpanded else { return }
            expandedJob = nil
            expandedJobId = nil
        }
    }

    private var topBar: some View {
        HStack {
            // When the carousel is open, the logo is replaced by an
            // X that dismisses the carousel — the entire screen
            // belongs to the outfit detail in that mode. Once the
            // user enters edit mode, the card grows taller and the
            // keyboard can push it over this strip, so we hide the
            // X and temp toggle then. The resting expanded card
            // sits below them — they stay visible.
            if store.isCarouselOpen {
                carouselDismissButton
                    .opacity(store.isCarouselCardEditing ? 0 : 1)
                    .allowsHitTesting(!store.isCarouselCardEditing)
            } else {
                logoView
            }
            Spacer()
            HStack(spacing: 8) {
                if store.currentView == .list || store.currentView == .calendar {
                    if store.isCarouselOpen {
                        tempToggle
                            .opacity(store.isCarouselCardEditing ? 0 : 1)
                            .allowsHitTesting(!store.isCarouselCardEditing)
                    } else if store.currentView == .calendar {
                        // On calendar, the grid/calendar toggle takes
                        // the spot that settings + share occupy on
                        // grid view. The profile header isn't shown
                        // here so the toggle has no in-page home.
                        ViewModeTogglePill(isCalendarActive: true) {
                            switchView(to: .list)
                        }
                        .padding(.trailing, 8)
                    } else if store.archiveTogglePinned {
                        // The in-page section toggle has scrolled up
                        // to the top-bar level — swap share + settings
                        // for the toggle so it appears to pin in
                        // place. The in-page copy fades out via the
                        // same flag so it doesn't render twice.
                        ViewModeTogglePill(isCalendarActive: false) {
                            switchView(to: .calendar)
                        }
                        .padding(.trailing, 8)
                        .transition(.opacity)
                    } else {
                        shareProfileButton
                        settingsButton
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: store.archiveTogglePinned)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
        .contentShape(Rectangle())
    }

    /// Gear icon on the top-right of the profile-home view. Opens the
    /// existing `ProfileView` in a sheet so theme toggles, follow
    /// stats, profile editing, Virtual Closet entry, and sign-out
    /// live there instead of a dedicated tab. Uses SF Symbol `gearshape`
    /// directly — AppIcon has no gear glyph and adding one for a
    /// single use site isn't worth the path code.
    private var settingsButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showsSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.iconPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98)))
                .overlay(Circle().stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    /// "Add me on Yafa" share entry point. The actual share content
    /// (card render, copy, deep link) is out of scope for this pass —
    /// the button just opens a placeholder share sheet so the surface
    /// area is wired up for follow-on work.
    private var shareProfileButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showsShareProfileSheet = true
        } label: {
            AppIcon(glyph: .share, size: 14, color: AppPalette.iconPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98)))
                .overlay(Circle().stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    /// Loads the persisted avatar for the current user if we haven't already
    /// hydrated for that ID this session. Returning users skip onboarding.
    /// The Virtual Closet itself is now reached via the settings sheet
    /// rather than a dedicated top-bar button, but the underlying
    /// state and storage hooks are kept so a settings-row entry can be
    /// wired up in a follow-up without re-doing the lifecycle plumbing.
    private func hydrateClosetAvatarIfNeeded() {
        guard let userId = store.userId, hydratedAvatarForUserId != userId else { return }
        hydratedAvatarForUserId = userId
        if let stored = ClosetAvatarStorage.load(userId: userId) {
            closetAvatar = stored
        }
    }

    // MARK: - List ↔ Calendar transition (matchedGeometryEffect-driven)

    private enum Transition {
        /// `withAnimation` curve. Subtle settle, no overshoot.
        static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// Phase 1 — wait this long for the destination's scroll task
        /// to clear its `pendingScrollOutfitId` flag.
        static let scrollWaitTimeout: TimeInterval = 0.4
        /// Phase 2 — wait this long for the destination cell's frame
        /// to be on-screen and stable across two consecutive samples.
        static let stabilityPollTimeout: TimeInterval = 0.3
        /// Render-cycle granularity for both polling loops (~60Hz).
        static let pollInterval = Duration.milliseconds(16)
        /// One extra render cycle after Phase 2 succeeds, so the
        /// final layout commit makes it through before withAnimation.
        static let postPollSettle = Duration.milliseconds(32)
        /// Fallback wait when there's no anchor (no visible outfit).
        /// Gives the destination a beat to lay out initial content.
        static let noAnchorSettle = Duration.milliseconds(80)
        /// Tail wait after the spring kicks off, before clearing
        /// `transitionAnchorOutfitId`. Lets the spring fully settle
        /// so matchedGeometryEffect doesn't get yanked mid-morph.
        static let postSpringSettle = Duration.milliseconds(550)
    }

    private func switchView(to target: AppView) {
        guard target == .list || target == .calendar else { return }
        let goingToCalendar = target == .calendar
        let sourceFrames = goingToCalendar ? store.listOutfitFrames : store.calendarOutfitFrames
        let anchorId = mostCenteredOutfitId(in: sourceFrames)

        store.selectedOutfitId = nil
        store.transitionAnchorOutfitId = anchorId
        // Capture the source anchor's currently-displayed frame so
        // the destination anchor can render the same frame during
        // the morph. Independent of any persistent scrub state.
        store.transitionAnchorFrameIndex = anchorId.flatMap {
            store.currentDisplayedFrame[$0]
        }
        if let anchorId {
            if goingToCalendar {
                store.pendingCalendarScrollOutfitId = anchorId
            } else {
                store.pendingListScrollOutfitId = anchorId
            }
        }

        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            if let anchorId {
                await waitForDestinationScroll(goingToCalendar: goingToCalendar)
                if Task.isCancelled { return }

                let foundValidTarget = await waitForStableDestinationFrame(
                    anchorId: anchorId,
                    goingToCalendar: goingToCalendar
                )
                if Task.isCancelled { return }

                if !foundValidTarget {
                    // Polling never observed a valid on-screen frame —
                    // destination scroll genuinely failed. Drop the
                    // anchor so the morph degrades to a clean opacity
                    // crossfade instead of jumping somewhere wrong.
                    store.transitionAnchorOutfitId = nil
                }
                try? await Task.sleep(for: Transition.postPollSettle)
            } else {
                try? await Task.sleep(for: Transition.noAnchorSettle)
            }
            guard !Task.isCancelled else { return }

            withAnimation(Transition.spring) {
                store.currentView = target
                listOpacity = goingToCalendar ? 0 : 1
                calendarOpacity = goingToCalendar ? 1 : 0
            }

            try? await Task.sleep(for: Transition.postSpringSettle)
            guard !Task.isCancelled else { return }
            store.transitionAnchorOutfitId = nil
            store.transitionAnchorFrameIndex = nil
        }
    }

    /// Picks the outfit whose frame is closest to the screen center
    /// among those currently intersecting the viewport. Returns `nil`
    /// if no outfit is visible (e.g., scrolled past everything).
    private func mostCenteredOutfitId(in frames: [String: CGRect]) -> String? {
        let viewport = UIScreen.main.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        return frames
            .filter { _, frame in frame.intersects(viewport) && frame.width > 0 }
            .min { lhs, rhs in
                let ld = squaredDistance(from: CGPoint(x: lhs.value.midX, y: lhs.value.midY), to: center)
                let rd = squaredDistance(from: CGPoint(x: rhs.value.midX, y: rhs.value.midY), to: center)
                return ld < rd
            }?.key
    }

    private func squaredDistance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// Phase 1 of the transition wait. Polls until the destination
    /// view's `pendingScrollOutfitId` flag is cleared by its scroll
    /// task, or 400ms elapses. Without this, we'd start the morph
    /// before the destination has actually scrolled — and capture a
    /// stale (pre-scroll) frame as the morph target.
    @MainActor
    private func waitForDestinationScroll(goingToCalendar: Bool) async {
        let deadline = Date().addingTimeInterval(Transition.scrollWaitTimeout)
        while Date() < deadline {
            let stillPending = goingToCalendar
                ? (store.pendingCalendarScrollOutfitId != nil)
                : (store.pendingListScrollOutfitId != nil)
            if !stillPending { return }
            try? await Task.sleep(for: Transition.pollInterval)
            if Task.isCancelled { return }
        }
    }

    /// Phase 2 of the transition wait. Polls the destination cell's
    /// frame until it's on-screen with non-zero size AND has been
    /// stable across two consecutive 16ms samples. Returns whether a
    /// stable frame was actually observed within 300ms.
    @MainActor
    private func waitForStableDestinationFrame(
        anchorId: String,
        goingToCalendar: Bool
    ) async -> Bool {
        let viewport = UIScreen.main.bounds
        let pollStart = Date()
        var lastFrame: CGRect?
        while Date().timeIntervalSince(pollStart) < Transition.stabilityPollTimeout {
            let frames = goingToCalendar ? store.calendarOutfitFrames : store.listOutfitFrames
            if let frame = frames[anchorId],
               frame.width > 0, frame.height > 0,
               frame.intersects(viewport) {
                if let last = lastFrame,
                   abs(last.minX - frame.minX) < 0.5,
                   abs(last.minY - frame.minY) < 0.5 {
                    return true
                }
                lastFrame = frame
            }
            try? await Task.sleep(for: Transition.pollInterval)
            if Task.isCancelled { return false }
        }
        return false
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

    /// X button shown in the top-left while the carousel is open
    /// (replaces the Yafa logo). Always dismisses the carousel —
    /// even if the detail card inside it is currently expanded —
    /// by bumping `carouselDismissTrigger`, which the host view
    /// (OutfitGridView / UserProfileView) observes.
    private var carouselDismissButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.carouselDismissTrigger += 1
        } label: {
            AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                .frame(width: 36, height: 36)
                .appCircle()
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }


    private var tabBar: some View {
        HStack(spacing: 0) {
                // Profile is now the home tab — the index/archive view
                // doubles as the user's profile (avatar + bio + grid).
                // The standalone ProfileView is reached via a settings
                // sheet from inside this tab, not from the tab bar.
                tabItem(icon: .person, iconSize: 22, label: "Profile", tab: .list)
                tabItem(icon: .plusCircle, iconSize: 26, label: "Upload", tab: .upload)
                tabItem(icon: .globe, iconSize: 24, label: "Public", tab: .feed)
            }
            .padding(.horizontal, LayoutMetrics.small)
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
            // Cap the pill width and center it. The previous 4-tab
            // layout used the full screen-minus-padding; with only 3
            // tabs that left huge gaps between icons. A maxWidth cap
            // pulls the icons closer together regardless of device
            // size, and the inner xxSmall padding keeps the icons
            // visually balanced inside the pill.
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            .padding(.bottom, LayoutMetrics.xxSmall)
    }

    private func tabItem(icon: AppIconGlyph, iconSize: CGFloat = 24, label: String, tab: AppView) -> some View {
        let isActive = store.currentView == tab || (tab == .list && store.currentView == .calendar)
        // Count any active or waiting generations from the queue.
        // Drives the upload tab icon's glow ring and the small
        // badge bubble in the corner.
        let inFlightGenerations = store.generationQueue.inFlightCount
        let showsUploadActivity = tab == .upload && inFlightGenerations > 0
        return Button {
            // Upload tab is no longer a navigation target — it's an
            // action that opens the floating picker above the tab
            // bar. Skip the normal currentView routing entirely.
            if tab == .upload {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                // Minimize any open card back to its pill first —
                // the picker buttons (camera / camera roll) sit
                // just above the pill area, and a card on screen
                // would cover them. `returnCardToStack` runs the
                // card morph on its own animation curve; the
                // picker toggle's spring runs in parallel.
                if expandedJobId != nil {
                    returnCardToStack()
                }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    showGenerationPicker.toggle()
                    // When the picker opens, collapse any expanded
                    // stack back to the chip — the picker buttons
                    // sit just above the pill area, and a tall
                    // stack would push them up or overlap. The
                    // chip is a constant 52pt slot so the picker
                    // has a stable visual anchor.
                    if showGenerationPicker {
                        isChipExpanded = false
                    }
                }
                return
            }

            let targetTab = (tab == .list && store.currentView == .calendar) ? AppView.list : tab
            // The Profile tab counts as "active" in both `.list` and
            // `.calendar` (its icon highlights for either), so the
            // back-to-top short-circuit triggers on a re-tap from
            // either of those — not just the literal currentView
            // match. From calendar, that also includes snapping
            // back to the list layer so the user lands on the
            // archive at the top.
            let isProfileTabActive = tab == .list && (store.currentView == .list || store.currentView == .calendar)
            if store.currentView == targetTab || isProfileTabActive {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                if tab == .feed {
                    store.feedScrollToTopTrigger += 1
                } else if tab == .list {
                    if store.currentView == .calendar {
                        // Snap (no morph) — the user's intent is
                        // "go home and scroll up", not a list↔calendar
                        // swap. Match the opacity layers so the list
                        // is the visible one on arrival.
                        store.selectedOutfitId = nil
                        listOpacity = 1
                        calendarOpacity = 0
                        store.currentView = .list
                    }
                    store.archiveScrollToTopTrigger += 1
                }
                return
            }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()

            store.selectedOutfitId = nil
            // List↔calendar transitions need to go through `switchView`
            // so the opacity crossfade (and the matchedGeometryEffect
            // morph) runs. Setting `currentView` alone leaves the
            // per-view opacities stale, which is why tapping Home
            // from calendar would flip the toggle but leave the
            // calendar visible underneath.
            let isListCalendarSwitch =
                (store.currentView == .calendar && targetTab == .list) ||
                (store.currentView == .list && targetTab == .calendar)
            if isListCalendarSwitch {
                switchView(to: targetTab)
            } else {
                // When the target is list or calendar but we got here
                // from a different section (upload/feed/profile), the
                // per-view opacities may still hold their last
                // list↔calendar values. Snap them so the right layer
                // is visible (and hit-testable) on arrival — otherwise
                // returning to Home from upload while the last visit
                // was Calendar leaves the calendar covering the list.
                if targetTab == .list {
                    listOpacity = 1
                    calendarOpacity = 0
                } else if targetTab == .calendar {
                    listOpacity = 0
                    calendarOpacity = 1
                }
                store.currentView = targetTab
            }
        } label: {
            VStack(spacing: LayoutMetrics.xxxSmall) {
                ZStack(alignment: .topTrailing) {
                    if tab == .upload {
                        UploadTabIconView(
                            isActive: isActive,
                            isAnimating: showsUploadActivity,
                            progress: store.generationQueue.aggregateUploadProgress
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
                        Text("\(max(inFlightGenerations, 1))")
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
                            .contentTransition(.numericText(value: Double(inFlightGenerations)))
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
                    glyph: .bookmark,
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

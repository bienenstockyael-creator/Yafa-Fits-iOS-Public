import SwiftUI
import UIKit

struct OutfitGridView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// Cross-view transition namespace passed in from RootView.
    var transitionNamespace: Namespace.ID

    /// Fired when the user taps the calendar icon in the section
    /// header row. RootView wires this to its `switchView(to:)` so
    /// the existing matchedGeometry transition still drives the swap.
    var onToggleToCalendar: () -> Void = {}

    /// Tap on a generation placeholder card (a job that's in
    /// flight at the top of the grid) — RootView opens the
    /// expanded card for that job.
    var onExpandGenerationJob: (PipelineJob) -> Void = { _ in }

    /// Fires when the user starts scrolling the grid. RootView
    /// uses this to auto-dismiss an open generation card or
    /// picker so they don't block the content the user is
    /// trying to reach.
    var onScrollBegan: () -> Void = {}

    @State private var contentVisible = false
    @State private var playsInitialSequence = false
    @State private var dragHintVisible = true
    @State private var outfitFrames: [String: CGRect] = [:]
    @State private var outfitFrameIndices: [String: Int] = [:]
    /// Reference-type tracker so per-frame updates during scrub mutate
    /// internal state WITHOUT triggering grid re-renders. SwiftUI only
    /// observes @State value identity; class-internal mutations are
    /// invisible to it. We only commit to the store on drag-end.
    @State private var scrubTracker = ScrubFrameTracker()
    /// Exit/entry frame images so grid cells show the exact frame a
    /// carousel visit left on. CAPPED: uncapped, a long browse session
    /// accumulated a decoded UIImage per visited outfit — memory
    /// pressure that read as "scroll gets janky after a while".
    @State private var outfitFrameImages: [String: UIImage] = [:]
    @State private var outfitFrameImageOrder: [String] = []

    private func storeFrameImage(_ image: UIImage, for outfitId: String) {
        outfitFrameImages[outfitId] = image
        outfitFrameImageOrder.removeAll { $0 == outfitId }
        outfitFrameImageOrder.append(outfitId)
        while outfitFrameImageOrder.count > 12 {
            let evicted = outfitFrameImageOrder.removeFirst()
            outfitFrameImages[evicted] = nil
        }
    }
    @State private var showCarousel = false
    @State private var carouselBackdropVisible = false
    @State private var carouselChromeVisible = false
    @State private var carouselIndex = 0
    @State private var activeCarouselFrameIndex = 0
    @State private var activeCarouselDisplayedFrame: Int?
    @State private var isScrubbing = false
    @State private var heroTransition: HeroTransition?
    @State private var heroOpacity: Double = 1
    @State private var showCurrentCarouselLiveSlide = false
    @State private var showCarouselEntryOverlay = false
    @State private var revealGridOutfitIdDuringHero: String?
    @State private var carouselEntryFrame: CarouselEntryFrame?
    @State private var carouselEntryImage: UIImage?
    @State private var heroFrame: CGRect = .zero
    @State private var carouselTargetFrame: CGRect = .null
    @State private var entranceTask: Task<Void, Never>?
    @State private var carouselTransitionTask: Task<Void, Never>?
    /// Cancellable handle for the in-flight scroll-to-pending task.
    /// Each new pending-scroll cancels the previous task — without
    /// this, rapid taps stack overlapping scroll tasks that step on
    /// each other's `pendingListScrollOutfitId` clears, which confuses
    /// the transition's Phase-1 wait.
    @State private var pendingScrollTask: Task<Void, Never>?

    /// Measured height of `ProfileHeader` (avatar + name + bio +
    /// stats). Updated via a `.background { GeometryReader }` reader
    /// on the header itself. Used by `handleScrollOffset` as the
    /// pin threshold so longer bios / wrapped display names
    /// automatically push the pin trigger further down. Defaults to
    /// 0 (i.e. fall back to the hard-coded 200) until the first
    /// layout pass lands a measurement.
    @State private var profileHeaderHeight: CGFloat = 0

    /// Last seen scroll offset — used to detect "user is actively
    /// scrolling" (vs. content settling) so `onScrollBegan` only
    /// fires on real user gestures.
    @State private var lastObservedScrollOffset: CGFloat = 0

    // Open-transition timings come from the SHARED choreography so they
    // cannot drift from the user-profile sheet's copy of this sequence.
    private let heroTransitionDuration = CarouselHeroChoreography.heroFlightDuration
    private let heroFadeInDuration = CarouselHeroChoreography.revealFadeDuration
    private let heroFadeOutDuration: Double = 0.08
    private let carouselBackdropFadeInDuration = CarouselHeroChoreography.backdropFadeInDuration
    private let carouselBackdropFadeOutDuration: Double = 0.12
    private let carouselChromeFadeInDuration = CarouselHeroChoreography.chromeFadeInDuration
    private let carouselChromeFadeOutDuration: Double = 0.1
    private let initialVisibleCount = 9
    // MARK: Pinch zoom (mirrors the closet grid + calendar)
    // Mechanics live in the shared `gridPinchZoom` modifier
    // (GridPinchZoom.swift); the archive adds the continuum's final
    // stop — pinching past the biggest cells opens the carousel.

    @State private var pinch = GridPinchZoomState()
    @State private var twoFingersDown = false
    /// Direct handle to the grid's UIScrollView — scrub/pinch locks go
    /// through the pan RECOGNIZER (wedge-proof) instead of flapping
    /// SwiftUI's scrollDisabled mid-touch.
    @State private var scrollBox = WeakScrollViewBox()
    private static let minColumns = 2
    private static let maxColumns = 4

    private var columnCount: Int { store.archiveColumnCount }

    /// STATIC layout instances per density — a fresh [GridItem] per
    /// body evaluation forced LazyVGrid to re-lay the grid on every
    /// render (transition instability, pinch cost). Same fix as the
    /// calendar.
    private static let columnLayouts: [Int: [GridItem]] = [
        2: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: 2),
        3: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 3),
        4: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 4),
    ]

    private var columns: [GridItem] {
        Self.columnLayouts[columnCount] ?? Self.columnLayouts[3]!
    }

    private var gridRowSpacing: CGFloat {
        switch columnCount {
        case 2: 48
        case 3: 42
        default: 30
        }
    }

    /// Cell height scales with the zoom (168pt at the default 3
    /// columns) so cards keep their proportions.
    private var cardHeight: CGFloat {
        504 / CGFloat(columnCount)
    }

    var body: some View {
        ScrollViewReader { reader in
            GeometryReader { geometry in
                let viewportFrame = geometry.frame(in: .global)
                let heroDisplayFrame = displayedHeroFrame(in: viewportFrame)

                ZStack {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Match UserProfileView's top clearance —
                            // just the safe area. The GradientBlurView
                            // that previously sat above this view was
                            // removed (it was washing out the avatar
                            // on first load); the corner buttons have
                            // their own circle backgrounds so they
                            // stay legible without it.
                            Color.clear
                                .frame(height: LayoutMetrics.safeTop)

                            // Invisible UIKit hook that observes the
                            // underlying UIScrollView's contentOffset
                            // via KVO. SwiftUI's preference-key path
                            // wasn't propagating through this view's
                            // layout (the listener only ever saw the
                            // default sentinel), so we drop down to
                            // UIKit for a deterministic scroll signal.
                            // Also carries the "archiveTop" anchor
                            // ID so re-tapping the Profile tab can
                            // scroll back to it.
                            ScrollOffsetObserver(onScroll: { offsetY in
                                handleScrollOffset(offsetY)
                            }, onScrollViewAttach: { scrollView in
                                // Two-finger touches can never scroll —
                                // set ONCE, no toggling to wedge.
                                scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
                                scrollBox.scrollView = scrollView
                            })
                            .frame(width: 0, height: 0)
                            .id("archiveTop")

                            // Profile-as-home: avatar / username / bio /
                            // stats scroll with the grid and slide off
                            // the top naturally. Hidden in calendar view
                            // (CalendarMonthView does not render this).
                            // Background GeometryReader measures the
                            // header's height so the pin threshold
                            // tracks the actual layout (longer bios /
                            // wrapped names move the trigger).
                            ProfileHeader()
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear
                                            .onAppear { profileHeaderHeight = proxy.size.height }
                                            .onChange(of: proxy.size.height) { _, new in profileHeaderHeight = new }
                                    }
                                }

                            sectionHeader

                            if !store.sortedOutfits.isEmpty {
                                dragHint
                                    .padding(.top, LayoutMetrics.small)
                                    .padding(.bottom, LayoutMetrics.medium)
                                    .blurFadeReveal(active: contentVisible, delay: 0.06, blurRadius: 10)
                            }

                            outfitsGrid

                            Color.clear
                                .frame(height: LayoutMetrics.screenPadding)
                        }
                        .padding(.horizontal, LayoutMetrics.small)
                    }
                    .compositingGroup()
                    // Modal state only — transient scrub/pinch locks
                    // go through the pan recognizer (syncScrollLock);
                    // flapping scrollDisabled mid-touch wedged the pan
                    // (frozen scroll with every flag clear).
                    .scrollDisabled(showCarousel)
                    // Chrome cover, fading in WITH scroll: the profile
                    // header's stats/°F-°C toggle and the "outfits"
                    // section title scroll under the fixed top bar
                    // fully crisp (overlapping the status bar, logo,
                    // and share/settings buttons). Unlike the
                    // calendar's always-on cover, this one must be
                    // invisible at rest — the profile header
                    // legitimately owns the top of the page — so its
                    // opacity tracks the scroll offset.
                    .overlay(alignment: .top) {
                        archiveChromeCover
                    }
                    .background(
                        TouchCountReporter { count in
                            // Window-level recognizer: ignore touches
                            // while this surface isn't the visible one
                            // (the archive + calendar stay mounted) —
                            // but ALWAYS let a zero-count through so
                            // the flag can't latch scroll off.
                            guard store.currentView == .list || count == 0 else { return }
                            let down = count >= 2
                            if down != twoFingersDown { twoFingersDown = down }
                            syncScrollLock()
                            if count == 0 { scheduleGestureLatchSelfHeal() }
                        }
                    )
                    .allowsHitTesting(!showCarousel)
                    .overlay {
                        // Hide the CTA the moment ANY generation is in flight
                        // (2D or 3D) — the in-progress placeholder card is the
                        // content now; the button was overlapping it.
                        if store.sortedOutfits.isEmpty,
                           store.generationQueue.activeJobs.isEmpty,
                           store.generationQueue.waitingJobs.isEmpty {
                            emptyStatePrompt
                                .blurFadeReveal(active: contentVisible, delay: 0.06, blurRadius: 10)
                        }
                    }

                    if showCarousel {
                        CarouselView(
                            outfits: carouselOutfits,
                            currentIndex: $carouselIndex,
                            backdropOpacity: carouselBackdropVisible ? 1 : 0,
                            showsChrome: carouselChromeVisible,
                            showsCurrentLiveSlide: showCurrentCarouselLiveSlide,
                            showsEntryOverlay: showCarouselEntryOverlay,
                            heroTransitionActive: heroTransition != nil,
                            entryFrame: carouselEntryFrame,
                            entryImage: carouselEntryImage,
                            onHeroTargetFrameChange: { frame in
                                carouselTargetFrame = frame
                            },
                            onCurrentFrameChange: { frameIndex in
                                activeCarouselFrameIndex = frameIndex
                                if let entryFrame = carouselEntryFrame,
                                   carouselOutfits[safe: carouselIndex]?.id == entryFrame.outfitId,
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
                            onDeleteOutfit: { outfit in
                                deleteCarouselOutfit(outfit)
                            },
                            onDismiss: {
                                dismissCarousel(using: reader)
                            },
                            generatingOutfitIds: store.generating3DOutfitIds
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
                    store.listOutfitFrames = frames
                    updateCenteredOutfit(from: frames, viewportFrame: viewportFrame)
                }
            }
            .onAppear {
                prepareEntrance()
                // If we're returning from the calendar with an anchor
                // outfit selected, scroll so it's centered on screen.
                // Mirrors CalendarMonthView's onAppear scroll-to-anchor.
                scrollToPendingListTarget(using: reader)
            }
            .onChange(of: store.pendingListScrollOutfitId) { _, newId in
                guard newId != nil else { return }
                scrollToPendingListTarget(using: reader)
            }
            .onChange(of: store.archiveScrollToTopTrigger) { _, _ in
                withAnimation(.easeInOut(duration: 0.32)) {
                    reader.scrollTo("archiveTop", anchor: .top)
                }
            }
            .onChange(of: store.currentView) { _, _ in
                // A view switch can unmount a cell mid-scrub, so its
                // drag-end callback never fires — `isScrubbing` then
                // latches true and scroll is permanently disabled
                // (the "scroll freezes after a few back-and-forths").
                isScrubbing = false
                twoFingersDown = false
                syncScrollLock()
            }
            .onChange(of: scenePhase) { _, phase in
                // Backgrounding cancels all touches system-wide and
                // can drop in-flight gesture END callbacks — returning
                // from the app switcher then read as "frozen until a
                // tab tap". Foregrounding = no fingers down: clear all
                // transient gesture latches. (Mirrors the calendar.)
                guard phase == .active else { return }
                isScrubbing = false
                twoFingersDown = false
                pinch.startColumns = nil
                pinch.isPinching = false
                pinch.scale = 1
                syncScrollLock()
                scrollBox.resetPanRecognizer()
            }
            .onChange(of: store.carouselDismissTrigger) { _, _ in
                // Fired by the global X button in the top bar when
                // the carousel is open. Only acts if we're the host
                // currently showing the carousel.
                guard showCarousel else { return }
                dismissCarousel(using: reader)
            }
            .onChange(of: store.isLoading) { _, isLoading in
                guard !showCarousel else { return }
                if isLoading {
                    resetEntranceState()
                } else {
                    startEntrance(after: AppConfig.loaderFadeDuration + AppConfig.listEntranceDelayAfterLoader)
                }
            }
            .onChange(of: showCarousel) { _, isShowing in
                store.isCarouselOpen = isShowing
                guard isShowing else { return }
                Task { @MainActor in
                    await syncGridToCarouselSelection(using: reader)
                }
            }
            .onChange(of: carouselIndex) { _, _ in
                guard showCarousel else { return }
                Task { @MainActor in
                    await syncGridToCarouselSelection(using: reader)
                }
            }
            .onDisappear {
                entranceTask?.cancel()
                carouselTransitionTask?.cancel()
                store.isCarouselOpen = false
                // Clear the pinned flag so the next view (feed,
                // upload, profile sheet) doesn't see a stale toggle
                // in the top bar.
                store.archiveTogglePinned = false
            }
            // Opt the whole archive surface out of automatic keyboard
            // avoidance. The carousel detail card has inline TextFields
            // for location and tags; without this, focusing them
            // shoves the parent ZStack (and therefore the carousel)
            // up by the keyboard height, which dragged the card off
            // its anchored position. `.ignoresSafeArea(.keyboard)`
            // applied *here* (the topmost view of this screen) is
            // what actually stops the shift — applying it lower in
            // CarouselView only opted that subtree out, while its
            // parent ZStack was still being inset.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    /// Fixed pattern: [1, 3, 2, 2, 1, 3, 3, 2, 1] — looks random but is stable
    private static let placeholderPattern = [1, 3, 2, 2, 1, 3, 3, 2, 1]

    /// Chrome cover, fading in WITH scroll: the profile header's stats /
    /// °F-°C toggle and the "outfits" section title scroll under the fixed
    /// top bar fully crisp otherwise (overlapping the status bar, logo,
    /// and share/settings buttons). Unlike the calendar's always-on
    /// cover, this one must be invisible at rest — the profile header
    /// legitimately owns the top of the page — so opacity tracks the
    /// scroll offset.
    private var archiveChromeCover: some View {
        let stops: [Gradient.Stop] = [
            Gradient.Stop(color: AppPalette.pageBackground, location: 0),
            Gradient.Stop(color: AppPalette.pageBackground, location: 0.6),
            Gradient.Stop(color: AppPalette.pageBackground.opacity(0), location: 1),
        ]
        let progress: CGFloat = (lastObservedScrollOffset - 60) / 100
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: 120)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .opacity(Double(min(CGFloat(1), max(CGFloat(0), progress))))
    }

    /// "outfits" label on the left, grid/calendar toggle on the right.
    /// Sits between the profile header and the grid. The HStack's
    /// own global minY is bubbled up via `ArchiveToggleMinYKey` so
    /// the top bar can pin a copy of the toggle once scrolling brings
    /// the section level with the top bar — at which point the
    /// in-page toggle fades out via `store.archiveTogglePinned`.
    private var sectionHeader: some View {
        HStack(alignment: .center) {
            Text("outfits")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.leading, LayoutMetrics.xxSmall)

            Spacer()

            ViewModeTogglePill(isCalendarActive: false) {
                onToggleToCalendar()
            }
            .opacity(store.archiveTogglePinned ? 0 : 1)
            .animation(.easeInOut(duration: 0.12), value: store.archiveTogglePinned)
        }
        .padding(.top, LayoutMetrics.xSmall)
        .padding(.bottom, LayoutMetrics.xSmall)
        // POSITION-driven fade, independent of the pinned flag: the
        // binary pin threshold can fire late (or the header can hover
        // right at the boundary), letting the in-page toggle scroll
        // crisp underneath the top bar's share/settings — the ghost
        // capsule "overlap". Fading by the row's own proximity to the
        // chrome makes that visually impossible: by the time it
        // reaches the buttons it has already dissolved.
        .headerProximityFade(headerBottom: 64, fadeZone: 60)
    }

    private var outfitsGrid: some View {
        LazyVGrid(columns: columns, spacing: gridRowSpacing) {
            // Generation placeholders sit at the top of the grid —
            // newest selection first — so the user's "I just picked
            // this" moment lands in the highest-priority visual slot.
            // Filtered to only the queue jobs whose committed outfit
            // isn't already in the archive (avoids a duplicate render
            // during the brief window between accept-2D and queue
            // removal).
            ForEach(generationPlaceholderJobs, id: \.id) { job in
                GenerationPlaceholderCard(
                    job: job,
                    phase: store.generationQueue.phase(for: job),
                    onTap: {
                        guard !pinch.isPinching else { return }
                        onExpandGenerationJob(job)
                    },
                    height: cardHeight
                )
            }
            ForEach(Array(store.sortedOutfits.enumerated()), id: \.element.id) { index, outfit in
                gridItem(outfit: outfit, index: index)
            }
        }
        // Shared pinch-zoom engine (see GridPinchZoom.swift) plus the
        // archive's final stop: zooming in past the 2-column cells
        // (raw < 1.45) opens the carousel on the centered outfit —
        // fired on RELEASE so the open never fights the live gesture.
        .gridPinchZoom(
            $pinch,
            minColumns: Self.minColumns,
            maxColumns: Self.maxColumns,
            columnCount: columnCount,
            setColumnCount: { store.archiveColumnCount = $0 },
            zoomPastMinThreshold: 1.45,
            onEnded: { pinchedIntoCarousel in
                guard pinchedIntoCarousel else { return }
                if let id = store.centeredListOutfitId ?? store.sortedOutfits.first?.id,
                   let index = store.sortedOutfits.firstIndex(where: { $0.id == id }) {
                    presentCarousel(
                        for: store.sortedOutfits[index],
                        at: index,
                        frameIndex: store.listOutfitFrameIndices[id] ?? 0,
                        image: nil
                    )
                }
            }
        )
    }

    private var generationPlaceholderJobs: [PipelineJob] {
        let queue = store.generationQueue
        let archived = Set(store.outfits.map(\.id))
        let all = queue.activeJobs + queue.waitingJobs
        return all
            .filter { job in
                guard let resultId = job.resultOutfitId else { return true }
                return !archived.contains(resultId)
            }
            .reversed()
    }

    /// Outfits shown by the carousel. Fits whose 3D upgrade is
    /// rendering are REAL archive entries (the Generate-3D flow saves
    /// the 2D immediately), so no injection is needed — they're in
    /// `sortedOutfits` like any saved 2D, just wearing sparkles.
    private var carouselOutfits: [Outfit] {
        store.sortedOutfits
    }

    private func placeholderCard(index: Int) -> some View {
        let imageNumber = Self.placeholderPattern[index % Self.placeholderPattern.count]
        let resourceName = "placeholder-\(imageNumber)"

        return Group {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: "webp"),
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
                    .aspectRatio(FrameConfig.dimensions.width / FrameConfig.dimensions.height, contentMode: .fit)
            }
        }
        .opacity(0.03)
        .blurFadeReveal(active: contentVisible, delay: revealDelay(for: index))
    }

    private func gridItem(outfit: Outfit, index: Int) -> some View {
        OutfitCardView(
            outfit: outfit,
            height: cardHeight,
            scrubEnabled: !twoFingersDown,
            // NEVER preload the full 242-frame sequence from a grid
            // cell (the old `columnCount <= 3` gate was always true at
            // the default density, so the storm ran on every mount).
            // Each preload queues ~242 serialized decodes on the
            // FrameLoader actor; cover-frame loads for newly visible
            // cells then starve behind them — blank cells, transition
            // stalls, unresponsive pinch. Scrubbing lazy-loads frames
            // on demand, and the launch entrance spin still preloads
            // via `playEntranceSequence` (bounded to the first
            // screenful).
            preloadFullSequence: false,
            eagerLoad: index < initialVisibleCount,
            playEntranceSequence: playsInitialSequence && index < initialVisibleCount,
            entranceSequenceActive: contentVisible,
            entranceSequenceDelay: revealDelay(for: index),
            // Priority: anchor-frame override (only set during a
            // list↔calendar transition for the anchor cell) →
            // carousel local override → nil. The anchor override is
            // what keeps the morphing cell visually in sync with the
            // source view's displayed frame.
            syncFrameIndex: anchorTransitionFrame(for: outfit.id) ?? outfitFrameIndices[outfit.id],
            syncImage: outfitFrameImages[outfit.id],
            onTap: { frameIndex, image in
                // A finger-lift at the end of a pinch must not read
                // as a tap.
                guard !pinch.isPinching else { return }
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                presentCarousel(for: outfit, at: index, frameIndex: frameIndex, image: image)
            },
            onHorizontalDragChange: { isDragging in
                isScrubbing = isDragging
                syncScrollLock()
                if isDragging {
                    dragHintVisible = false
                } else {
                    // Drag ended — commit the latest scrubbed frame to
                    // the store so the next view-transition can start
                    // the hero at the correct frame instead of frame 0.
                    // Only fires once at end (not per-frame) so no jitter.
                    if let frame = scrubTracker.frames[outfit.id] {
                        store.listOutfitFrameIndices[outfit.id] = frame
                    }
                }
            },
            onFrameChange: { newFrame in
                // Per-frame updates go into the reference-type tracker
                // (no @State mutation, no grid re-render). The actual
                // commit to the store happens on drag end above.
                scrubTracker.frames[outfit.id] = newFrame
                // Broadcast current frame to the store so a list↔
                // calendar transition can capture the source anchor's
                // exact displayed frame at switch time. No view body
                // reads this dict, so writes don't trigger re-renders.
                store.currentDisplayedFrame[outfit.id] = newFrame
            }
        )
        .overlay {
            // 3D upgrade in flight: the archived 2D wears the sparkle
            // field until the render is accepted. Non-interactive —
            // taps pass through to the card underneath.
            if store.generating3DOutfitIds.contains(outfit.id) {
                GenerationStarField(starSize: 200, interactive: false)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .blurFadeReveal(active: contentVisible, delay: revealDelay(for: index))
        .id(outfit.id)
        .anchorTransition(
            outfitId: outfit.id,
            namespace: transitionNamespace,
            isAnchor: store.transitionAnchorOutfitId == outfit.id,
            viewName: "list",
            isSource: store.currentView == .list
        )
        .opacity(
            // Hide cell only while it's the source of an in-flight
            // CAROUSEL hero zoom — list↔calendar transition is handled
            // by matchedGeometryEffect on the cell itself.
            (heroTransition?.outfit.id == outfit.id && revealGridOutfitIdDuringHero != outfit.id)
                ? 0.001
                : 1
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ListOutfitFramePreferenceKey.self,
                    value: [outfit.id: proxy.frame(in: .global)]
                )
            }
        }
        // When the cell scrolls out of the lazy-render region, drop
        // its entry from the frames dicts so transition logic can't
        // pick up a stale (pre-scroll) frame and morph to the wrong
        // place. SwiftUI's PreferenceKey reducer doesn't reliably
        // remove entries for unmounted cells, so we do it explicitly.
        .onDisappear {
            outfitFrames[outfit.id] = nil
            store.listOutfitFrames[outfit.id] = nil
        }
    }

    private var emptyStatePrompt: some View {
        // Bias the button into the lower portion of the viewport so
        // it sits between the "outfits" section header (which scrolls
        // away with the profile area at the top) and the tab bar —
        // not at the geometric centre of the full scroll viewport,
        // which would put it right under the profile stats.
        VStack(spacing: 0) {
            Spacer()
            Spacer()
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                // Trigger RootView's floating generation picker. The
                // tab bar's "+" tap funnels through the same picker,
                // so the empty state's CTA stays in sync with the
                // primary entry point automatically.
                store.generationPickerOpenTrigger += 1
            } label: {
                HStack(spacing: 6) {
                    AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.textPrimary)
                    Text("CREATE YOUR FIRST FIT")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
                .frame(height: 48)
                .padding(.horizontal, 28)
                .appCapsule(shadowRadius: 8, shadowY: 4)
            }
            .buttonStyle(SolidPressButtonStyle())
            Spacer()
        }
    }

    private var dragHint: some View {
        Text("DRAG TO ROTATE")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
            .opacity(dragHintVisible && !showCarousel ? 1 : 0)
            .frame(maxWidth: .infinity)
    }

    private func prepareEntrance() {
        if store.isLoading {
            resetEntranceState()
        } else {
            startEntrance()
        }
    }

    private func resetEntranceState() {
        entranceTask?.cancel()
        contentVisible = false
        playsInitialSequence = false
        dragHintVisible = true
        showCarousel = false
        carouselBackdropVisible = false
        carouselChromeVisible = false
        isScrubbing = false
        heroTransition = nil
        heroOpacity = 1
        showCurrentCarouselLiveSlide = false
        showCarouselEntryOverlay = false
        revealGridOutfitIdDuringHero = nil
        carouselEntryFrame = nil
        carouselEntryImage = nil
        activeCarouselFrameIndex = 0
        activeCarouselDisplayedFrame = nil
        heroFrame = .zero
        carouselTargetFrame = .null
        store.selectedOutfitId = nil
    }

    private func startEntrance(after delay: Double = 0) {
        entranceTask?.cancel()
        resetEntranceState()
        playsInitialSequence = !store.hasPlayedInitialListEntrance

        entranceTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            contentVisible = true
            if playsInitialSequence {
                store.hasPlayedInitialListEntrance = true
            }
        }
    }

    private func revealDelay(for index: Int) -> Double {
        Double(min(index, initialVisibleCount - 1)) * 0.05
    }

    private func presentCarousel(for outfit: Outfit, at index: Int, frameIndex: Int, image: UIImage?) {
        carouselTransitionTask?.cancel()
        // Rapid open → close → open: cancelling a mid-flight dismissal
        // leaves the PREVIOUS outfit's hero image mounted above the
        // stack (it only unmounts at the end of the dismiss task). A
        // stale hero over a fresh open is exactly the "two outfits
        // crossing" glitch — clear every transition leftover up front,
        // synchronously, before staging this open.
        heroTransition = nil
        heroOpacity = 1
        showCarouselEntryOverlay = false
        showCurrentCarouselLiveSlide = false
        revealGridOutfitIdDuringHero = nil
        carouselEntryFrame = nil
        carouselEntryImage = nil
        carouselTargetFrame = .null

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
            store.selectedOutfitId = outfit.id
            activeCarouselFrameIndex = entryFrameIndex
            activeCarouselDisplayedFrame = nil
            heroOpacity = 1
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            revealGridOutfitIdDuringHero = nil
            outfitFrameIndices[outfit.id] = entryFrameIndex
            if let entryImage {
                storeFrameImage(entryImage, for: outfit.id)
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

            withAnimation(CarouselHeroChoreography.heroFlightAnimation) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            // The slide can settle a few points away from where it was when
            // the flight started (initial slideHeight placeholder, late layout
            // under load) — landing on the stale rect made the live slide pop
            // in visibly offset from the hero. Re-measure and glide out any
            // drift concurrently with the reveal so the swap is pixel-aligned
            // without adding a pause.
            let settledFrame = await waitForCarouselTargetFrame(fallback: targetFrame)
            guard !Task.isCancelled else { return }
            if !CarouselHeroChoreography.rectsMatch(settledFrame, targetFrame) {
                withAnimation(.easeOut(duration: 0.1)) {
                    heroFrame = settledFrame
                }
            }

            _ = await waitForCarouselDisplayedFrame(entryFrameIndex, outfitId: outfit.id)
            guard !Task.isCancelled else { return }

            showCurrentCarouselLiveSlide = true
            withAnimation(.easeOut(duration: heroFadeInDuration)) {
                showCarouselEntryOverlay = carouselEntryImage != nil
                heroOpacity = 0
            }
            // Chrome fades in WITH the reveal crossfade — it used to wait for
            // the crossfade to fully finish first, adding ~120ms of dead
            // serialization to every open for no structural reason.
            withAnimation(.easeInOut(duration: carouselChromeFadeInDuration)) {
                carouselChromeVisible = true
            }

            try? await Task.sleep(for: .milliseconds(Int(heroFadeInDuration * 1000)))
            guard !Task.isCancelled else { return }

            heroTransition = nil
            heroOpacity = 1
        }
    }

    private func dismissCarousel(using reader: ScrollViewProxy) {
        carouselTransitionTask?.cancel()
        store.isCarouselOpen = false

        // Teardown watchdog: the dismiss task below has cancellation
        // early-exits — if it's cancelled WITHOUT a successor (scroll-
        // dismiss racing the X, an edit-triggered re-render), it can
        // die leaving `showCarousel == true`: the grid stays hit-
        // disabled + scroll-locked with no carousel on screen
        // ("outfits don't drag anymore / frozen after closing").
        // `isCarouselOpen` went false synchronously above, so if the
        // flags still disagree after 1.5s the flow is definitively
        // stuck — apply terminal cleanup, no animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard showCarousel, !store.isCarouselOpen else { return }
            showCarousel = false
            heroTransition = nil
            heroOpacity = 1
            revealGridOutfitIdDuringHero = nil
            carouselBackdropVisible = false
            carouselChromeVisible = false
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            carouselEntryFrame = nil
            carouselEntryImage = nil
            carouselTargetFrame = .null
            activeCarouselFrameIndex = 0
            activeCarouselDisplayedFrame = nil
            store.selectedOutfitId = nil
        }

        guard
            showCarousel,
            let currentOutfit = carouselOutfits[safe: carouselIndex]
        else {
            showCarousel = false
            heroTransition = nil
            carouselBackdropVisible = false
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            carouselEntryFrame = nil
            carouselEntryImage = nil
            carouselTargetFrame = .null
            activeCarouselFrameIndex = 0
            activeCarouselDisplayedFrame = nil
            store.selectedOutfitId = nil
            return
        }

        let startFrame = carouselTargetFrame.isNull ? heroFrame : carouselTargetFrame
        let exitFrameIndex = activeCarouselDisplayedFrame ?? activeCarouselFrameIndex

        carouselTransitionTask = Task { @MainActor in
            await syncGridToCarouselSelection(using: reader)
            let targetFrame = outfitFrames[currentOutfit.id]
            let exitImage = await FrameLoader.shared.frame(for: currentOutfit, index: exitFrameIndex)
            guard !Task.isCancelled else { return }

            heroOpacity = 1
            revealGridOutfitIdDuringHero = nil
            outfitFrameIndices[currentOutfit.id] = exitFrameIndex
            if let exitImage {
                storeFrameImage(exitImage, for: currentOutfit.id)
            }

            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            withAnimation(.easeInOut(duration: carouselChromeFadeOutDuration)) {
                carouselChromeVisible = false
            }
            withAnimation(.easeInOut(duration: carouselBackdropFadeOutDuration)) {
                carouselBackdropVisible = false
            }

            guard let targetFrame else {
                try? await Task.sleep(for: .milliseconds(Int(carouselBackdropFadeOutDuration * 1000)))
                guard !Task.isCancelled else { return }
                showCarousel = false
                heroTransition = nil
                heroOpacity = 1
                revealGridOutfitIdDuringHero = nil
                showCurrentCarouselLiveSlide = false
                showCarouselEntryOverlay = false
                carouselEntryFrame = nil
                carouselEntryImage = nil
                carouselTargetFrame = .null
                activeCarouselFrameIndex = 0
                activeCarouselDisplayedFrame = nil
                carouselBackdropVisible = false
                store.selectedOutfitId = nil
                return
            }

            heroTransition = HeroTransition(outfit: currentOutfit, frameIndex: exitFrameIndex, image: exitImage)
            heroFrame = startFrame

            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(CarouselHeroChoreography.heroFlightAnimation) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            showCarousel = false
            revealGridOutfitIdDuringHero = currentOutfit.id

            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: heroFadeOutDuration)) {
                heroOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(Int(heroFadeOutDuration * 1000)))
            guard !Task.isCancelled else { return }

            heroTransition = nil
            heroOpacity = 1
            revealGridOutfitIdDuringHero = nil
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            carouselEntryFrame = nil
            carouselEntryImage = nil
            carouselTargetFrame = .null
            activeCarouselFrameIndex = 0
            activeCarouselDisplayedFrame = nil
            carouselBackdropVisible = false
            store.selectedOutfitId = nil
        }
    }

    /// Fired by `ScrollOffsetObserver` on every contentOffset tick.
    /// `offsetY = 0` at the top; increases as the user scrolls up.
    /// We pin once the user has scrolled past the profile header so
    /// the section toggle would be sitting at the top-bar level.
    ///
    /// Threshold is the measured `ProfileHeader` height — when the
    /// scroll has consumed that much, the section header (which sits
    /// right below it) is at the top of the visible area. Falls back
    /// to `200` (a reasonable default for the typical layout) until
    /// the first height measurement lands.

    /// Push the transient lock state into the scroll view's pan
    /// recognizer. Disable-mid-gesture cancels cleanly; re-enable
    /// restores — unlike scrollDisabled, this cannot wedge.
    private func syncScrollLock() {
        scrollBox.setScrollLocked(isScrubbing || twoFingersDown)
    }

    /// Self-heal for latched gesture state — mirrors the calendar.
    /// SwiftUI can DROP a gesture's `.onEnded` mid-interruption; the
    /// pinch then leaves `isPinching` true forever and every card tap
    /// is guarded by it. Zero fingers on the glass = no live gesture,
    /// so clear the latches after a beat.
    private func scheduleGestureLatchSelfHeal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard TouchCountGestureRecognizer.liveTouchCount == 0 else { return }
            if pinch.isPinching || pinch.scale != 1 || pinch.startColumns != nil {
                pinch.startColumns = nil
                pinch.isPinching = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) {
                    pinch.scale = 1
                }
            }
            if isScrubbing { isScrubbing = false }
            syncScrollLock()
        }
    }

    private func handleScrollOffset(_ offsetY: CGFloat) {
        // Notify the host (RootView) that the user is actively
        // scrolling — used to auto-dismiss an open card / picker
        // so they don't block the content the user is reaching for.
        // Filter out tiny KVO bounces (< 4pt) so a settle doesn't
        // count as scroll.
        if abs(offsetY - lastObservedScrollOffset) > 4 {
            onScrollBegan()
        }
        lastObservedScrollOffset = offsetY

        // Fire ~40pt EARLY: the in-page toggle now dissolves by
        // proximity as it nears the chrome (see sectionHeader), so the
        // top-bar copy should already be in place when it fades — the
        // handoff reads as one pill pinning instead of two swapping.
        let pinThreshold = (profileHeaderHeight > 0 ? profileHeaderHeight : 200) - 40
        let shouldPin = offsetY > pinThreshold
        guard store.archiveTogglePinned != shouldPin else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.archiveTogglePinned = shouldPin
        }
    }

    @MainActor
    private func syncGridToCarouselSelection(using reader: ScrollViewProxy) async {
        guard let outfitId = carouselOutfits[safe: carouselIndex]?.id else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            reader.scrollTo(outfitId, anchor: .center)
        }
        await Task.yield()
        await Task.yield()
    }

    @MainActor
    private func waitForCarouselTargetFrame(fallback: CGRect) async -> CGRect {
        await CarouselHeroChoreography.waitForStableFrame(fallback: fallback) {
            carouselTargetFrame
        }
    }

    @MainActor
    private func waitForCarouselDisplayedFrame(_ frameIndex: Int, outfitId: String) async -> Bool {
        await CarouselHeroChoreography.waitUntil {
            carouselOutfits[safe: carouselIndex]?.id == outfitId
                && activeCarouselDisplayedFrame == frameIndex
        }
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

    private func hideCarouselEntryOverlay() {
        guard showCarouselEntryOverlay else { return }
        withAnimation(.easeOut(duration: heroFadeOutDuration)) {
            showCarouselEntryOverlay = false
        }
    }

    private func deleteCarouselOutfit(_ outfit: Outfit) {
        carouselTransitionTask?.cancel()
        showCarousel = false
        carouselBackdropVisible = false
        carouselChromeVisible = false
        isScrubbing = false
        heroTransition = nil
        heroOpacity = 1
        showCurrentCarouselLiveSlide = false
        showCarouselEntryOverlay = false
        revealGridOutfitIdDuringHero = nil
        carouselEntryFrame = nil
        carouselEntryImage = nil
        heroFrame = .zero
        carouselTargetFrame = .null
        activeCarouselFrameIndex = 0
        activeCarouselDisplayedFrame = nil
        carouselIndex = min(carouselIndex, max(carouselOutfits.count - 2, 0))
        store.selectedOutfitId = nil
        store.deleteOutfit(outfit)
    }

    /// Mirrors CalendarMonthView.scrollToPendingTarget — when we're
    /// brought back to the list with an anchor selected (e.g., user
    /// switched from calendar back to archive), scroll so the anchor
    /// outfit is centered on screen. Otherwise the hero would land at
    /// an off-screen position and look like the outfit "disappeared."
    private func scrollToPendingListTarget(using reader: ScrollViewProxy) {
        guard let targetOutfitId = store.pendingListScrollOutfitId else { return }

        // Cancel any previous in-flight scroll task before starting
        // a new one — otherwise overlapping tasks race on the
        // `pendingListScrollOutfitId` clear and the transition's
        // Phase-1 wait can exit on the wrong task's clear.
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(15))
            if Task.isCancelled { return }
            // Three nudges. For long-jump scrolls (calendar-bottom →
            // archive-bottom), the LazyVGrid hasn't mounted the target
            // row yet on the first call; each subsequent scrollTo
            // refines the position as more rows get laid out.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            for waitMs in [25, 30] {
                // Authority check — abort if a newer pending target
                // has taken over (or the flag was cleared). Stronger
                // than `Task.isCancelled` because a cancelled-but-
                // still-running task can issue stray synchronous
                // scrollTos between await points before cancellation
                // is observed.
                guard store.pendingListScrollOutfitId == targetOutfitId else { return }
                withTransaction(transaction) {
                    reader.scrollTo(targetOutfitId, anchor: .center)
                }
                try? await Task.sleep(for: .milliseconds(waitMs))
            }
            guard store.pendingListScrollOutfitId == targetOutfitId else { return }
            withTransaction(transaction) {
                reader.scrollTo(targetOutfitId, anchor: .center)
            }
            try? await Task.sleep(for: .milliseconds(35))
            // Only null the flag if it still points at OUR target.
            guard store.pendingListScrollOutfitId == targetOutfitId else { return }
            store.pendingListScrollOutfitId = nil
        }
    }

    /// Returns the in-flight transition's source frame for this cell
    /// if it's the current anchor, else nil. Lets the morphing cell
    /// render the same frame as the source view across the morph.
    private func anchorTransitionFrame(for outfitId: String) -> Int? {
        guard store.transitionAnchorOutfitId == outfitId else { return nil }
        return store.transitionAnchorFrameIndex
    }

    private func updateCenteredOutfit(from frames: [String: CGRect], viewportFrame: CGRect) {
        guard !frames.isEmpty, !showCarousel, store.currentView == .list else { return }

        let visibleViewport = CGRect(
            x: viewportFrame.minX,
            y: viewportFrame.minY,
            width: viewportFrame.width,
            height: max(0, viewportFrame.height)
        )
        let viewportCenter = CGPoint(x: visibleViewport.midX, y: visibleViewport.midY)

        let nearestOutfitId = frames
            .filter { $0.value.intersects(visibleViewport) }
            .min { lhs, rhs in
                distanceSquared(from: lhs.value.center, to: viewportCenter)
                    < distanceSquared(from: rhs.value.center, to: viewportCenter)
            }?
            .key

        guard let nearestOutfitId else { return }
        if store.centeredListOutfitId != nearestOutfitId {
            store.centeredListOutfitId = nearestOutfitId
        }
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

}

/// Reference-type holder for live-scrub frame tracking. Stored as
/// `@State` for identity persistence, but mutations to its internal
/// dict are invisible to SwiftUI's observation — we get O(1) per-frame
/// updates during scrub without re-rendering the grid.
private final class ScrubFrameTracker {
    var frames: [String: Int] = [:]
}

struct CarouselEntryFrame: Equatable {
    let outfitId: String
    let frameIndex: Int
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}



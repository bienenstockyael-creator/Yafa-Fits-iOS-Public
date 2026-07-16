import SwiftUI
import UIKit
import Vision
import simd

/// The wardrobe (product closet): every product the user has tagged,
/// shown as a filterable grid.
///
/// Sources items from the *union* of two places, so it shows
/// everything ever tagged without any data migration (mirroring how
/// the try-on closet already sources items):
///   1. The `products` table — canonical owned + wishlist items
///      (`WardrobeItem`, editable, carrying category/status/etc.).
///   2. Inline products attached to the user's outfits
///      (`Outfit.products`) that never landed in `products` — shown
///      read-only with an inferred category until promoted.
///
/// Deduped by normalized name AND image URL; real `products` rows win
/// over inline duplicates so the editable copy is the one that shows.
struct WardrobeView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let userId: UUID
    /// Dismiss the closet. Set when the closet is shown as a grow-from-button
    /// page (RootView overlay); falls back to the sheet dismiss otherwise.
    var onClose: (() -> Void)? = nil

    @State private var libraryItems: [WardrobeItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    init(userId: UUID, onClose: (() -> Void)? = nil) {
        self.userId = userId
        self.onClose = onClose
        // Seed from the cache so a reopen shows the last closet with no spinner;
        // load() still refreshes from the network in the background.
        if let cached = ClosetCache.items[userId], !cached.isEmpty {
            _libraryItems = State(initialValue: cached)
            _isLoading = State(initialValue: false)
        }
    }
    /// Re-fetches the closet while any thumbnail is still generating, so
    /// the sparkle overlay clears itself once FAL swaps in the cut-out.
    @State private var pollTask: Task<Void, Never>?

    @State private var categoryFilter: WardrobeCategory? = nil  // nil == All
    @State private var statusFilter: WardrobeStatus? = nil      // nil == All
    @State private var searchText: String = ""
    @State private var selectedItem: WardrobeDisplayItem?
    /// Bumped on every open so each lightbox gets a fresh identity (and fresh
    /// @State) — prevents a reused instance from opening with stale offset state.
    @State private var lightboxOpenToken = 0
    /// Global frames of the grid tiles + the anchor of the last-tapped one, so
    /// the lightbox grows out of (and shrinks back into) the product's spot.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var tapAnchor: UnitPoint = .center
    @State private var showGetExtension = false
    /// First-open explainer (how the closet fills up). Shown once, then never.
    @State private var showClosetIntro = false
    private let closetIntroSeenKey = "closet_intro_seen_v1"
    /// Live downward offset while swiping the closet page down to dismiss it
    /// (like a sheet). Drives the pull; release past a threshold closes it.
    @State private var closetDragOffset: CGFloat = 0
    /// Bitmap of the page captured at drag start — THE thing that
    /// follows the finger (see closetDismissDrag). nil at rest.
    @State private var dragSnapshot: UIImage?
    /// True once a committed dismiss slide is running — blocks new
    /// drag input during the hand-off to the (unanimated) unmount.
    @State private var isCommittingDismiss = false
    /// Weak handle to the cover's UIKit container, for snapshotting.
    @State private var containerRef = ContainerViewRef()
    /// Items deleted this session — filtered out immediately so the grid
    /// updates even before the (cached) outfit list re-syncs.
    @State private var deletedItemIDs: Set<String> = []

    /// Drives the grid's enter/exit animation on a filter change. `nil` →
    /// the quiet scale+fade used when tapping a pill; an edge → a directional
    /// slide (set by a swipe, so items page in from the swiped side).
    @State private var insertionEdge: Edge? = nil

    /// Apple Photos–style zoom: pinch to change how many columns the grid
    /// shows. Always starts at 2 (the default density) each time the closet
    /// opens — not persisted.
    @State private var columnCount: Int = 2
    /// Live, damped scale applied to the grid during a pinch for continuous
    /// feedback; springs back to 1 (and commits a new column count) on
    /// release — so the zoom feels fluid instead of snapping mid-gesture.
    /// Small compensating scale so tile *size* stays continuous while the
    /// column count steps during a pinch (the integer layout can only jump,
    /// the scale fills the gaps). Always ~0.85–1.2, so it never shoves
    /// content off-screen.
    @State private var pinchScale: CGFloat = 1
    /// Column count when the current pinch began, so the gesture maps
    /// absolute (not incrementally drifting).
    @State private var pinchStartColumns: Int?
    /// True while a pinch is in progress — used to lock scrolling so the
    /// content doesn't drift as you zoom.
    @State private var isPinching = false
    /// The focal point of the current pinch (midpoint of the two fingers),
    /// in the grid's unit space — so the zoom originates from your fingers
    /// rather than the content's center.
    @State private var pinchAnchor: UnitPoint = .center
    /// True whenever ≥2 fingers are on screen — scrolling is disabled then,
    /// so a two-finger pinch can never be hijacked into a scroll (one finger
    /// still scrolls normally).
    @State private var twoFingersDown = false
    /// Direct handle to the closet's UIScrollView — the pinch lock
    /// goes through the pan RECOGNIZER (wedge-proof) instead of
    /// flapping SwiftUI's scrollDisabled mid-touch.
    @State private var scrollBox = WeakScrollViewBox()
    @Environment(\.scenePhase) private var closetScenePhase

    private static let minColumns = 2
    private static let maxColumns = 4
    private let gridSpacing: CGFloat = 14

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    /// Changes when the category/status filter changes (NOT on search or
    /// zoom), so the grid re-identifies and the swap animates as a clean
    /// scale + fade instead of items sliding.
    private var gridIdentity: String {
        "\(categoryFilter?.rawValue ?? "all")|\(statusFilter?.rawValue ?? "all")"
    }

    /// The tapped tile's centre as a UnitPoint of the screen — the grow/shrink
    /// anchor for the lightbox. Falls back to centre if not captured yet.
    private func anchorPoint(for id: String) -> UnitPoint {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0, let f = cellFrames[id] else { return .center }
        // Clamp to the screen — a tile scrolled partly off-screen can report a
        // midY beyond the bounds, which would grow the card from off-screen.
        let x = min(max(f.midX / screen.width, 0), 1)
        let y = min(max(f.midY / screen.height, 0), 1)
        return UnitPoint(x: x, y: y)
    }

    /// Shrink the lightbox back into its tile. SAME spring as the open so the
    /// exit feels symmetric with the entry, not abrupt.
    private func closeLightbox() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedItem = nil
        }
    }

    /// Real device top inset from the key window — the page root
    /// ignores the safe area (it owns the full physical screen), so
    /// the header clears the status bar with explicit padding.
    private static var windowSafeTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        // The page fills the whole screen, behind the bars. NOT a NavigationStack:
        // its nav bar reserved the top and its safe-area management clamped both
        // the page AND the lightbox overlay below the bars — the real reason full
        // screen never reached the edges. A custom header replaces the (purely
        // cosmetic) nav bar.
        ZStack {
            // Dim behind the dragged card — a physical sheet needs
            // separation from the screen it slides over. Fades in with
            // the pull, back out as a committed dismiss slides away.
            if closetDragOffset > 0 {
                Color.black
                    .opacity(
                        0.20 * min(1, closetDragOffset / 260)
                            * (1 - closetDragOffset / UIScreen.main.bounds.height)
                    )
                    .ignoresSafeArea()
            }

            // THE LIVE PAGE — never offset, never clipped, so SwiftUI's
            // position-dependent safe-area layout never reflows it (the
            // reflow inside a moving live page was the drag's "clipping
            // pop", proven across three instrumented rounds). Hidden
            // while the snapshot drives the drag; the two are pixel-
            // identical at the moment of the swap.
            ZStack {
                AppPalette.groupedBackground

                VStack(spacing: 0) {
                    closetHeader
                    content
                }
                // Manual top inset (window safe area) — the root owns
                // the FULL physical screen, so the header clears the
                // status bar by explicit padding, not safe-area layout.
                .padding(.top, Self.windowSafeTopInset)
            }
            .ignoresSafeArea(.container)
            // System open/close slides get their corners from the UIKit
            // container rounding — disabled while the snapshot drag is
            // live so the stationary container's mask can't carve into
            // the moving snapshot.
            .fullScreenCardCorners(containerActive: dragSnapshot == nil)
            .background(ContainerViewGrabber(ref: containerRef))
            .opacity(dragSnapshot == nil ? 1 : 0)

            // THE DRAGGED CARD — a bitmap of the page, following the
            // finger with progressively rounding corners and a shadow.
            // Pixels cannot reflow.
            if let snapshot = dragSnapshot {
                SnapshotDragCard(image: snapshot, dragOffset: closetDragOffset)
            }
        }
        .task { await load() }
        .task {
            // Complete any wishlist items the server couldn't scrape
            // (bot-walled shops like Farfetch) — the app's WebKit
            // backfill reads the page like Safari and fills them in.
            // Reloads the closet if anything was completed.
            if let userId = store.userId {
                WishlistBackfillService.shared.backfillIfNeeded(userId: userId)
            }
        }
        .onAppear {
            // First-ever open: surface the explainer once the page has settled.
            guard !UserDefaults.standard.bool(forKey: closetIntroSeenKey) else { return }
            UserDefaults.standard.set(true, forKey: closetIntroSeenKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    showClosetIntro = true
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: $showGetExtension) {
            GetExtensionSheet()
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
        // Backdrop dims in place — it must NOT travel with the card. Its OWN
        // overlay so its existence toggles independently and its .opacity
        // transition actually fires.
        .overlay {
            // Persistent ZStack so the child's .opacity transition fires while
            // hit-testing re-evaluates LIVE. The moment a close sets selectedItem
            // = nil, the fading backdrop stops intercepting taps and they fall
            // through to the grid — so the exit never blocks opening another item.
            ZStack {
                if selectedItem != nil {
                    Color.black.opacity(0.32)
                        .contentShape(Rectangle())
                        .onTapGesture { closeLightbox() }
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(selectedItem != nil)
            // The overlay (not just the Color) must ignore the safe area, or it's
            // bounded below the nav bar and the dim never reaches the status bar.
            .ignoresSafeArea()
        }
        // Tap-to-edit opens IN PLACE as a lightbox that grows out of the tapped
        // tile — not a sheet-on-sheet. SEPARATE overlay from the backdrop: the
        // .scale transition must be the root of its own inserted subtree, or
        // SwiftUI swallows it (a child of a ZStack that appears as a whole gets
        // only the container's default opacity — a pure fade, no scale).
        .overlay {
            // Same pattern: persistent ZStack keeps the .scale transition alive
            // while hit-testing turns off the instant we start closing, so the
            // exiting card never swallows a tap meant for another tile.
            ZStack {
                if let item = selectedItem {
                    ProductLightbox(
                        item: item,
                        userId: userId,
                        onClose: { closeLightbox() },
                        onChanged: { await load() },
                        onDeleted: {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                                _ = deletedItemIDs.insert(item.id)
                            }
                        },
                        similarCandidates: allItems,
                        onSelectSimilar: { next in
                            // Swap the lightbox to the tapped similar item —
                            // fresh identity (new token) so the form state
                            // rebuilds for the new product.
                            lightboxOpenToken += 1
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                selectedItem = next
                            }
                        }
                    )
                    .environment(store)
                    // Per-item identity: switching items (or tapping a new tile
                    // while one is closing) must build a FRESH lightbox, or the
                    // reused @State form keeps the previous item's name/category
                    // while the image shows the new one (the mismatched card).
                    .id("\(item.id)-\(lightboxOpenToken)")
                    // Start small and tight at the tile so the card visibly
                    // CLUSTERS on the product and grows outward from there.
                    .transition(.scale(scale: 0.12, anchor: tapAnchor).combined(with: .opacity))
                }
            }
            .allowsHitTesting(selectedItem != nil)
            // Let the lightbox fill the entire screen (incl. behind the bars);
            // ProductLightbox insets its own content using the window safe area.
            .ignoresSafeArea()
        }
        // First-open explainer, above everything and centered to the viewport.
        .overlay {
            if showClosetIntro {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { dismissClosetIntro() }
                        .transition(.opacity)
                    closetIntroCard
                        .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keep the closet sheet from swipe-dismissing while a lightbox is open.
        .interactiveDismissDisabled(selectedItem != nil)
        // Fixed light palette across the app — keep it light so the search
        // field text stays readable in dark mode.
        .preferredColorScheme(.light)
    }

    private func dismissClosetIntro() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showClosetIntro = false
        }
    }

    /// First-open explainer card — matches the app's InfoExplainerModal style.
    private var closetIntroCard: some View {
        VStack(spacing: LayoutMetrics.medium) {
            AppIcon(glyph: .tshirt, size: 34, color: AppPalette.iconPrimary, filled: false)
                .padding(.top, LayoutMetrics.small)

            VStack(spacing: LayoutMetrics.small) {
                Text("Your closet")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                Text("Products you tag on your outfits land here automatically. You can also save wishlist items straight from Safari — tap Share, then Yafa.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { dismissClosetIntro() } label: {
                Text("GOT IT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.top, LayoutMetrics.xSmall)
        }
        .padding(.horizontal, LayoutMetrics.large)
        .padding(.vertical, LayoutMetrics.large)
        .appCard(cornerRadius: 24, shadowRadius: 28, shadowY: 12)
        .padding(.horizontal, LayoutMetrics.xLarge)
    }

    /// Custom page header replacing the nav bar. It lives inside a VStack that
    /// respects the safe area, so it naturally sits below the status bar while
    /// the page background fills behind it.
    private var closetHeader: some View {
        ZStack {
            Text("Closet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            HStack {
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    AppIcon(glyph: .xmark, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle()
                }
                .buttonStyle(SolidPressButtonStyle())
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 6)
        // Swipe the top of the page down to dismiss — like a sheet.
        .contentShape(Rectangle())
        .gesture(closetDismissDrag)
    }

    /// Swipe-down-to-dismiss for the whole closet page (the closet is a
    /// fullScreenCover, which has no built-in interactive dismiss). Disabled
    /// while a product lightbox is open so it can't fight the lightbox.
    ///
    /// SNAPSHOT-DRIVEN, the way UIKit's own interactive dismissals work:
    /// at drag start the page is captured as an image and THE PIXELS are
    /// what follow the finger (rounded, shadowed, over the dim). SwiftUI
    /// re-applies safe-area layout the moment a live page is offset —
    /// content visibly reflowed inside the moving card on every drag
    /// start (the "clipping pop"); a bitmap cannot reflow.
    private var closetDismissDrag: some Gesture {
        // GLOBAL coordinate space: the header is inside the view we offset, so a
        // .local translation would move WITH the offset and feed back into itself
        // (the frantic jitter). Global = the finger's actual screen movement.
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                guard selectedItem == nil, !isCommittingDismiss else { return }
                if dragSnapshot == nil, v.translation.height > 0 {
                    dragSnapshot = containerRef.snapshot()
                }
                closetDragOffset = max(0, v.translation.height)
            }
            .onEnded { v in
                guard selectedItem == nil, !isCommittingDismiss else { return }
                if v.translation.height > 120 || v.predictedEndTranslation.height > 350 {
                    // Commit: finish the slide OURSELVES on the snapshot,
                    // then drop the cover with animations disabled — the
                    // system dismissal would otherwise re-animate the
                    // (reflowed) live page from the top.
                    isCommittingDismiss = true
                    withAnimation(.easeIn(duration: 0.22)) {
                        closetDragOffset = UIScreen.main.bounds.height
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            if let onClose { onClose() } else { dismiss() }
                        }
                    }
                } else {
                    // Cancel: spring the snapshot back flat, then swap the
                    // (identical-pixels) live page back in.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        closetDragOffset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard closetDragOffset == 0 else { return }
                        dragSnapshot = nil
                    }
                }
            }
    }


    /// Same look as the public-feed search bar (appCard 14 / search icon /
    /// 13pt), but a live text field that filters the grid.
    private var searchBar: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .search, size: 14, color: AppPalette.textFaint)
            TextField("Search your closet", text: $searchText)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textStrong)
                .tint(AppPalette.textStrong)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppPalette.textFaint)
                }
                .buttonStyle(SolidPressButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, LayoutMetrics.small)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allItems.isEmpty {
            // Keep the closet chrome (search + categories) so an empty closet
            // still reads as a real, just-unpopulated closet. The message stays
            // centered on the page via the ZStack (the bars don't push it down).
            ZStack {
                emptyState
                VStack(spacing: 0) {
                    searchBar
                    filterBar
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(spacing: 0) {
                searchBar
                filterBar
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            ScrollOffsetObserver(onScroll: { _ in }, onScrollViewAttach: { scrollView in
                // Two-finger touches can never scroll — set ONCE.
                scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
                scrollBox.scrollView = scrollView
            })
            .frame(width: 0, height: 0)

            // The whole page (grid or empty state) is ONE animated unit, keyed
            // by the active filter. On a filter change the entire layer
            // transitions together — a directional slide on swipe, a scale+fade
            // on tap — so individual tiles never animate on their own (no
            // bottom-up reflow).
            Group {
                if filteredItems.isEmpty {
                    noMatchesState
                        .padding(.top, LayoutMetrics.xLarge)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredItems) { item in
                            Button {
                                // Ignore the stray tap that a finger-lift after a
                                // pinch can register.
                                guard !isPinching else { return }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                tapAnchor = anchorPoint(for: item.id)
                                // Bump the open token so every open builds a FRESH
                                // lightbox — a rapid open/close/reopen can otherwise
                                // reuse the instance with stale drag/offset state
                                // (the card opening half-shifted-down).
                                lightboxOpenToken += 1
                                // iOS app-launch feel: springs up from the tile and
                                // settles softly — snappy and light, not rubbery.
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    selectedItem = item
                                }
                            } label: {
                                WardrobeItemCell(
                                    item: item,
                                    showCategory: columnCount <= 2 && categoryFilter == nil && statusFilter == nil,
                                    showWishlistTag: columnCount <= 2,
                                    isHeroActive: selectedItem?.id == item.id
                                )
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: CellFrameKey.self,
                                            value: [item.id: proxy.frame(in: .global)]
                                        )
                                    }
                                )
                            }
                            .buttonStyle(SolidPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)
                    // Clear the home indicator for the LAST items (the scroll
                    // view itself extends through the bottom safe area below).
                    .padding(.bottom, 40)
                    // Zoom from the pinch focal point, not the content center.
                    .scaleEffect(pinchScale, anchor: pinchAnchor)
                    // Gesture lives on the grid so `startAnchor` is in the grid's
                    // own coordinate space (the finger midpoint). High priority so
                    // a two-finger pinch wins over the ScrollView's scroll instead
                    // of the scroll hijacking it.
                    .highPriorityGesture(zoomGesture)
                }
            }
            .id(gridIdentity)
            .transition(gridTransition)
        }
        .scrollIndicators(.hidden)
        .onPreferenceChange(CellFrameKey.self) { cellFrames = $0 }
        // Top fade as a lightweight OVERLAY (background colour → clear) over
        // just the top edge — so items dissolve under the pills WITHOUT
        // masking the whole ScrollView (which was clipping the bottom).
        // Content now extends fully to the bottom of the viewport.
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [AppPalette.groupedBackground, AppPalette.groupedBackground.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 22)
            .allowsHitTesting(false)
        }
        // Disable scrolling the moment a second finger lands, so a pinch is
        // never read as a scroll. One-finger scrolling is unaffected.
        // Transient pinch lock goes through the pan recognizer
        // (see syncScrollLock) — flapping scrollDisabled mid-touch
        // wedged the pan.
        // Horizontal flick walks the category pills, simultaneously with the
        // vertical scroll (only horizontal-dominant swipes act).
        .simultaneousGesture(categorySwipe)
        // Extend the grid THROUGH the bottom safe area so it fills to the
        // physical bottom of the screen — no background strip / clip line
        // above the home indicator.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(
            TouchCountReporter { count in
                let down = count >= 2
                if down != twoFingersDown { twoFingersDown = down }
                scrollBox.setScrollLocked(down)
            }
        )
        .onChange(of: closetScenePhase) { _, phase in
            // Backgrounding cancels touches system-wide; if the app
            // resigns mid-pinch the recognizer-level lock can be left
            // engaged with no flag showing it — the "leave the app,
            // come back, it's a bit frozen" report. Foregrounding =
            // no fingers down: unlock unconditionally.
            guard phase == .active else { return }
            twoFingersDown = false
            scrollBox.resetPanRecognizer()
        }
    }

    /// Pinch out → fewer/bigger tiles; pinch in → more/smaller. Mirrors the
    /// Photos app: the grid scales live under your fingers, then springs to
    /// the new column count when you let go. Two-finger pinch coexists with
    /// one-finger scroll.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                pinchAnchor = value.startAnchor   // finger midpoint
                if pinchStartColumns == nil { pinchStartColumns = columnCount }
                let start = Double(pinchStartColumns ?? columnCount)
                // Continuous desired column count (zoom out → bigger tiles →
                // fewer columns).
                let raw = start / Double(value.magnification)
                let lo = Double(Self.minColumns), hi = Double(Self.maxColumns)
                // Rubber-band past the limits so the extremes (2 / 4 cols)
                // still have an overshoot to spring back from on release.
                let effective: Double
                if raw < lo { effective = lo - (lo - raw) * 0.28 }
                else if raw > hi { effective = hi + (raw - hi) * 0.28 }
                else { effective = raw }
                let whole = min(Self.maxColumns, max(Self.minColumns, Int(raw.rounded())))
                if whole != columnCount {
                    columnCount = whole          // steps 2→3→4 mid-pinch
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                // Compensating scale (overshoots past the limits → bounce).
                pinchScale = CGFloat(Double(columnCount) / effective)
            }
            .onEnded { _ in
                pinchStartColumns = nil
                // Settle with an underdamped spring so the end of the zoom has
                // a light, organic bounce.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { pinchScale = 1 }
                // Keep `isPinching` true a beat longer so the finger-lift
                // doesn't register as a tap (opening an item) and scrolling
                // doesn't snap back mid-settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    isPinching = false
                }
            }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        // One row: All · categories · Wishlist (status, not a category).
        // Tappable, and also driven by horizontal swipes on the grid — the
        // active pill auto-scrolls into view whenever the selection changes.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "All", isOn: categoryFilter == nil && statusFilter == nil) {
                        categoryFilter = nil
                        statusFilter = nil
                    }
                    .id("all")
                    // Wishlist right after All — the highest-value filter,
                    // always present (even on an empty closet) so people
                    // know it exists and where saved items will land.
                    chip(title: "Wishlist", isOn: statusFilter == .wishlist) {
                        categoryFilter = nil
                        statusFilter = (statusFilter == .wishlist) ? nil : .wishlist
                    }
                    .id("wishlist")
                    ForEach(availableCategories, id: \.self) { cat in
                        chip(title: cat.label, isOn: categoryFilter == cat && statusFilter == nil) {
                            statusFilter = nil
                            categoryFilter = (categoryFilter == cat) ? nil : cat
                        }
                        .id(cat.rawValue)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
            }
            .onChange(of: gridIdentity) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(currentTabID, anchor: .center)
                }
            }
        }
        .padding(.top, LayoutMetrics.xSmall)
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Tapping a pill uses the quiet scale+fade (no direction).
            insertionEdge = nil
            withAnimation(.easeInOut(duration: 0.3)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.white : AppPalette.textMuted)
                .padding(.horizontal, 14)
                .frame(height: 34)
                // Selected: solid dark fill on top of the frosted capsule.
                .background {
                    if isOn {
                        Capsule(style: .continuous).fill(AppPalette.textStrong)
                    }
                }
                // Unselected: the app's standard frosted-glass capsule (same
                // treatment as TagPill / appCapsule everywhere else).
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    // MARK: - Category swipe

    /// The ordered filter "tabs" the swipe walks through — matches the pill
    /// row exactly: All · each present category · Wishlist (when present).
    private enum FilterTab: Equatable {
        case all
        case category(WardrobeCategory)
        case wishlist
    }

    private var filterTabs: [FilterTab] {
        // Order matches the pill row: All · Wishlist · categories.
        var tabs: [FilterTab] = [.all, .wishlist]
        tabs += availableCategories.map(FilterTab.category)
        return tabs
    }

    private var currentTabIndex: Int {
        if statusFilter == .wishlist {
            return filterTabs.firstIndex(of: .wishlist) ?? 0
        }
        if let categoryFilter {
            return filterTabs.firstIndex(of: .category(categoryFilter)) ?? 0
        }
        return 0
    }

    /// `id` of the currently-selected pill, for auto-scrolling it into view.
    private var currentTabID: String {
        if statusFilter == .wishlist { return "wishlist" }
        if let categoryFilter { return categoryFilter.rawValue }
        return "all"
    }

    private func applyTab(_ tab: FilterTab) {
        switch tab {
        case .all:
            categoryFilter = nil
            statusFilter = nil
        case .category(let c):
            statusFilter = nil
            categoryFilter = c
        case .wishlist:
            categoryFilter = nil
            statusFilter = .wishlist
        }
    }

    /// Step one tab left/right (clamped at the ends). Unlike a pill tap, the
    /// grid pages in directionally — swipe left (next) → new items enter from
    /// the right; swipe right (prev) → from the left.
    private func advanceTab(by delta: Int) {
        let tabs = filterTabs
        guard tabs.count > 1 else { return }
        let next = currentTabIndex + delta
        guard next >= 0, next < tabs.count else { return }
        insertionEdge = delta > 0 ? .trailing : .leading
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.32)) { applyTab(tabs[next]) }
    }

    /// Whole-grid enter/exit transition on a filter change. A swipe sets
    /// `insertionEdge`, so the page slides in from the swiped side and the old
    /// one slides out the opposite way (a clean page turn — purely horizontal).
    /// A tap leaves it `nil`, giving a quiet scale+fade instead.
    private var gridTransition: AnyTransition {
        guard let insertionEdge else {
            return .scale(scale: 0.96).combined(with: .opacity)
        }
        let removalEdge: Edge = insertionEdge == .trailing ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    /// Horizontal flick on the grid → previous/next category. Runs
    /// simultaneously with the vertical scroll, but commits ONLY on a
    /// decisively horizontal swipe (using flick velocity), so it never
    /// competes with vertical scrolling or the sheet's swipe-to-dismiss.
    private var categorySwipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard !isPinching, !twoFingersDown else { return }
                // Use the projected end point so a quick flick counts even if
                // short — but require the motion to be strongly horizontal.
                let dx = value.predictedEndTranslation.width
                let dy = value.predictedEndTranslation.height
                guard abs(dx) > 80, abs(dx) > abs(dy) * 2.5 else { return }
                advanceTab(by: dx < 0 ? 1 : -1)   // swipe left → next
            }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.medium) {
            AppIcon(glyph: .tshirt, size: 30, color: AppPalette.textMuted)
                .frame(width: 76, height: 76)
                .appCircle(shadowRadius: 0, shadowY: 0)
            VStack(spacing: 7) {
                Text("Your closet is empty")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text("Tag products on your outfits and they’ll collect here automatically. You can also save wishlist items from Safari — tap Share, then Yafa.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, LayoutMetrics.xLarge)

            // Desktop / Chrome-extension entry (live on the Web Store).
            Button { showGetExtension = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Save from your desktop")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            Text("No items match")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
            Text("Try a different filter or search.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Union + filtering

    /// The full deduped closet (products table ∪ inline outfit products).
    private var allItems: [WardrobeDisplayItem] {
        var seenNames = Set<String>()
        var seenURLs = Set<String>()
        var items: [WardrobeDisplayItem] = []

        func consider(name: String, url: String) -> Bool {
            let n = Self.nameKey(name)
            let u = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && seenNames.contains(n) { return false }
            if !u.isEmpty && seenURLs.contains(u) { return false }
            if !n.isEmpty { seenNames.insert(n) }
            if !u.isEmpty { seenURLs.insert(u) }
            return true
        }

        // Real products-table rows first (so they win dedup).
        for item in libraryItems {
            guard consider(name: item.name, url: item.imageURL) else { continue }
            // Stored category wins; fall back to keyword inference while
            // most rows still carry the default 'unknown' (decoded as
            // `.other`).
            let category = WardrobeCategory(rawValue: item.category)
                ?? WardrobeCategory.inferring(from: item.name)
            items.append(WardrobeDisplayItem(
                id: item.id.uuidString,
                name: item.name,
                imageURL: item.imageURL,
                category: category,
                status: WardrobeStatus(rawValue: item.status) ?? .owned,
                brand: item.brand,
                price: item.price,
                sourceURL: item.sourceURL,
                productId: item.id,
                isPolishing: item.isPolishing
            ))
        }

        // Inline outfit products (read-only, inferred category, owned).
        for outfit in store.outfits {
            for product in outfit.products ?? [] {
                guard let resolved = product.resolvedImageURL?.absoluteString else { continue }
                guard consider(name: product.name, url: resolved) else { continue }
                items.append(WardrobeDisplayItem(
                    id: "outfit-\(product.id)-\(outfit.id)",
                    name: product.name,
                    imageURL: resolved,
                    category: WardrobeCategory.inferring(from: product.name),
                    status: .owned,
                    brand: nil,
                    price: product.price,
                    sourceURL: product.shopLink,
                    productId: product.productId
                ))
            }
        }
        return items.filter { !deletedItemIDs.contains($0.id) }
    }

    private var filteredItems: [WardrobeDisplayItem] {
        let query = Self.nameKey(searchText)
        // A search spans the WHOLE closet — it ignores the selected category /
        // status filter so you find anything, not just within the current tab.
        if !query.isEmpty {
            return allItems.filter { item in
                let haystack = Self.nameKey(item.name) + " " + (item.brand.map(Self.nameKey) ?? "")
                return haystack.contains(query)
            }
        }
        return allItems.filter { item in
            if let categoryFilter, item.category != categoryFilter { return false }
            if let statusFilter, item.status != statusFilter { return false }
            return true
        }
    }

    /// Categories actually present, in a stable display order. When the closet
    /// is empty, show the FULL set so the empty state still conveys the structure
    /// the user is meant to populate.
    private var availableCategories: [WardrobeCategory] {
        guard !allItems.isEmpty else { return WardrobeCategory.displayOrder }
        let present = Set(allItems.map(\.category))
        return WardrobeCategory.displayOrder.filter { present.contains($0) }
    }

    /// Aggressive normalization shared by dedup + search: lowercase,
    /// trim, strip trailing "(2)" / " 3" counters, collapse spaces.
    private static func nameKey(_ s: String) -> String {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = lower.replacingOccurrences(
            of: "\\s*\\(?\\s*\\d+\\s*\\)?\\s*$",
            with: "",
            options: .regularExpression
        )
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Loading

    private func load() async {
        do {
            let items = try await WardrobeService.fetchCloset(userId: userId)
            await MainActor.run {
                libraryItems = items
                ClosetCache.items[userId] = items
                isLoading = false
                schedulePollIfPolishing()
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// While any item is still generating its thumbnail, re-fetch shortly
    /// after so the cut-out (and the sparkle dismissal) appear on their
    /// own. Self-cancelling: stops as soon as nothing is polishing.
    @MainActor
    private func schedulePollIfPolishing() {
        pollTask?.cancel()
        guard libraryItems.contains(where: { $0.isPolishing }) else { return }
        pollTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

// MARK: - Display model

/// UI-layer unification of a `products`-table `WardrobeItem` and an
/// inline `Outfit.products` entry. `productId` is non-nil only when
/// the item is backed by an editable `products` row.
struct WardrobeDisplayItem: Identifiable, Hashable {
    let id: String
    let name: String
    let imageURL: String
    let category: WardrobeCategory
    let status: WardrobeStatus
    let brand: String?
    let price: String?
    let sourceURL: String?
    let productId: UUID?
    /// True while a Share-Extension save is still having its FAL cut-out
    /// generated — drives the sparkle overlay in the cell.
    var isPolishing: Bool = false

    /// Resolves possibly-relative image paths against the site base URL
    /// (same as `Product.resolvedImageURL`).
    var resolvedImageURL: URL? {
        let trimmed = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let abs = URL(string: trimmed), abs.scheme != nil { return abs }
        let normalized = trimmed.hasPrefix("/")
            ? String(trimmed.dropFirst())
            : trimmed.replacingOccurrences(of: "^\\./?", with: "", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }
        return AppConfig.siteBaseURL.appendingPathComponent(normalized)
    }
}

/// Last-known closet rows per user, so reopening the closet (a fullScreenCover
/// that re-mounts WardrobeView each time) shows the products instantly instead
/// of a spinner while the network re-fetch runs in the background.
enum ClosetCache {
    @MainActor static var items: [UUID: [WardrobeItem]] = [:]
}

// MARK: - Cell

/// Collects each grid tile's global frame (keyed by item id) so the lightbox
/// can grow out of the exact tile that was tapped.
private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

/// Reports the lightbox scroll content's top offset (0 at rest, negative as it
/// scrolls up) so the sheet knows when it's pinned to the top.
private struct ScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Staggered top-to-bottom fade for the compact lightbox's sections.
/// Opacity-only and value-scoped, so it can never animate layout —
/// sections are laid out in their final positions from frame one and
/// simply fade in.
private struct LightboxRevealModifier: ViewModifier {
    let index: Int
    let revealed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .animation(
                .easeOut(duration: 0.4).delay(0.08 + Double(index) * 0.06),
                value: revealed
            )
    }
}

private extension View {
    func lightboxReveal(_ index: Int, revealed: Bool) -> some View {
        modifier(LightboxRevealModifier(index: index, revealed: revealed))
    }
}


private struct WardrobeItemCell: View {
    let item: WardrobeDisplayItem
    /// Show the category pill (only on the All filter, 2 columns).
    var showCategory: Bool = false
    /// Show the wishlist tag for wishlist items (2 columns).
    var showWishlistTag: Bool = false
    /// True while THIS item is open in the lightbox — the cell holds its space
    /// (clear) so the growing lightbox owns the visual.
    var isHeroActive: Bool = false

    private var isWishlist: Bool { item.status == .wishlist }

    /// Drives the generating sparkles. Tracks `isPolishing`, but *lingers*
    /// after polishing ends until the cut-out image has actually loaded — so
    /// the sparkles hand off to the finished thumbnail instead of vanishing
    /// onto the raw photo a beat early.
    @State private var showSparkles = false
    @State private var lingerTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .center, spacing: 7) {
            // Product floats with no card behind it (minimal). A fixed
            // aspect box scales the tile with the column width so the grid
            // reflows cleanly when you pinch-zoom.
            Color.clear
                .aspectRatio(0.85, contentMode: .fit)
                .overlay {
                    if isHeroActive {
                        // Image is flying in the lightbox — hold its space here.
                        Color.clear
                    } else {
                        TrimmedRemoteImage(url: item.resolvedImageURL, contentPadding: 6, onLoad: {
                            // Cut-out finished loading — retire the sparkles now
                            // (only once polishing has actually ended).
                            if !item.isPolishing {
                                lingerTask?.cancel()
                                showSparkles = false
                            }
                        })
                            // Keep the raw photo dimmed under the sparkles until
                            // the cut-out is ready, so they resolve together.
                            .opacity(showSparkles ? 0.25 : 1)
                    }
                }
                .overlay {
                    // The app's generation Lottie sparkles — shown while
                    // polishing, then held until the cut-out loads (see above).
                    if showSparkles {
                        GenerationStarField(starSize: 250, interactive: false)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showSparkles)
                .onAppear { showSparkles = item.isPolishing }
                .onChange(of: item.isPolishing) { _, nowPolishing in
                    if nowPolishing {
                        lingerTask?.cancel()
                        showSparkles = true
                    } else {
                        // Linger until the cut-out loads (onLoad above); cap it
                        // so a failed polish never sparkles forever.
                        lingerTask?.cancel()
                        lingerTask = Task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            await MainActor.run { showSparkles = false }
                        }
                    }
                }

            // Quiet, centered caption — the garment is the hero.
            Text(item.name)
                .font(.system(size: 11.5))
                .foregroundStyle(AppPalette.textMuted)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Wishlist items get a distinct tag; owned items show category.
            if isWishlist, showWishlistTag {
                wishlistPill
                    .scaleEffect(0.85)
            } else if showCategory, item.category != .other {
                TagPill(tag: item.category.label)
                    .scaleEffect(0.85)
            }
        }
    }

    /// Mirrors `TagPill` exactly — same clean white capsule and neutral
    /// text — distinguished only by a soft purple glow behind it (the same
    /// `aiAccent` glow used on the auto-tagging UI).
    private var wishlistPill: some View {
        Text("WISHLIST")
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .frame(height: 36)
            .appCapsule(shadowRadius: 0, shadowY: 0)
            .shadow(color: AppPalette.aiAccent.opacity(0.35), radius: 14, y: 0)
    }
}

// MARK: - Item detail / edit

/// Tap-to-edit sheet for a wardrobe item.
///
/// Two modes, keyed on whether the item is backed by a `products`
/// row (`item.productId != nil`):
///   • Backed → edits update that row in place.
///   • Inline (an `Outfit.products` entry not yet in the closet) →
///     saving *promotes* it by creating a real `products` row. The
///     union dedup then collapses the inline copy into the new row,
///     so it becomes editable from then on.
/// Tap-to-edit "lightbox" for a closet product. Opens in place — the card grows
/// out of the tapped tile and shrinks back on dismiss — instead of a
/// sheet-on-sheet. Drag the header up to go full screen, down to collapse.
private struct ProductLightbox: View {
    let item: WardrobeDisplayItem
    let userId: UUID
    /// Dismiss the lightbox (parent reverses the grow back into the tile).
    var onClose: () -> Void
    /// Called after a successful save so the closet can reload.
    var onChanged: () async -> Void
    /// Called after a successful delete so the closet can drop it locally.
    var onDeleted: () -> Void
    /// The whole closet — pool for the "similar items" row.
    var similarCandidates: [WardrobeDisplayItem] = []
    /// Tap on a similar item → parent swaps the lightbox to it.
    var onSelectSimilar: (WardrobeDisplayItem) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @Environment(OutfitStore.self) private var store

    @State private var name: String
    @State private var category: WardrobeCategory
    @State private var brand: String
    @State private var price: String
    @State private var sourceURL: String
    @State private var status: WardrobeStatus
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirm = false
    /// Inset card vs. edge-to-edge full screen.
    @State private var isFull = false
    /// Whether the scroll content is pinned to the top (gates pull-to-dismiss).
    @State private var atTop = true
    /// Live scroll offset of the editor form (0 at rest, negative
    /// scrolled) — the hero image rides it 1:1 in full mode.
    @State private var scrollTop: CGFloat = 0
    /// Live downward offset while pulling the full sheet down to dismiss.
    @State private var sheetDrag: CGFloat = 0
    /// Latches whether the in-progress drag began in full-screen mode, so a
    /// single card-mode drag can only expand (never also dismiss).
    @State private var dragStartFull: Bool?
    /// Translation captured the moment the content reaches the top mid-drag, so
    /// the sheet only moves by the OVERSCROLL past the top — a continuous pull
    /// scrolls to the top and then keeps going into a close, while a drag that
    /// never reaches the top leaves the sheet put.
    @State private var dragRefAtTop: CGFloat?
    /// Captured ONCE on appear so the layout is stable — reading window insets
    /// every render jittered the grow (scene ordering isn't deterministic).
    @State private var insetTop: CGFloat = 47
    @State private var insetBottom: CGFloat = 34
    /// Defer the heavy TAGGED ON carousel (multiple outfit images that eager-load)
    /// until the open/close scale spring has settled — building/loading it during
    /// the spring competes for the main thread and jitters the animation.
    @State private var showTaggedOn = false
    /// Similar items re-ranked by on-device VISUAL similarity (feature
    /// print + dominant color). nil until the async pass lands — the
    /// row stays hidden until its FINAL order is known, so it never
    /// visibly reorders in front of the user.
    @State private var visuallyRankedSimilar: [WardrobeDisplayItem]?
    /// Drives the compact card's staggered section fade-in.
    @State private var contentRevealed = false

    /// Real device safe-area insets from the key window. We position content
    /// manually because the overlay ignores the safe area (so SwiftUI reports
    /// zero insets inside it).
    private var screenInsets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets)
            ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }

    init(
        item: WardrobeDisplayItem,
        userId: UUID,
        onClose: @escaping () -> Void,
        onChanged: @escaping () async -> Void,
        onDeleted: @escaping () -> Void = {},
        similarCandidates: [WardrobeDisplayItem] = [],
        onSelectSimilar: @escaping (WardrobeDisplayItem) -> Void = { _ in }
    ) {
        self.item = item
        self.userId = userId
        self.onClose = onClose
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        self.similarCandidates = similarCandidates
        self.onSelectSimilar = onSelectSimilar
        _name = State(initialValue: item.name)
        _category = State(initialValue: item.category)
        _brand = State(initialValue: item.brand ?? "")
        _price = State(initialValue: item.price ?? "")
        _sourceURL = State(initialValue: item.sourceURL ?? "")
        _status = State(initialValue: item.status)
    }

    var body: some View {
        ZStack {
            ZStack(alignment: .top) {
                // ONE content tree for both modes. The hero image is a
                // single view that NEVER unmounts — its frame morphs
                // between preview (170) and editor (200) inside the
                // expand spring, which is what makes the transition
                // read as one continuous product. Only the content
                // below it swaps (crossfade): compact sections vs the
                // scrolling editor form.
                unifiedContent
                // The ONLY pinned chrome — X (and Save, full mode only).
                pinnedControls
            }
            .background(AppPalette.groupedBackground)
            // Card → square edge-to-edge as it goes full screen.
            .clipShape(RoundedRectangle(cornerRadius: isFull ? 0 : 28, style: .continuous))
            .padding(.horizontal, isFull ? 0 : 10)
            .shadow(color: .black.opacity(isFull ? 0 : 0.18), radius: isFull ? 0 : 30, y: isFull ? 0 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // Follow the finger when pulling the FULL sheet down to
            // dismiss — the compact card is fixed and never follows.
            .offset(y: isFull ? sheetDrag : 0)
        }
        // Fill the screen via the parent overlay's safe-area bypass — NOT by
        // ignoring the safe area on this (scaling) view, which moved the grow
        // anchor and jittered the animation.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let i = screenInsets
            insetTop = i.top
            insetBottom = i.bottom
            // Mount the tagged-on carousel only after the open spring settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showTaggedOn = true }
        }
        .task(id: item.id) { await rankSimilarVisually() }
        // ONE unified gesture: in card mode any drag expands to full; in full
        // mode a pull-down at the very top dismisses. Simultaneous, so the
        // ScrollView still scrolls normally underneath it.
        .simultaneousGesture(sheetGesture)
        .alert("Remove from closet?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) { Task { await deleteItem() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes “\(item.name)” from your closet and untags it from any outfits it's on.")
        }
    }

    /// ONE tree for both modes. The hero image never unmounts — its
    /// frame morphs inside the expand spring, so the product is a
    /// single continuous element across preview ↔ editor. Below it,
    /// the compact sections and the scrolling editor form swap with a
    /// crossfade. (An earlier matchedGeometryEffect pair across the
    /// ScrollView boundary resolved unreliably and fell back to a
    /// fade — a never-unmounting view can't fail that way.)
    /// Hero block metrics for the current mode — the content below is
    /// indented by exactly this much so the image can live BEHIND it.
    private var heroTopPadding: CGFloat {
        isFull ? insetTop + LayoutMetrics.screenPadding + 44 + LayoutMetrics.small : 32
    }
    private var heroBlockHeight: CGFloat {
        heroTopPadding + (isFull ? 200 : 170)
    }

    private var unifiedContent: some View {
        ZStack(alignment: .top) {
            // (The "Edit item" title lives in `pinnedControls`, centered
            // on the X/Save row like the app's other sheet headers.)
            // Cap the hero's width as well as its height: with only a
            // fixed height, wide products (sandals, glasses) render at
            // full card width and dwarf tall/square ones.
            //
            // The hero still never unmounts (single continuous element
            // across preview <-> editor), but in FULL mode it now
            // RIDES the scroll: the form is inset by the hero block
            // and the image translates 1:1 with the scroll offset —
            // it scrolls away with the content instead of pinning on
            // top and clipping the first field.
            TrimmedRemoteImage(url: item.resolvedImageURL)
                .frame(maxWidth: 250)
                .frame(height: isFull ? 200 : 170)
                .frame(maxWidth: .infinity)
                .padding(.top, heroTopPadding)
                .offset(y: isFull ? min(0, scrollTop) : 0)
                .lightboxReveal(0, revealed: contentRevealed)
            if isFull {
                editorScroll
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: heroBlockHeight)
                    compactSections
                }
                .transition(.opacity)
            }
        }
        .onAppear { contentRevealed = true }
    }

    /// FULL mode: the form starts below the hero block and the hero
    /// scrolls away WITH it (see unifiedContent). A zero-size probe
    /// reports the content offset — it drives both the hero's ride
    /// and the pull-down-to-dismiss gesture's at-top check.
    private var editorScroll: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.large) {
                formCard
                statusSection
                if !sourceURL.isEmpty, let linkURL = URL(string: sourceURL) {
                    openLinkButton(linkURL)
                }
                if showTaggedOn { taggedOnSection }
                if let saveError {
                    Text(saveError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                deleteButton
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, heroBlockHeight + LayoutMetrics.large)
            // Clear the home indicator — as SCROLLABLE padding so the
            // last row reaches the very edge instead of clipping.
            .padding(.bottom, insetBottom + LayoutMetrics.large)
            // Tap anywhere on the page (but not on a field/control) to dismiss the
            // keyboard. Text fields consume their own taps, so they still focus.
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ScrollTopKey.self,
                        value: proxy.frame(in: .named("lightboxScroll")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "lightboxScroll")
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(ScrollTopKey.self) {
            atTop = $0 >= -1
            scrollTop = $0
        }
    }

    /// CARD mode sections below the hero: a plain VStack — intrinsic
    /// height, no scroll, no measurement. The card wraps this exactly,
    /// so every section is always fully visible and a vertical swipe
    /// can only mean expand / dismiss. Components mirror PublishSheet.
    ///
    /// Every section is mounted from the FIRST frame (fixed layout, no
    /// popping or reordering as the card opens) and revealed with a
    /// gentle top-to-bottom staggered fade. The one exception is the
    /// similar row, which appears only once its FINAL visually-ranked
    /// order is known — the card glides taller as it fades in.
    private var compactSections: some View {
        VStack(spacing: LayoutMetrics.medium) {
            compactIdentity
                .lightboxReveal(1, revealed: contentRevealed)
            compactShopSection
                .lightboxReveal(2, revealed: contentRevealed)
            compactSimilarSection
            compactTaggedOnSection
                .lightboxReveal(3, revealed: contentRevealed)
            Text("swipe up to edit")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
                .lightboxReveal(4, revealed: contentRevealed)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, LayoutMetrics.medium)
        // Bottom breathing room mirrors the hero's 32pt top inset.
        .padding(.bottom, 32)
    }

    /// Unified scroll/drag behaviour:
    ///   • card mode → drag UP expands to full; drag DOWN follows the finger and
    ///     dismisses (it must NOT expand on a downward drag)
    ///   • full + pinned to top → pulling down rubber-bands; a committed pull or
    ///     fast flick dismisses, otherwise it springs back
    private var sheetGesture: some Gesture {
        // Larger minimum distance so this gesture doesn't arbitrate with (and
        // stutter) every small scroll movement.
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { v in
                // Latch the full-vs-card intent at the start.
                if dragStartFull == nil { dragStartFull = isFull }
                let startedFull = dragStartFull ?? isFull

                guard startedFull else {
                    // CARD mode: the preview is FIXED in the center —
                    // it never follows the finger. Swipes still act as
                    // triggers (up → expand, down → dismiss), decided
                    // on release.
                    return
                }
                // FULL mode: the sheet only follows the OVERSCROLL past the top.
                if atTop, v.translation.height > 0 {
                    if dragRefAtTop == nil { dragRefAtTop = v.translation.height }
                    let past = v.translation.height - (dragRefAtTop ?? 0)
                    // Small dead zone before the sheet starts following, so a
                    // top-edge bounce while scrolling doesn't twitch the card.
                    sheetDrag = max(0, past - 8) * 0.6
                } else {
                    dragRefAtTop = nil
                    if sheetDrag != 0 { sheetDrag = 0 }
                }
            }
            .onEnded { v in
                let startedFull = dragStartFull ?? isFull
                let ref = dragRefAtTop
                dragStartFull = nil
                dragRefAtTop = nil

                let dy = v.translation.height
                let flick = v.predictedEndTranslation.height

                if !startedFull {
                    // CARD mode: pure triggers, no movement — up →
                    // expand into the editor, a committed down → close.
                    if dy < -55 || flick < -200 {
                        setExpanded(true)
                    } else if dy > 110 || flick > 350 {
                        onClose()
                    }
                    return
                }
                // FULL mode: dismiss on a committed OVERSCROLL past the top.
                if atTop, let ref {
                    let past = dy - ref
                    let flickPast = flick - ref
                    if past > 120 || flickPast > 320 {
                        onClose()
                        return
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { sheetDrag = 0 }
            }
    }

    private func setExpanded(_ full: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            isFull = full
        }
    }

    /// Resign first responder so a tap outside the keyboard / a field closes it.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// The only pinned controls — X (left) and Save (right). A short fade behind
    /// them lets scrolling content dissolve underneath instead of cutting hard.
    private var pinnedControls: some View {
        let topInset = (isFull ? insetTop : 0)
        // Same header pattern as the app's other sheets (e.g. the
        // Closet page): title centered ON the control row, X left,
        // action right.
        return ZStack {
            if isFull {
                Text("Edit item")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                // Float the same way as the app's other controls: an X circle button
                // and a white pill (fill + thin stroke + shadow) for Save.
                Button { onClose() } label: {
                    AppIcon(glyph: .xmark, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle()
                }
                .buttonStyle(SolidPressButtonStyle())
                Spacer()
                // Save only exists in the full editor — the compact card
                // is a read-only preview with nothing to save.
                if isFull {
                    Button { Task { await save() } } label: {
                        Text("Save")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSave ? AppPalette.textStrong : AppPalette.textFaint)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .appCapsule()
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .disabled(!canSave)
                }
            }
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        // Same breathing room above the buttons as the side padding.
        .padding(.top, topInset + LayoutMetrics.screenPadding)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Compact card mode (read-only preview)

    /// PublishSheet-style section label — identical to CAPTION /
    /// PRODUCTS so the two sheets read as one design system.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
    }

    /// Name (primary) + brand · price (muted) + category/status chips.
    private var compactIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            let sub = [item.brand ?? "", item.price ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
            }
            HStack(spacing: 6) {
                metaChip(item.category.label.uppercased())
                metaChip(item.status == .wishlist ? "WISHLIST" : "OWNED")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
    }

    /// THE action of the preview: link out to the product. Mirrors
    /// the PublishSheet's shop-link row (link icon + URL text), read-
    /// only with a link-out arrow. Hidden when there's no link.
    @ViewBuilder
    private var compactShopSection: some View {
        if !sourceURL.isEmpty, let linkURL = URL(string: sourceURL) {
            VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
                sectionLabel("SHOP")
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openURL(linkURL)
                } label: {
                    HStack(spacing: LayoutMetrics.xSmall) {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.textSecondary)
                        Text(linkURL.host?.replacingOccurrences(of: "www.", with: "") ?? sourceURL)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .padding(LayoutMetrics.medium)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
                .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            }
        }
    }

    /// Same-category neighbours, most-similar first. For a WISHLIST
    /// item the pool is what the user already OWNS — "do I already
    /// have something like this?" is the whole point of the row. For
    /// an owned item it's the rest of the closet. Similarity = same
    /// category, ranked by brand match + name-word overlap.
    private var similarItems: [WardrobeDisplayItem] {
        let mySubType = Self.inferredSubType(of: item.name)
        let pool = similarCandidates.filter { candidate in
            candidate.id != item.id
                && candidate.category == item.category
                // Category alone is too coarse ("accessories" holds
                // bags AND hats) — when both names reveal a sub-type,
                // they must agree. Unknown sub-types pass through and
                // let the visual ranking decide.
                && Self.subTypesCompatible(mySubType, Self.inferredSubType(of: candidate.name))
                && (item.status != .wishlist || candidate.status == .owned)
        }
        guard !pool.isEmpty else { return [] }

        let itemBrand = (item.brand ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let itemWords = Self.significantWords(item.name)
        func score(_ candidate: WardrobeDisplayItem) -> Int {
            var s = 0
            if !itemBrand.isEmpty,
               (candidate.brand ?? "").trimmingCharacters(in: .whitespaces).lowercased() == itemBrand {
                s += 3
            }
            s += Self.significantWords(candidate.name).intersection(itemWords).count
            return s
        }
        return Array(pool.sorted { score($0) > score($1) }.prefix(8))
    }

    /// Re-ranks the (category/status-filtered) candidates by how the
    /// items LOOK: Vision feature-print distance + dominant-color
    /// distance against this item's image. Runs off-main; signatures
    /// are cached per image, so revisits are instant. The row is only
    /// published ONCE, in its final order — never shown-then-reordered.
    /// If the visual pass can't run (offline, bad image), it falls
    /// back to the heuristic (brand/name) order rather than no row.
    private func rankSimilarVisually() async {
        let pool = similarItems
        guard !pool.isEmpty else { return }

        func publish(_ list: [WardrobeDisplayItem]) async {
            await MainActor.run {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    visuallyRankedSimilar = list
                }
            }
        }

        guard pool.count > 1,
              let myURL = item.resolvedImageURL,
              let mySig = await ProductSimilarityService.shared.signature(for: myURL) else {
            await publish(pool)
            return
        }

        var scored: [(item: WardrobeDisplayItem, distance: Float)] = []
        for candidate in pool {
            guard let url = candidate.resolvedImageURL,
                  let sig = await ProductSimilarityService.shared.signature(for: url) else { continue }
            scored.append((candidate, ProductSimilarityService.distance(mySig, sig)))
        }
        guard !scored.isEmpty else {
            await publish(pool)
            return
        }
        // "Similar" means SIMILAR: anything past the cutoff is dropped,
        // not just ranked last. Two gates — an absolute ceiling, and a
        // relative band around the best match (if your closet has a
        // near-twin, distant items don't get to tag along). An empty
        // result hides the row — better no suggestions than a bucket
        // hat next to a suede bag.
        let sorted = scored.sorted { $0.distance < $1.distance }
        let best = sorted[0].distance
        let ranked = sorted
            .filter {
                $0.distance < ProductSimilarityService.similarityCutoff
                    && $0.distance < best + ProductSimilarityService.similarityBand
            }
            .map(\.item)
        await publish(ranked)
    }

    /// Lowercased name words worth matching on (drops 1–2 letter
    /// filler like "a"/"of").
    private static func significantWords(_ name: String) -> Set<String> {
        Set(
            name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }

    /// Item-type lexicon: names usually say what a thing IS ("Brown
    /// Suede Bag", "Bucket Hat", "Ruffled Lace Bralette"). Used to
    /// keep types apart inside coarse categories — especially OTHER,
    /// which lumps everything unclassified together.
    private static let subTypeLexicon: [(type: String, words: Set<String>)] = [
        ("bag", ["bag", "purse", "tote", "clutch", "crossbody", "handbag", "satchel", "hobo", "baguette", "backpack"]),
        ("hat", ["hat", "cap", "beanie", "bucket", "beret", "fedora"]),
        ("belt", ["belt"]),
        ("scarf", ["scarf", "bandana", "shawl"]),
        ("glasses", ["sunglasses", "glasses", "shades"]),
        ("jewelry", ["necklace", "ring", "bracelet", "earring", "earrings", "chain", "pendant", "brooch"]),
        ("boot", ["boot", "boots"]),
        ("heel", ["heel", "heels", "pump", "pumps", "stiletto", "stilettos"]),
        ("sneaker", ["sneaker", "sneakers", "trainer", "trainers", "runner", "runners"]),
        ("sandal", ["sandal", "sandals", "slide", "slides", "mule", "mules"]),
        ("flat", ["loafer", "loafers", "flat", "flats", "ballerina", "mary", "janes"]),
        ("swim", ["bikini", "swimsuit", "swim", "swimwear", "trunks", "onepiece"]),
        ("underwear", ["bra", "bralette", "brief", "briefs", "panty", "panties", "thong", "lingerie", "boxer", "boxers"]),
        ("top", ["shirt", "tee", "tshirt", "top", "jersey", "blouse", "sweater", "knit", "hoodie", "cardigan", "tank", "cami", "camisole", "polo", "turtleneck", "vest", "bodysuit"]),
        ("outerwear", ["jacket", "coat", "blazer", "parka", "trench", "puffer", "windbreaker"]),
        ("bottom", ["pants", "jeans", "trousers", "shorts", "skirt", "leggings", "joggers", "sweatpants", "culottes"]),
        ("dress", ["dress", "gown", "jumpsuit", "romper"]),
        ("socks", ["sock", "socks", "tights", "stockings"]),
    ]

    private static func inferredSubType(of name: String) -> String? {
        let words = significantWords(name)
        return subTypeLexicon.first { !words.isDisjoint(with: $0.words) }?.type
    }

    /// Both known → must match; either unknown → compatible (visual
    /// ranking sorts it out).
    private static func subTypesCompatible(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    /// "You already own something like this" — the compact card's
    /// discovery row. Tapping a tile swaps the lightbox to that item.
    @ViewBuilder
    private var compactSimilarSection: some View {
        let similar = visuallyRankedSimilar ?? []
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
                sectionLabel(item.status == .wishlist ? "SIMILAR — ALREADY IN YOUR CLOSET" : "SIMILAR IN YOUR CLOSET")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(similar) { candidate in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onSelectSimilar(candidate)
                            } label: {
                                VStack(spacing: 6) {
                                    TrimmedRemoteImage(url: candidate.resolvedImageURL)
                                        .frame(width: 74, height: 74)
                                        .padding(6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.white)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                                        )
                                    Text(candidate.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(AppPalette.textMuted)
                                        .lineLimit(1)
                                        .frame(width: 86)
                                }
                            }
                            .buttonStyle(SolidPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
                .padding(.horizontal, -LayoutMetrics.screenPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    /// Compact TAGGED ON strip — smaller thumbnails than the full
    /// editor's carousel, same edge-bleed scroll.
    @ViewBuilder
    private var compactTaggedOnSection: some View {
        let outfits = taggedOutfits
        if !outfits.isEmpty {
            VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
                sectionLabel("TAGGED ON")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(outfits) { outfit in
                            RotatableOutfitImage(outfit: outfit, height: 96, draggable: false, eagerLoad: true)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
                .padding(.horizontal, -LayoutMetrics.screenPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    private var deleteButton: some View {
        Button(role: .destructive) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showDeleteConfirm = true
        } label: {
            Text("Delete")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(SolidPressButtonStyle())
        .padding(.top, LayoutMetrics.xSmall)
    }

    private func deleteItem() async {
        do {
            try await WardrobeService.deleteItem(productId: item.productId, name: item.name)
            // Fits already loaded in memory must drop the product too —
            // the server-side untag only covers the next fresh fetch.
            store.removeProductEverywhere(productId: item.productId, name: item.name)
            onDeleted()
            await onChanged()
            onClose()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// All editable fields in one inset card with hairline row dividers
    /// (iOS grouped-form feel) instead of a stack of separate cards.
    private var formCard: some View {
        VStack(spacing: 0) {
            formRow("Name") {
                TextField("Item name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            rowDivider
            HStack {
                Text("Category")
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                Spacer(minLength: 16)
                Menu {
                    ForEach(WardrobeCategory.displayOrder, id: \.self) { c in
                        Button(c.label) { category = c }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(category.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppPalette.textStrong)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            rowDivider
            formRow("Brand") {
                TextField("Add brand", text: $brand)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            rowDivider
            formRow("Link") {
                TextField("Add URL", text: $sourceURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }
        .padding(.vertical, 2)
        // Same frosted-glass card as the carousel's product detail card.
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
    }

    private func formRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.textMuted)
            Spacer(minLength: 16)
            content()
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.textStrong)
                .tint(AppPalette.textStrong)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppPalette.cardBorder)
            .frame(height: 0.75)
            .padding(.leading, 16)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("STATUS")
            Picker("", selection: $status) {
                Text("Owned").tag(WardrobeStatus.owned)
                Text("Wishlist").tag(WardrobeStatus.wishlist)
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLinkButton(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "bag")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open product link")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppPalette.textStrong)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Mini carousel of the outfits this product is currently tagged on.
    @ViewBuilder
    private var taggedOnSection: some View {
        let outfits = taggedOutfits
        if !outfits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("TAGGED ON")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(outfits) { outfit in
                            RotatableOutfitImage(outfit: outfit, height: 150, draggable: false, eagerLoad: true)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    // Re-inset the items so the first aligns with the content;
                    // combined with the negative padding below, the carousel
                    // bleeds to the screen edges instead of clipping early.
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
                // Cancel the page's horizontal padding so the scroll is full-width.
                .padding(.horizontal, -LayoutMetrics.screenPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taggedOutfits: [Outfit] {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let myName = norm(item.name)
        let myURL = item.resolvedImageURL?.absoluteString
        return store.outfits.filter { outfit in
            (outfit.products ?? []).contains { p in
                if let pid = item.productId, let ppid = p.productId { return ppid == pid }
                if !myName.isEmpty && norm(p.name) == myName { return true }
                if let myURL, p.resolvedImageURL?.absoluteString == myURL { return true }
                return false
            }
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let pid = item.productId {
                try await WardrobeService.updateItem(
                    id: pid,
                    name: trimmed,
                    category: category.rawValue,
                    brand: brand,
                    price: price,
                    sourceURL: sourceURL,
                    status: status
                )
            } else {
                _ = try await WardrobeService.createItem(
                    userId: userId,
                    name: trimmed,
                    imageURL: item.imageURL,
                    category: category.rawValue,
                    brand: brand.isEmpty ? nil : brand,
                    price: price.isEmpty ? nil : price,
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    status: status
                )
            }
            await onChanged()
            onClose()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}


// MARK: - Get the Chrome extension

/// Explains the Yafa browser extension and how to get it. Until the extension
/// is approved on the Chrome Web Store, it shows a "Coming soon" state instead
/// of a live button. Flip `isLive` to true (and the URL is already correct)
/// once the listing is published.
struct GetExtensionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isPreparing = false

    /// Set to true once the extension is live on the Web Store.
    private let isLive = true
    private let storeURL = URL(string: "https://chromewebstore.google.com/detail/cjeoackfbfomhbcneibfpfddapklgopg")!

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(title: "CHROME EXTENSION") { dismiss() }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.small)

            VStack(spacing: LayoutMetrics.large) {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppPalette.textStrong)
                    .frame(width: 64, height: 64)
                    .appCircle(shadowRadius: 0, shadowY: 0)
                Text("Save from your desktop")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text("Shopping on your laptop? Add the Yafa extension to Chrome to save products as you browse — they sync straight to your closet here.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, LayoutMetrics.large)

            VStack(alignment: .leading, spacing: 14) {
                stepRow("1", "On your computer, add the Yafa extension to Chrome")
                stepRow("2", "Click the plus icon on any product page to save the item")
                stepRow("3", "Tap “Add to Yafa” to send it to your closet")
            }
            .padding(LayoutMetrics.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)

            Spacer()

            if isLive {
                // Chrome extensions install on DESKTOP only, but the user is on
                // their phone — so the primary action SHARES the listing link
                // (AirDrop to their Mac / Messages / Copy) to get it onto their
                // computer, rather than opening a store page they can't install
                // from here.
                // Present the share sheet ourselves (not ShareLink) so the
                // button can show a spinner while the system warms the activity
                // sheet up — it has an unavoidable cold-start delay on first use.
                Button {
                    guard !isPreparing else { return }
                    isPreparing = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    presentShareSheet()
                } label: {
                    Group {
                        if isPreparing {
                            ProgressView().tint(AppPalette.textMuted)
                        } else {
                            HStack(spacing: 7) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("SEND LINK TO YOUR COMPUTER")
                                    .font(.system(size: 12, weight: .semibold))
                                    .tracking(1.5)
                            }
                            .foregroundStyle(AppPalette.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .appCapsule(shadowRadius: 6, shadowY: 3)
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(isPreparing)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Coming soon to the Chrome Web Store")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppPalette.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppPalette.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            }
            }
            .padding(.bottom, LayoutMetrics.large)
            .padding(.horizontal, LayoutMetrics.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.groupedBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    /// Presents the system share sheet directly so the button can show a
    /// spinner until it finishes appearing (the `present` completion fires
    /// after the presentation animation). Clears the spinner then.
    private func presentShareSheet() {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController
        else { isPreparing = false; return }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let activityVC = UIActivityViewController(activityItems: [storeURL], applicationActivities: nil)
        // iPad: anchor the popover near the bottom of the presenting view.
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(activityVC, animated: true) { isPreparing = false }
    }

    private func stepRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(AppPalette.textStrong))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Visual similarity

/// On-device visual similarity for closet items. Two signals, computed
/// once per image and cached for the session:
///   1. Vision feature print — Apple's image embedding; captures
///      shape, texture, and overall look in one distance metric.
///   2. Dominant color over NON-TRANSPARENT pixels — product images
///      are background-removed cutouts, so this is the product's
///      actual color. Added explicitly so a brown bag ranks brown
///      bags above black bags of the same silhouette.
/// No server round-trips, no cost — everything runs locally.
private actor ProductSimilarityService {
    static let shared = ProductSimilarityService()

    struct Signature {
        let featurePrint: VNFeaturePrintObservation
        let color: SIMD3<Float>
    }

    private var cache: [String: Signature] = [:]
    private var failed: Set<String> = []

    func signature(for url: URL) async -> Signature? {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let cg = UIImage(data: data)?.cgImage else {
            failed.insert(key)
            return nil
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else {
            failed.insert(key)
            return nil
        }
        let sig = Signature(
            featurePrint: observation,
            color: Self.averageOpaqueColor(cg) ?? SIMD3(0.5, 0.5, 0.5)
        )
        cache[key] = sig
        return sig
    }

    /// 0 = identical, larger = more different. Feature-print distance
    /// carries the look; the color term is weighted high enough that a
    /// black top ranks black tops above white ones of the same shape.
    static func distance(_ a: Signature, _ b: Signature) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.featurePrint.computeDistance(&d, to: b.featurePrint)
        let colorDistance = simd_length(a.color - b.color) / 1.732  // normalize to 0…1
        return d + colorDistance * 1.0
    }

    /// Combined-distance ceiling for calling two items "similar".
    /// Feature-print distances for same-class items typically land
    /// well under 1.0; unrelated items push past ~1.3 even before the
    /// color term. Tune against the real closet if the row feels too
    /// strict or too loose.
    static let similarityCutoff: Float = 1.2
    /// Relative band: only items within this margin of the BEST match
    /// survive — a near-twin in the closet raises the bar for the rest.
    static let similarityBand: Float = 0.35

    /// Mean RGB over pixels with meaningful alpha, sampled on a 32×32
    /// downscale. Premultiplied-alpha aware: dividing the channel sums
    /// by the alpha sum recovers the true average color.
    private static func averageOpaqueColor(_ cg: CGImage) -> SIMD3<Float>? {
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r: Float = 0, g: Float = 0, b: Float = 0, aSum: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Float(pixels[i + 3]) / 255
            guard a > 0.1 else { continue }
            r += Float(pixels[i]) / 255
            g += Float(pixels[i + 1]) / 255
            b += Float(pixels[i + 2]) / 255
            aSum += a
        }
        guard aSum > 1 else { return nil }
        return SIMD3(r / aSum, g / aSum, b / aSum)
    }
}

// (DragCardShape, ContainerViewRef, ContainerViewGrabber and
// SnapshotDragCard live in AppModifiers.swift — shared with every
// full-screen sheet that uses the snapshot-driven drag dismissal.)

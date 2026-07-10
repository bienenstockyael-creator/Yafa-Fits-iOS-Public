import SwiftUI

struct CalendarMonthView: View {
    @Environment(OutfitStore.self) private var store

    /// Cross-view transition namespace passed in from RootView.
    var transitionNamespace: Namespace.ID

    /// Tap on a generation placeholder card — RootView opens the
    /// expanded card for that job. Same callback shape as
    /// `OutfitGridView.onExpandGenerationJob`.
    var onExpandGenerationJob: (PipelineJob) -> Void = { _ in }

    /// Fired when the user starts scrolling the calendar. RootView
    /// uses this to morph an open generation card / picker / stack
    /// back to its pill — matching the grid view's behavior so the
    /// dismiss never reads as a hard cut.
    var onScrollBegan: () -> Void = {}

    private let calendar = Calendar.current
    private let monthTitleColor = AppPalette.textStrong
    private let activeDayColor = AppPalette.textPrimary
    private let inactiveDayColor = AppPalette.textFaint.opacity(0.48)

    // Header fade zone: items fade out when their top edge is within this range of the header bottom
    private let headerBottom: CGFloat = 68
    private let fadeZone: CGFloat = 80

    @State private var isScrubbing = false
    /// Cancellable handle for the in-flight scroll-to-pending task.
    /// Each new pending-scroll cancels the previous task — without
    /// this, rapid taps stack overlapping scroll tasks that step on
    /// each other's `pendingCalendarScrollOutfitId` clears, which
    /// confuses the transition's Phase-1 wait.
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var lastObservedScrollOffset: CGFloat = 0

    // MARK: Pinch zoom (mirrors the closet grid)

    /// Pinch out → fewer/bigger day cells; pinch in → more/smaller.
    /// Store-backed so RootView can normalize it back to the default
    /// before every archive↔calendar transition. Mechanics live in the
    /// shared `gridPinchZoom` modifier (GridPinchZoom.swift).
    private var columnCount: Int { store.calendarColumnCount }
    @State private var pinch = GridPinchZoomState()
    @State private var twoFingersDown = false
    private static let minColumns = 2
    private static let maxColumns = 4

    /// STATIC layout instances per density — building a fresh
    /// [GridItem] on every body evaluation made LazyVGrid re-lay the
    /// whole grid continuously during the transition's opacity
    /// animation, so the anchor cell's frame never went stable and
    /// the morph degraded to a fade (the p2=FAIL diagnostic).
    private static let columnLayouts: [Int: [GridItem]] = [
        2: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: 2),
        3: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 3),
        4: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4),
    ]

    private var columns: [GridItem] {
        Self.columnLayouts[columnCount] ?? Self.columnLayouts[2]!
    }

    private var rowSpacing: CGFloat {
        switch columnCount {
        case 2: 34
        case 3: 24
        default: 18
        }
    }

    /// Day-cell thumbnail height scales with the zoom so the cells
    /// keep their proportions (156pt at the default 2 columns).
    private var dayThumbHeight: CGFloat {
        312 / CGFloat(columnCount)
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    // Zero-height KVO probe on the underlying
                    // UIScrollView's contentOffset. Mirrors
                    // OutfitGridView's setup so calendar scroll also
                    // dismisses an open card / picker via the same
                    // morph animation (instead of a hard cut on
                    // tab-switch / scroll).
                    ScrollOffsetObserver { offsetY in
                        if abs(offsetY - lastObservedScrollOffset) > 4 {
                            onScrollBegan()
                        }
                        lastObservedScrollOffset = offsetY
                    }
                    .frame(width: 0, height: 0)

                    // No in-page section header here — on calendar,
                    // the grid/calendar toggle lives in the top bar
                    // (RootView) so the calendar layout stays clean
                    // and matches the grid view's vertical anchor for
                    // the toggle. In-flight generation placeholders
                    // render inline in today's calendar slot (see
                    // `calendarDay`) rather than as a separate strip,
                    // so a freshly-kicked-off job lands at the right
                    // date instead of floating above the months.
                    ForEach(cachedSections) { section in
                        monthSection(section)
                    }

                    Color.clear
                        .frame(height: LayoutMetrics.screenPadding)
                }
                .padding(.horizontal, LayoutMetrics.large)
                .padding(.top, LayoutMetrics.calendarTopInset)
                // Shared pinch-zoom engine (scale-under-fingers, column
                // stepping, rubber-band, spring settle, hit-area and
                // gesture-arbitration rules) — see GridPinchZoom.swift.
                .gridPinchZoom(
                    $pinch,
                    minColumns: Self.minColumns,
                    maxColumns: Self.maxColumns,
                    columnCount: columnCount,
                    setColumnCount: { store.calendarColumnCount = $0 }
                )
            }
            // Disable scrolling the moment a second finger lands, so a
            // pinch is never read as a scroll. One-finger scrolling is
            // unaffected. (Same setup as the closet grid.)
            .scrollDisabled(isScrubbing || store.selectedOutfitId != nil || twoFingersDown)
            // Chrome cover ABOVE the per-cell fade band. The fade's
            // stale-geometry guard skips cells whose top has scrolled
            // past ~the screen top — their lower halves otherwise hang
            // CRISP over the status bar / logo ("header blur
            // clipping"). Solid page background over the chrome strip,
            // dissolving to transparent right where the per-cell fade
            // band (headerBottom + fadeZone) takes over, so the two
            // treatments read as one continuous dissolve.
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: AppPalette.pageBackground, location: 0),
                        .init(color: AppPalette.pageBackground, location: 0.45),
                        .init(color: AppPalette.pageBackground.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 96)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .background(
                TouchCountReporter { count in
                    // Window-level recognizer: ignore touches while
                    // this surface isn't the visible one (the archive
                    // + calendar stay mounted) — but ALWAYS let a
                    // zero-count through so the flag can't latch
                    // scroll off.
                    guard store.currentView == .calendar || count == 0 else { return }
                    let down = count >= 2
                    if down != twoFingersDown { twoFingersDown = down }
                }
            )
            .onPreferenceChange(CalendarOutfitFramePreferenceKey.self) { frames in
                store.calendarOutfitFrames = frames
            }
            .onAppear {
                if cachedSections.isEmpty { cachedSections = monthSections }
                scrollToPendingTarget(using: reader, animated: false)
            }
            .onChange(of: store.sortedOutfits) { _, _ in
                cachedSections = monthSections
            }
            .onChange(of: generationPlaceholderJobs.isEmpty) { _, _ in
                cachedSections = monthSections
            }
            .onChange(of: store.pendingCalendarScrollOutfitId) { _, newId in
                guard newId != nil else { return }
                scrollToPendingTarget(using: reader, animated: false)
            }
            .onChange(of: store.currentView) { _, _ in
                // A view switch can unmount a cell mid-scrub, so its
                // drag-end callback never fires — `isScrubbing` then
                // latches true and scroll is permanently disabled.
                isScrubbing = false
                twoFingersDown = false
            }
        }
    }

    // MARK: - Generation placeholders

    /// In-flight generation jobs whose committed outfit hasn't
    /// landed in the archive yet. Filtering matches `OutfitGridView`
    /// so a job briefly between accept and queue-removal doesn't
    /// double-render.
    private var generationPlaceholderJobs: [PipelineJob] {
        let queue = store.generationQueue
        let archived = Set(store.outfits.map(\.id))
        let all = queue.activeJobs + queue.waitingJobs
        return all.filter { job in
            guard let resultId = job.resultOutfitId else { return true }
            return !archived.contains(resultId)
        }
    }

    /// First in-flight job to surface in today's calendar slot.
    /// The calendar grid is one cell per day, so we can't show
    /// every queued job inline — additional placeholders stay
    /// accessible via the floating pill stack.
    private var todayPlaceholderJob: PipelineJob? {
        generationPlaceholderJobs.first
    }

    // MARK: - Month & Day rendering

    private func monthSection(_ section: MonthSection) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(monthTitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .headerProximityFade(headerBottom: headerBottom, fadeZone: fadeZone)

            LazyVGrid(columns: columns, spacing: rowSpacing) {
                ForEach(Array(section.days.enumerated()), id: \.element.id) { _, day in
                    calendarDay(day)
                }
            }
        }
    }

    private func calendarDay(_ day: CalendarDay) -> some View {
        let displayed = displayedOutfit(for: day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(day.numberLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(day.outfits.isEmpty ? inactiveDayColor : activeDayColor)

                // +N pill: this day holds more outfits than the one
                // shown — tap steps through them (swiping the outfit
                // pages too). Metrics match `WeatherPill` 1:1 — 12pt
                // semibold, 22pt content height (its icon's height),
                // xSmall/7 padding — so the two pills read as the same
                // species. Hidden at the max-density zoom: the tiny
                // cells have no room for it, and the swipe still
                // pages (the pill returns on pinch-in). Vertically
                // centered against the day number; the overflow rides
                // into the row gaps, floating like the weather pill.
                if day.outfits.count > 1, columnCount < Self.maxColumns {
                    Button {
                        pageDay(day, forward: true)
                    } label: {
                        // Elongated pill proportions: short "+N" text
                        // with equal-ish padding all around read as a
                        // circle — wide horizontal padding + tighter
                        // vertical keeps it visibly a pill.
                        Text("+\(day.outfits.count - 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppPalette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            // Solid WHITE capsule (appCapsule is a
                            // translucent blur fill — read as grey
                            // here), same hairline border as the app
                            // capsules.
                            .background(Capsule().fill(Color.white))
                            .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                            // Explicit glow blob — a `.shadow` here is
                            // near-invisible (shadows derive from the
                            // view's alpha and wash out on the white
                            // page). A blurred capsule painted behind
                            // the pill always shows.
                            .background {
                                Capsule()
                                    .fill(Self.dayPagePillGlow)
                                    .blur(radius: 10)
                                    .offset(y: 3)
                                    .padding(.horizontal, -3)
                            }
                    }
                    .buttonStyle(SolidPressButtonStyle())
                }
            }
            .frame(height: 18, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                if let outfit = displayed {
                    dayOutfitImage(outfit, day: day)
                        .transition(dayPageTransition)
                } else if calendar.isDateInToday(day.date),
                          let placeholder = todayPlaceholderJob {
                    // In-flight generation kicked off today — sits in
                    // today's calendar cell so the placeholder lives
                    // at the right date instead of as a top-of-page
                    // strip.
                    GenerationPlaceholderCard(
                        job: placeholder,
                        phase: store.generationQueue.phase(for: placeholder),
                        onTap: { onExpandGenerationJob(placeholder) },
                        compact: true
                    )
                    .frame(height: dayThumbHeight)
                } else {
                    Color.clear
                        .frame(height: dayThumbHeight)
                }
            }
            // SwiftUI pager for 2D outfits (no pan recognizer to hand
            // us a release) — 3D outfits page via the scrub-release
            // discrimination inside `dayOutfitImage`, whose UIKit pan
            // cancels this gesture, so the two paths never both fire.
            // Only attached on multi-outfit days: a gesture per cell
            // adds arbitration weight against the pinch's magnify.
            .if(day.outfits.count > 1) {
                $0.simultaneousGesture(pagerGesture(for: day, displayed: displayed))
            }
        }
        // Apply the 3D badge on the outer VStack so it sits at the
        // cell's top-right (date-row level) instead of on the image
        // below. topInset centers the 11pt icon vertically against
        // the 18pt-tall day-number frame; trailingInset pulls it a
        // touch inward from the right edge.
        .outfit3DBadge(active: (displayed?.frameCount ?? 0) > 1, topInset: 4, trailingInset: 8)
        // Dissolve under the top chrome (logo + toggle have no
        // backdrop; content scrolls beneath them). The "outfits
        // randomly disappear" bug blamed on this fade was actually
        // cover-frame starvation from the appear-time sequence
        // preloads (now removed) — the fade itself is safe with the
        // stale-geometry guard. Disabled on the transition anchor so
        // the morphing cell is never dimmed mid-flight.
        .headerProximityFade(
            headerBottom: headerBottom,
            fadeZone: fadeZone,
            enabled: displayed == nil || store.transitionAnchorOutfitId != displayed?.id
        )
        // Scroll-target id MUST live on the OUTER cell — the direct
        // lazy-grid child. ScrollViewReader can only find ids of
        // not-yet-instantiated lazy content when they're registered at
        // this level; an id nested inside the cell made scrollTo
        // silently no-op for any unmounted month, so every long-jump
        // transition degraded to a fade (p2=FAIL "none"). Doubling as
        // the paging identity: displayed change remounts the cell and
        // fires the nudge+fade transition on the image block; the day
        // number and pill crossfade with themselves, invisibly.
        .id(displayed?.id ?? day.dateKey)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayOutfitImage(_ outfit: Outfit, day: CalendarDay) -> some View {
        RotatableOutfitImage(
            outfit: outfit,
            height: dayThumbHeight,
            // Two fingers down = pinch — the scrub must not
            // steal a finger from the magnify (this was the
            // "pinch doesn't always engage" intermittency).
            draggable: !twoFingersDown,
            // NEVER preload the full 242-frame sequence from
            // a grid cell. Every appear-time preload queues
            // ~242 serialized disk-reads/decodes on the
            // FrameLoader actor; the transition's scrollTo
            // mounts dozens of cells at once, and newly
            // visible cells' single cover-frame loads then
            // wait SECONDS behind that queue (blank
            // "disappearing" cells, 2s+ transition stalls,
            // unresponsive pinch). Scrubbing lazy-loads
            // frames on demand, so nothing is lost.
            preloadFullSequenceOnAppear: false,
            // Don't let a scrub that stole the first finger of a
            // forming pinch cancel SwiftUI touch delivery — the
            // grid's magnify takes over and the scrub is disabled a
            // beat later (draggable flips with twoFingersDown).
            scrubPanCancelsTouches: false,
            // Sync to the source anchor's frame ONLY during
            // a list↔calendar transition (so the morph is
            // visually continuous). Outside of transitions
            // the cell is free to scrub on its own without
            // affecting the archive's view.
            syncFrameIndex: anchorTransitionFrame(for: outfit.id),
            onTap: {
                // A finger-lift at the end of a pinch must
                // not read as a tap (same guard as the
                // closet grid).
                guard !pinch.isPinching else { return }
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                store.selectedOutfitId = outfit.id
            },
            onHorizontalDragChange: { isDragging in
                isScrubbing = isDragging
            },
            onFrameChange: { newFrame in
                // Broadcast for the transition-frame
                // capture in switchView. No view body reads
                // this dict so writes don't trigger
                // re-renders.
                store.currentDisplayedFrame[outfit.id] = newFrame
            },
            onHorizontalDragRelease: { release in
                // Scrub-vs-page discrimination, same thresholds as the
                // carousel: a decisive one-direction flick pages to the
                // day's next outfit; a back-and-forth scrub (low
                // monotonicity) stays on this outfit and just rotates.
                guard day.outfits.count > 1,
                      abs(release.totalTranslation) > Self.dayPageDistanceFloor,
                      release.monotonicityRatio >= Self.dayPageMonotonicityFloor
                else { return }
                pageDay(day, forward: release.totalTranslation < 0)
            }
        )
        .frame(maxWidth: .infinity)
        .anchorTransition(
            outfitId: outfit.id,
            namespace: transitionNamespace,
            isAnchor: store.transitionAnchorOutfitId == outfit.id,
            viewName: "calendar",
            isSource: store.currentView == .calendar
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CalendarOutfitFramePreferenceKey.self,
                    value: [outfit.id: proxy.frame(in: .global)]
                )
            }
        }
        // Drop stale frame entries when the cell scrolls
        // out of the lazy-render region, so transition
        // logic can't pick a frame from a previous scroll.
        .onDisappear {
            store.calendarOutfitFrames[outfit.id] = nil
        }
    }

    // MARK: - Multi-outfit day paging

    /// Matches `CarouselView.ScrubSwipe` so paging a day cell feels
    /// identical to paging the carousel.
    private static let dayPageDistanceFloor: CGFloat = 55
    private static let dayPageMonotonicityFloor: CGFloat = 0.80
    private static let dayPageAnimation = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)
    /// Glow under the +N pill — subtle light blue (the WeatherPill's
    /// rainy tint), painted as an explicit blurred blob (a `.shadow`
    /// washes out on the white page).
    private static let dayPagePillGlow = Color(red: 0.71, green: 0.86, blue: 1).opacity(0.55)

    /// Direction of the last page action — drives which edge the
    /// incoming/outgoing outfit nudges toward.
    @State private var dayPageForward = true

    /// Nudge+fade rather than a full edge slide: the day cell isn't
    /// clipped (clipping would carve the archive↔calendar morph as it
    /// passes through), so the outgoing outfit must not travel into
    /// neighboring cells.
    private var dayPageTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: dayPageForward ? 44 : -44).combined(with: .opacity),
            removal: .offset(x: dayPageForward ? -44 : 44).combined(with: .opacity)
        )
    }

    /// The outfit a day cell currently shows: the user's page choice
    /// (or the transition's anchor override) if it still exists on
    /// that day, else the day's newest.
    private func displayedOutfit(for day: CalendarDay) -> Outfit? {
        guard !day.outfits.isEmpty else { return nil }
        if let overrideId = store.calendarDayDisplayedOutfitIds[day.dateKey],
           let match = day.outfits.first(where: { $0.id == overrideId }) {
            return match
        }
        return day.outfits.first
    }

    private func pageDay(_ day: CalendarDay, forward: Bool) {
        guard day.outfits.count > 1,
              let current = displayedOutfit(for: day),
              let index = day.outfits.firstIndex(where: { $0.id == current.id })
        else { return }
        let count = day.outfits.count
        let next = (index + (forward ? 1 : -1) + count) % count
        dayPageForward = forward
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(Self.dayPageAnimation) {
            store.calendarDayDisplayedOutfitIds[day.dateKey] = day.outfits[next].id
        }
    }

    /// Backup pager for 2D outfits: they have no pan recognizer, so a
    /// horizontal flick reaches SwiftUI directly. Gated to 2D — on 3D
    /// cells the scrub's UIKit pan (cancelsTouchesInView) cancels this
    /// gesture, and the release-discrimination path pages instead.
    private func pagerGesture(for day: CalendarDay, displayed: Outfit?) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard day.outfits.count > 1,
                      (displayed?.frameCount ?? 1) <= 1,
                      !pinch.isPinching, !twoFingersDown
                else { return }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.2,
                      abs(dx) > 44
                else { return }
                pageDay(day, forward: dx < 0)
            }
    }

    /// Cached sections — rebuilding on every body evaluation froze the
    /// pinch: the live pinch scale changes per frame, and each rebuild
    /// allocated a DateFormatter and ran hundreds of Calendar ops.
    /// Rebuilt only when the outfits (or the placeholder) change.
    @State private var cachedSections: [MonthSection] = []

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var monthSections: [MonthSection] {
        let grouped = Dictionary(grouping: store.sortedOutfits) { $0.monthBucket ?? .distantPast }
        var sections = grouped.keys
            .sorted(by: >)
            .map { month in
                let outfits = grouped[month] ?? []
                return MonthSection(month: month, days: days(for: month, outfits: outfits))
            }

        // If there's an in-flight job today but no outfits exist for
        // the current month yet, the current month wouldn't appear at
        // all and the placeholder would have nowhere to render. Add
        // a synthetic empty month so today's slot can host the
        // placeholder card.
        if todayPlaceholderJob != nil,
           let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())),
           !sections.contains(where: { calendar.isDate($0.month, equalTo: currentMonth, toGranularity: .month) }) {
            sections.insert(
                MonthSection(month: currentMonth, days: days(for: currentMonth, outfits: [])),
                at: 0
            )
        }

        return sections
    }

    private func days(for month: Date, outfits: [Outfit]) -> [CalendarDay] {
        // ALL outfits per date (newest first — grouping preserves the
        // sortedOutfits order). The cell shows one at a time; the +N
        // pill / swipe pages through the rest.
        let outfitsByDate = Dictionary(grouping: outfits, by: \.date)
        let formatter = Self.dayKeyFormatter

        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }

        // Newest day first within each month, matching the grid's
        // newest-first order so toggling between views doesn't reorder
        // the user's mental list of outfits.
        let now = Date()
        return range.reversed().compactMap { day in
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = day
            guard let date = calendar.date(from: components) else { return nil }
            // FUTURE days don't render — a screenful of blank
            // end-of-month cells sat above today at the top of the
            // calendar, so every toggle from the archive landed on
            // emptiness instead of the anchor outfit.
            if date > now, !calendar.isDateInToday(date) { return nil }
            let key = formatter.string(from: date)
            return CalendarDay(date: date, dateKey: key, outfits: outfitsByDate[key] ?? [])
        }
    }

    /// Returns the in-flight transition's source frame for this cell
    /// if it's the current anchor, else nil. Keeps the morphing cell
    /// in sync with the source view's displayed frame.
    private func anchorTransitionFrame(for outfitId: String) -> Int? {
        guard store.transitionAnchorOutfitId == outfitId else { return nil }
        return store.transitionAnchorFrameIndex
    }

    private func scrollToPendingTarget(using reader: ScrollViewProxy, animated: Bool = true) {
        guard let targetOutfitId = store.pendingCalendarScrollOutfitId else { return }

        // Cancel any previous in-flight scroll task. Without this, a
        // rapid second pendingScroll request stacks on top of the
        // first; both tasks issue scrollTo's and both later try to
        // clear `pendingCalendarScrollOutfitId`, racing with the
        // transition's Phase-1 wait. Now there's exactly one active
        // scroll task at a time.
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { return }

            // Always non-animated — the destination view should appear
            // already at the right scroll position with no scroll
            // animation, only its own opacity transition.
            //
            // Three nudges instead of two: for long jumps (top→bottom),
            // LazyVStack doesn't know exact cell positions yet, so the
            // first scroll lands approximately. Each subsequent scroll
            // refines as more cells get mounted and the size estimate
            // tightens. Three nudges reliably centers even when going
            // archive-bottom → calendar-bottom.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            for waitMs in [40, 50] {
                // Authority check — abort if our targetOutfitId is no
                // longer the pending one (i.e., a newer task has taken
                // over, or the pending state has been cleared
                // entirely). Stronger than `Task.isCancelled` because
                // a cancelled-but-still-running task can issue stray
                // synchronous `scrollTo`s between await points before
                // cancellation is observed at the next iteration. This
                // check guarantees we only scroll while we're still
                // authoritative for the current target.
                guard store.pendingCalendarScrollOutfitId == targetOutfitId else { return }
                withTransaction(transaction) {
                    reader.scrollTo(targetOutfitId, anchor: .center)
                }
                try? await Task.sleep(for: .milliseconds(waitMs))
            }
            guard store.pendingCalendarScrollOutfitId == targetOutfitId else { return }
            withTransaction(transaction) {
                reader.scrollTo(targetOutfitId, anchor: .center)
            }

            try? await Task.sleep(for: .milliseconds(60))
            // Only null out the flag if it's still pointing at OUR
            // target — never clobber a newer task's pending value.
            guard store.pendingCalendarScrollOutfitId == targetOutfitId else { return }
            store.pendingCalendarScrollOutfitId = nil
        }
    }
}

struct CalendarOutfitFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MonthSection: Identifiable {
    let month: Date
    let days: [CalendarDay]

    var id: Date { month }

    var title: String {
        month.formatted(.dateTime.month(.wide)) + "."
    }
}

private struct CalendarDay: Identifiable {
    let date: Date
    /// "yyyy-MM-dd" — keys the per-day displayed-outfit override.
    let dateKey: String
    /// Every outfit on this date, newest first. The cell displays one
    /// (see `displayedOutfit(for:)`) and pages through the rest.
    let outfits: [Outfit]

    var id: Date { date }

    var numberLabel: String {
        date.formatted(.dateTime.day())
    }
}

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
    /// before every archive↔calendar transition.
    private var columnCount: Int { store.calendarColumnCount }
    @State private var pinchScale: CGFloat = 1
    @State private var pinchAnchor: UnitPoint = .center
    @State private var isPinching = false
    @State private var pinchStartColumns: Int?
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
                // Zoom from the pinch focal point, not the content center.
                .scaleEffect(pinchScale, anchor: pinchAnchor)
                // The WHOLE content surface must be hit-testable for
                // the magnify: the calendar is sparse (empty days,
                // gaps, blank rows aren't hit-testable by default),
                // so a pinch with one finger on empty space only ever
                // delivered ONE touch to the gesture — it never
                // formed. This is why the calendar pinch felt far
                // flakier than the archive's (a dense wall of images).
                .contentShape(Rectangle())
                // SIMULTANEOUS, not high-priority: SwiftUI gesture
                // priority only orders gestures within this subtree —
                // it cannot preempt the parent ScrollView's pan. As a
                // high-priority gesture the magnify had to WIN a race
                // against the scroll (via the twoFingersDown
                // roundtrip) and usually lost ("pinch works 1 in 6").
                // Simultaneous lets it co-recognize with the scroll;
                // scrollDisabled(twoFingersDown) then freezes the
                // scroll a beat later, so the pinch always engages.
                .simultaneousGesture(zoomGesture)
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

    // MARK: - Pinch zoom gesture

    /// Pinch out → fewer/bigger day cells; pinch in → more/smaller.
    /// Mirrors the closet grid exactly: the calendar scales live under
    /// the fingers, steps the column count mid-pinch with a selection
    /// tick, then springs to rest with a light bounce on release.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                pinchAnchor = value.startAnchor   // finger midpoint
                if pinchStartColumns == nil { pinchStartColumns = columnCount }
                let start = Double(pinchStartColumns ?? columnCount)
                // Continuous desired column count (zoom out → bigger
                // cells → fewer columns).
                let raw = start / Double(value.magnification)
                let lo = Double(Self.minColumns), hi = Double(Self.maxColumns)
                // Rubber-band past the limits so the extremes still
                // have an overshoot to spring back from on release.
                let effective: Double
                if raw < lo { effective = lo - (lo - raw) * 0.28 }
                else if raw > hi { effective = hi + (raw - hi) * 0.28 }
                else { effective = raw }
                let whole = min(Self.maxColumns, max(Self.minColumns, Int(raw.rounded())))
                if whole != columnCount {
                    store.calendarColumnCount = whole   // steps 2→3→4 mid-pinch
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                // Compensating scale (overshoots past the limits → bounce).
                pinchScale = CGFloat(Double(columnCount) / effective)
            }
            .onEnded { _ in
                pinchStartColumns = nil
                // Settle with an underdamped spring so the end of the
                // zoom has a light, organic bounce.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { pinchScale = 1 }
                // Keep `isPinching` true a beat longer so the finger-
                // lift doesn't register as a tap and scrolling doesn't
                // snap back mid-settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    isPinching = false
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
                guard !isPinching else { return }
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
                      !isPinching, !twoFingersDown
                else { return }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.2,
                      abs(dx) > 44
                else { return }
                pageDay(day, forward: dx < 0)
            }
    }

    /// Cached sections — rebuilding on every body evaluation froze the
    /// pinch: `pinchScale` changes per frame, and each rebuild
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

struct CalendarDetailOverlayHost: View {
    @Environment(OutfitStore.self) private var store

    @State private var detailOutfitId: String?
    @State private var detailMounted = false
    @State private var detailVisible = false

    var body: some View {
        Group {
            if store.currentView == .calendar, detailMounted, let outfit = selectedOutfit {
                CalendarDetailSheet(
                    outfit: outfit,
                    isVisible: detailVisible,
                    useFahrenheit: store.useFahrenheit,
                    isLiked: store.likedIds.contains(outfit.id),
                    showsDeleteAction: store.isLocalOutfit(outfit),
                    onDismiss: {
                        store.selectedOutfitId = nil
                    },
                    onToggleLike: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            store.toggleLike(outfit.id)
                        }
                    },
                    onDelete: {
                        store.selectedOutfitId = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            store.deleteOutfit(outfit)
                        }
                    }
                )
            }
        }
        .onAppear {
            syncDetailState(selectedId: store.currentView == .calendar ? store.selectedOutfitId : nil)
        }
        .onChange(of: store.selectedOutfitId) { _, selectedId in
            guard store.currentView == .calendar else { return }
            syncDetailState(selectedId: selectedId)
        }
        .onChange(of: store.currentView) { _, currentView in
            guard currentView == .calendar else {
                dismissImmediately()
                return
            }
            syncDetailState(selectedId: store.selectedOutfitId)
        }
    }

    private var selectedOutfit: Outfit? {
        guard let detailOutfitId else { return nil }
        return store.outfitById[detailOutfitId]
    }

    private func syncDetailState(selectedId: String?) {
        guard store.currentView == .calendar else {
            dismissImmediately()
            return
        }

        if let selectedId, store.outfitById[selectedId] != nil {
            detailOutfitId = selectedId
            detailMounted = true

            Task { @MainActor in
                await Task.yield()
                await Task.yield()
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                    detailVisible = true
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            detailVisible = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(580))
            guard store.currentView == .calendar, store.selectedOutfitId == nil else { return }
            detailMounted = false
            detailOutfitId = nil
        }
    }

    private func dismissImmediately() {
        detailVisible = false
        detailMounted = false
        detailOutfitId = nil
    }
}

struct CalendarDetailSheet: View {
    let outfit: Outfit
    let isVisible: Bool
    let useFahrenheit: Bool
    let isLiked: Bool
    let showsDeleteAction: Bool
    let onDismiss: () -> Void
    let onToggleLike: () -> Void
    let onDelete: () -> Void
    @Environment(OutfitStore.self) private var store
    @State private var showDeleteConfirmation = false
    @State private var selectedLinkedProduct: Product?
    @State private var selectedLinkedTag: LinkedTagSelection?
    @State private var isPublished: Bool?
    @State private var isTogglingPublish = false
    @State private var showShareComposer = false
    @State private var showAddProduct = false
    @State private var autoDetectSource: QuickAddSource?
    @State private var isLoadingAutoDetect = false
    @State private var isEditing = false
    @State private var editableTags: [String] = []
    @State private var showingTagInput = false
    @State private var newTagText = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var isExpanded = false
    @State private var editableDate: Date = Date()
    @State private var showDatePicker = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .onTapGesture(perform: onDismiss)

            GeometryReader { geometry in
                let width = min(max(geometry.size.width - (LayoutMetrics.screenPadding * 2), 0), 600)
                let stageHeight: CGFloat = min(geometry.size.height * 0.51, 480)

                VStack(spacing: 0) {
                    header
                    heroStage(stageHeight: stageHeight)
                        .scaleEffect(isExpanded ? 0.90 : 1.0, anchor: .top)
                        .frame(height: isExpanded ? stageHeight * 0.90 : stageHeight)
                        .scaleEffect(keyboardHeight > 0 ? 0.78 : 1.0, anchor: .top)
                        .padding(.bottom, keyboardHeight > 0 ? -66 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
                    footer
                }
                .padding(.horizontal, LayoutMetrics.medium)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.medium)
                .frame(width: width)  // height is automatic — card scales with content
                .background {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(Color(white: 0.92).opacity(0.55))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.85)
                )
                .shadow(color: AppPalette.cardShadow.opacity(0.72), radius: 26, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: -keyboardHeight * 0.5)
                .scaleEffect(isVisible ? 1 : 0.985)
                .offset(y: isVisible ? 0 : 22)
                .opacity(isVisible ? 1 : 0)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55), value: isVisible)
            }
        }
        .sheet(item: $selectedLinkedProduct) { product in
            LinkedProductOutfitsSheet(product: product, sourceOutfit: outfit)
                .roundedSheetBackground()
        }
        .sheet(item: $selectedLinkedTag) { selection in
            LinkedTagOutfitsSheet(tag: selection.tag, sourceOutfit: outfit)
                .roundedSheetBackground()
        }
        .task {
            let published = await OutfitService.isPublished(outfitId: outfit.id)
            await MainActor.run { isPublished = published }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            if let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    keyboardHeight = frame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                keyboardHeight = 0
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            if isEditing {
                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(calEditableDateLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(AppPalette.textSecondary)
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                }
                .buttonStyle(SolidPressButtonStyle())
            } else {
                Text(outfit.numericDateLabel(useFahrenheit: useFahrenheit))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)
            }

            Spacer()

            Button(action: onDismiss) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 32, height: 32)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
        }
        .padding(.bottom, 6)
    }

    private func heroStage(stageHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            if let weather = outfit.weather, !weather.condition.isEmpty {
                WeatherPill(weather: weather, useFahrenheit: useFahrenheit)
            }

            Spacer(minLength: 0)

            RotatableOutfitImage(
                outfit: outfit,
                height: stageHeight - 58,
                draggable: true,
                eagerLoad: true,
                autoRotate: true
            )
            .frame(maxWidth: .infinity)
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 10)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45), value: isVisible)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: stageHeight, alignment: .top)
        .padding(.top, 2)
    }

    private var calEditableDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = useFahrenheit ? "MM/dd/yy" : "dd/MM/yy"
        return formatter.string(from: editableDate)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                Spacer(minLength: 0)

                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        if isEditing { saveCalendarEdits(); isEditing = false }
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "SHOW LESS" : "SHOW INFO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textFaint)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppPalette.iconPrimary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .frame(height: 36)
                }
                .buttonStyle(SolidPressButtonStyle())
            }

            if isExpanded {
                if isEditing {
                    calEditableProductRow
                } else if let products = outfit.products, !products.isEmpty {
                    productRow(products)
                } else {
                    emptyProductRow
                }

                if isEditing {
                    calEditableTagRow
                } else if let tags = outfit.tags, !tags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            TagPill(tag: tag) {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                selectedLinkedTag = LinkedTagSelection(id: tag)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    calEmptyTagRow
                }
            }

            HStack(spacing: 8) {
                publishButton
                Spacer(minLength: 0)
                deleteButton
                likeButton
                calShareButton
                if isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isEditing { saveCalendarEdits() }
                            else { editableTags = outfit.tags ?? []; editableDate = outfit.parsedDate ?? Date() }
                            isEditing.toggle()
                        }
                    } label: {
                        Text(isEditing ? "SAVE" : "EDIT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(isEditing ? AppPalette.textSecondary : AppPalette.textFaint)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .appCapsule(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteOutfit(outfit)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit from your archive. Products and tags on other outfits are not affected.")
        }
        .fullScreenCover(isPresented: $showShareComposer) {
            ShareCardComposer(outfit: outfit).environment(store)
                .snapshotDragDismiss(onClose: { showShareComposer = false })
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showAddProduct) {
            if let userId = store.userId {
                AddProductSheet(userId: userId, outfitId: outfit.id) { product in
                    let p = Product(name: product.name, price: nil, image: product.imageURL,
                                    productId: product.id, tags: product.tags)
                    store.updateOutfit(outfit.id, caption: outfit.caption,
                                       products: (outfit.products ?? []) + [p])
                }
                .roundedSheetBackground()
            }
        }
        .sheet(item: $autoDetectSource) { source in
            if let userId = store.userId {
                AutoDetectProductsView(
                    sourceImage: source.image,
                    userId: userId
                ) { newProduct in
                    let existing = store.outfitById[outfit.id]?.products ?? outfit.products ?? []
                    guard !existing.contains(where: { $0.name == newProduct.name }) else { return }
                    store.updateOutfit(
                        outfit.id,
                        caption: outfit.caption,
                        products: existing + [newProduct]
                    )
                }
                .roundedSheetBackground()
            }
        }
        .sheet(isPresented: $showDatePicker) {
            VStack(spacing: 16) {
                Text("CHANGE DATE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textFaint)
                DatePicker("", selection: $editableDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.black)
                    .colorScheme(.light)
            }
            .padding(LayoutMetrics.medium)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .roundedSheetBackground(AppPalette.pageBackground)
        }
    }

    private var calEmptyTagRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { editableTags = outfit.tags ?? []; isEditing = true }
        } label: {
            HStack(spacing: 6) {
                AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.textFaint)
                Text("Add a tag")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .frame(height: 36)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var calEditableProductRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAddProduct = true
                } label: {
                    AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(SolidPressButtonStyle())

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await openAutoDetect() }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingAutoDetect {
                            ProgressView().controlSize(.small).tint(AppPalette.iconPrimary)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                                .foregroundStyle(AppPalette.iconPrimary)
                        }
                        Text("Quick Add")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
                    // AI-action accent: soft purple halo (matches carousel).
                    .shadow(color: AppPalette.aiAccent.opacity(0.18), radius: 8, y: 0)
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(isLoadingAutoDetect)

                ForEach(outfit.products ?? [], id: \.id) { product in
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            calendarProductImage(product)
                            Text(product.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AppPalette.textMuted)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                        Button {
                            store.removeProduct(product, fromOutfitId: outfit.id)
                            Task { try? await ProductLibraryService.removeProductFromOutfit(outfitId: outfit.id, product: product) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .background(Color(red: 0.85, green: 0.25, blue: 0.25).clipShape(Circle()))
                        }
                        .buttonStyle(SolidPressButtonStyle())
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, LayoutMetrics.medium).padding(.vertical, 8)
        }
        .padding(.horizontal, -LayoutMetrics.medium)
    }

    private var calEditableTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation { showingTagInput.toggle() }
                    } label: {
                        AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())

                    ForEach(editableTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(AppPalette.textSecondary)
                            Button {
                                editableTags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(AppPalette.textFaint)
                            }
                            .buttonStyle(SolidPressButtonStyle())
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .appCapsule(shadowRadius: 0, shadowY: 0)
                    }
                }
                .padding(.horizontal, LayoutMetrics.medium)
            }
            .padding(.horizontal, -LayoutMetrics.medium)

            if showingTagInput {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("", text: $newTagText, prompt:
                            Text("New tag…").foregroundColor(AppPalette.textSecondary)
                        )
                        .font(.system(size: 13))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitCalTag() }
                        if !newTagText.isEmpty {
                            Button("Add") { commitCalTag() }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppPalette.textSecondary)
                        }
                    }
                    .padding(LayoutMetrics.xSmall)
                    .background(AppPalette.pageBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 1))

                    let suggestions = store.allOutfitTags
                        .filter { $0.lowercased().hasPrefix(newTagText.lowercased()) && !editableTags.contains($0) }
                        .prefix(5)
                        .map { $0 }
                    if !suggestions.isEmpty && !newTagText.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.self) { s in
                                Button {
                                    newTagText = s; commitCalTag()
                                } label: {
                                    Text(s)
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppPalette.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, LayoutMetrics.xSmall)
                                        .padding(.vertical, 9)
                                }
                                .buttonStyle(SolidPressButtonStyle())
                                if s != suggestions.last { Divider().opacity(0.5) }
                            }
                        }
                        .background(AppPalette.pageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: AppPalette.cardShadow, radius: 6, y: 3)
                    }
                }
            }
        }
    }

    private func saveCalendarEdits() {
        showingTagInput = false
        showDatePicker = false
        let tags = editableTags
        let outfitId = outfit.id
        store.updateOutfitTags(outfitId: outfitId, tags: tags)
        Task { try? await ProductLibraryService.updateOutfitTags(outfitId: outfitId, tags: tags) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let newDateString = formatter.string(from: editableDate)
        if newDateString != outfit.date {
            store.updateOutfitDate(outfitId: outfitId, date: newDateString)
            Task { try? await OutfitService.updateOutfitDate(outfitId: outfitId, date: newDateString) }
        }
    }

    private func commitCalTag() {
        let t = newTagText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !editableTags.contains(t) else { return }
        editableTags.append(t); newTagText = ""
    }

    private func openAutoDetect() async {
        guard !isLoadingAutoDetect else { return }
        await MainActor.run { isLoadingAutoDetect = true }
        defer { Task { @MainActor in isLoadingAutoDetect = false } }

        guard let image = await AutoDetectProductsView.loadCoverFrame(for: outfit) else { return }
        await MainActor.run { autoDetectSource = QuickAddSource(image: image) }
    }

    private var likeButton: some View {
        Button(action: onToggleLike) {
            AppIcon(
                glyph: .heart,
                size: 14,
                color: AppPalette.iconPrimary,
                filled: isLiked
            )
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var calShareButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showShareComposer = true
        } label: {
            AppIcon(glyph: .share, size: 14, color: AppPalette.iconPrimary)
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var publishButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            togglePublish()
        } label: {
            if isTogglingPublish {
                ProgressView()
                    .tint(AppPalette.textMuted)
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            } else {
                Text(isPublished == true ? "UNPUBLISH" : "PUBLISH")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(isPublished == true ? AppPalette.textMuted : AppPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isTogglingPublish || isPublished == nil)
    }

    private func togglePublish() {
        let newValue = !(isPublished ?? false)
        isTogglingPublish = true
        isPublished = newValue
        Task {
            do {
                try await OutfitService.setPublished(newValue, outfitId: outfit.id)
            } catch {
                await MainActor.run { isPublished = !newValue }
            }
            await MainActor.run { isTogglingPublish = false }
        }
    }

    private var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            AppIcon(glyph: .trash, size: 14, color: AppPalette.iconPrimary)
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func productRow(_ products: [Product]) -> some View {
        let visibleProducts = Array(products.prefix(4))

        return Group {
            if visibleProducts.count <= 3 {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(visibleProducts) { product in
                        productCell(product)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(visibleProducts) { product in
                            productCell(product)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.medium)
                }
                .padding(.horizontal, -LayoutMetrics.medium)
            }
        }
    }

    private var emptyProductRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showAddProduct = true
        } label: {
            HStack { EmptyProductCard() }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func productCell(_ product: Product) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            selectedLinkedProduct = product
        } label: {
            VStack(spacing: 6) {
                calendarProductImage(product)

                Text(product.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 72)
            }
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func calendarProductImage(_ product: Product) -> some View {
        Group {
            if let imageURL = product.resolvedImageURL {
                CachedRemoteImage(
                    url: imageURL,
                    maxPixelSize: 640,
                    contentMode: .fill,
                    failure: AnyView(placeholderProductImage)
                ) {
                    ProgressView().tint(AppPalette.textMuted)
                }
            } else {
                placeholderProductImage
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var placeholderProductImage: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.22))
            .overlay {
                Text("Preview")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppPalette.textMuted.opacity(0.9))
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

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        var height: CGFloat = 0

        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if index > 0 { height += spacing }
        }

        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            let rowWidth = row.enumerated().reduce(CGFloat(0)) { partial, pair in
                partial + pair.element.sizeThatFits(.unspecified).width + (pair.offset > 0 ? spacing : 0)
            }

            var x = bounds.minX + (bounds.width - rowWidth) / 2

            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: .unspecified
                )
                x += size.width + spacing
            }

            y += rowHeight + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows.last?.isEmpty == true ? 0 : spacing

            if currentWidth + size.width + extra > maxWidth, rows.last?.isEmpty == false {
                rows.append([])
                currentWidth = 0
            }

            if rows[rows.count - 1].isEmpty == false {
                currentWidth += spacing
            }

            rows[rows.count - 1].append(subview)
            currentWidth += size.width
        }

        return rows
    }
}

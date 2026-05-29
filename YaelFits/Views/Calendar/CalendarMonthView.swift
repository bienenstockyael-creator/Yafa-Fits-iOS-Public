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

    private let columns = [
        GridItem(.flexible(), spacing: 28, alignment: .top),
        GridItem(.flexible(), spacing: 28, alignment: .top),
    ]

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
                    ForEach(monthSections) { section in
                        monthSection(section)
                    }

                    Color.clear
                        .frame(height: LayoutMetrics.screenPadding)
                }
                .padding(.horizontal, LayoutMetrics.large)
                .padding(.top, LayoutMetrics.calendarTopInset)
            }
            .scrollDisabled(isScrubbing || store.selectedOutfitId != nil)
            .onPreferenceChange(CalendarOutfitFramePreferenceKey.self) { frames in
                store.calendarOutfitFrames = frames
            }
            .onAppear {
                scrollToPendingTarget(using: reader, animated: false)
            }
            .onChange(of: store.pendingCalendarScrollOutfitId) { _, newId in
                guard newId != nil else { return }
                scrollToPendingTarget(using: reader, animated: false)
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

            LazyVGrid(columns: columns, spacing: 34) {
                ForEach(Array(section.days.enumerated()), id: \.element.id) { _, day in
                    calendarDay(day)
                }
            }
        }
    }

    private func calendarDay(_ day: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(day.numberLabel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(day.outfit == nil ? inactiveDayColor : activeDayColor)
                .frame(height: 18, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let outfit = day.outfit {
                    RotatableOutfitImage(
                        outfit: outfit,
                        height: 156,
                        draggable: true,
                        preloadFullSequenceOnAppear: true,
                        // Sync to the source anchor's frame ONLY during
                        // a list↔calendar transition (so the morph is
                        // visually continuous). Outside of transitions
                        // the cell is free to scrub on its own without
                        // affecting the archive's view.
                        syncFrameIndex: anchorTransitionFrame(for: outfit.id),
                        onTap: {
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
                    .frame(height: 156)
                } else {
                    Color.clear
                        .frame(height: 156)
                }
            }
        }
        // Apply the 3D badge on the outer VStack so it sits at the
        // cell's top-right (date-row level) instead of on the image
        // below. topInset centers the 11pt icon vertically against
        // the 18pt-tall day-number frame; trailingInset pulls it a
        // touch inward from the right edge.
        .outfit3DBadge(active: (day.outfit?.frameCount ?? 0) > 1, topInset: 4, trailingInset: 8)
        .headerProximityFade(headerBottom: headerBottom, fadeZone: fadeZone)
        .id(day.scrollID)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
        let outfitsByDate = Dictionary(outfits.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }

        // Newest day first within each month, matching the grid's
        // newest-first order so toggling between views doesn't reorder
        // the user's mental list of outfits.
        return range.reversed().compactMap { day in
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = day
            guard let date = calendar.date(from: components) else { return nil }
            let key = formatter.string(from: date)
            return CalendarDay(date: date, outfit: outfitsByDate[key])
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
        }
        .sheet(item: $selectedLinkedTag) { selection in
            LinkedTagOutfitsSheet(tag: selection.tag, sourceOutfit: outfit)
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
                .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
                .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
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
        }
        .sheet(isPresented: $showAddProduct) {
            if let userId = store.userId {
                AddProductSheet(userId: userId, outfitId: outfit.id) { product in
                    let p = Product(name: product.name, price: nil, image: product.imageURL,
                                    productId: product.id, tags: product.tags)
                    store.updateOutfit(outfit.id, caption: outfit.caption,
                                       products: (outfit.products ?? []) + [p])
                }
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
            .presentationBackground(AppPalette.pageBackground)
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
        .buttonStyle(.plain)
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
                .buttonStyle(.plain)

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
                .buttonStyle(.plain)
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
                        .buttonStyle(.plain)
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
                    .buttonStyle(.plain)

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
                            .buttonStyle(.plain)
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
                                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }

    private func calendarProductImage(_ product: Product) -> some View {
        Group {
            if let imageURL = product.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipped()
                    case .failure:
                        placeholderProductImage
                    case .empty:
                        ProgressView().tint(AppPalette.textMuted)
                    @unknown default:
                        placeholderProductImage
                    }
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
    let outfit: Outfit?

    var id: Date { date }
    var scrollID: String { outfit?.id ?? date.ISO8601Format() }

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

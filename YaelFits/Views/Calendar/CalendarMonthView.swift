import SwiftUI

struct CalendarMonthView: View {
    @Environment(OutfitStore.self) private var store
    private let calendar = Calendar.current
    private let monthTitleColor = AppPalette.textStrong
    private let activeDayColor = AppPalette.textPrimary
    private let inactiveDayColor = AppPalette.textFaint.opacity(0.48)

    // Header fade zone: items fade out when their top edge is within this range of the header bottom
    private let headerBottom: CGFloat = 68
    private let fadeZone: CGFloat = 80

    @State private var isScrubbing = false

    private let columns = [
        GridItem(.flexible(), spacing: 28, alignment: .top),
        GridItem(.flexible(), spacing: 28, alignment: .top),
    ]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(monthSections.enumerated()), id: \.element.id) { sectionIndex, section in
                        monthSection(section, sectionIndex: sectionIndex, globalStaggerBase: sectionIndex * 6)
                    }

                    Color.clear
                        .frame(height: LayoutMetrics.floatingControlsInset)
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

    // MARK: - Stagger delay for cinematic transition reveals

    private func transitionStagger(for index: Int) -> Double {
        Double(index) * 0.04
    }

    private var isTransitionRevealing: Bool {
        store.viewTransitionPhase == .targetIn && store.currentView == .calendar
    }

    // MARK: - Month & Day rendering

    private func monthSection(_ section: MonthSection, sectionIndex: Int, globalStaggerBase: Int) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(monthTitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .headerProximityFade(headerBottom: headerBottom, fadeZone: fadeZone)
                .calendarTransitionReveal(
                    phase: store.viewTransitionPhase,
                    isCalendar: store.currentView == .calendar,
                    staggerIndex: globalStaggerBase
                )

            LazyVGrid(columns: columns, spacing: 34) {
                ForEach(Array(section.days.enumerated()), id: \.element.id) { dayIndex, day in
                    calendarDay(day)
                        .calendarTransitionReveal(
                            phase: store.viewTransitionPhase,
                            isCalendar: store.currentView == .calendar,
                            staggerIndex: globalStaggerBase + 1 + dayIndex
                        )
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
                        onTap: {
                            let impact = UIImpactFeedbackGenerator(style: .medium)
                            impact.impactOccurred()
                            store.selectedOutfitId = outfit.id
                        },
                        onHorizontalDragChange: { isDragging in
                            isScrubbing = isDragging
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .opacity(store.heroAnchorOutfitId == outfit.id ? 0 : 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CalendarOutfitFramePreferenceKey.self,
                                value: [outfit.id: proxy.frame(in: .global)]
                            )
                        }
                    }
                } else {
                    Color.clear
                        .frame(height: 156)
                }
            }
        }
        .headerProximityFade(headerBottom: headerBottom, fadeZone: fadeZone)
        .id(day.scrollID)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monthSections: [MonthSection] {
        let grouped = Dictionary(grouping: store.sortedOutfits) { $0.monthBucket ?? .distantPast }

        return grouped.keys
            .sorted(by: >)
            .map { month in
                let outfits = grouped[month] ?? []
                return MonthSection(month: month, days: days(for: month, outfits: outfits))
            }
    }

    private func days(for month: Date, outfits: [Outfit]) -> [CalendarDay] {
        let outfitsByDate = Dictionary(outfits.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }

        return range.compactMap { day in
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = day
            guard let date = calendar.date(from: components) else { return nil }
            let key = formatter.string(from: date)
            return CalendarDay(date: date, outfit: outfitsByDate[key])
        }
    }

    private func scrollToPendingTarget(using reader: ScrollViewProxy, animated: Bool = true) {
        guard let targetOutfitId = store.pendingCalendarScrollOutfitId else { return }

        Task { @MainActor in
            // Yield to let VStack render all content
            await Task.yield()
            await Task.yield()

            if animated {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                    reader.scrollTo(targetOutfitId, anchor: .center)
                }
            } else {
                reader.scrollTo(targetOutfitId, anchor: .center)
            }

            try? await Task.sleep(for: .milliseconds(100))
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
    @State private var isPublished: Bool?
    @State private var isTogglingPublish = false
    @State private var showShareComposer = false
    @State private var showAddProduct = false
    @State private var isEditing = false
    @State private var editableTags: [String] = []
    @State private var showingTagInput = false
    @State private var newTagText = ""
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .onTapGesture(perform: onDismiss)

            GeometryReader { geometry in
                let width = min(max(geometry.size.width - (LayoutMetrics.screenPadding * 2), 0), 600)
                // Stage height is fixed — card grows dynamically to fit all content
                let stageHeight: CGFloat = min(geometry.size.height * 0.34, 320)

                VStack(spacing: 0) {
                    header
                    heroStage(stageHeight: stageHeight)
                        .scaleEffect(keyboardHeight > 0 ? 0.78 : 1.0, anchor: .top)
                        .padding(.bottom, keyboardHeight > 0 ? -66 : 0)
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
                                .fill(Color.white.opacity(0.42))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.85)
                )
                .shadow(color: AppPalette.cardShadow.opacity(0.72), radius: 26, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 76)
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
            Text(outfit.numericDateLabel(useFahrenheit: useFahrenheit))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textFaint)

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

    private var footer: some View {
        VStack(spacing: 14) {
            // Header row: date + edit toggle
            HStack {
                Text(outfit.numericDateLabel(useFahrenheit: useFahrenheit))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isEditing { saveCalendarEdits() }
                        else { editableTags = outfit.tags ?? [] }
                        isEditing.toggle()
                    }
                } label: {
                    Text(isEditing ? "DONE" : "EDIT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(isEditing ? AppPalette.textSecondary : AppPalette.textFaint)
                }
                .buttonStyle(.plain)
            }

            // Products
            if isEditing {
                calEditableProductRow
            } else if let products = outfit.products, !products.isEmpty {
                productRow(products)
            } else {
                emptyProductRow
            }

            // Tags
            if isEditing {
                calEditableTagRow
            } else if let tags = outfit.tags, !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in TagPill(tag: tag) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                calEmptyTagRow
            }

            // Action bar
            HStack(spacing: 8) {
                publishButton
                Spacer(minLength: 0)
                deleteButton
                likeButton
                calShareButton
            }
        }
        .padding(.top, 10)
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
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(AppPalette.textFaint)
                }
                .buttonStyle(.plain)

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
            .padding(.horizontal, 2).padding(.vertical, 8)
        }
    }

    private var calEditableTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation { showingTagInput.toggle() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(AppPalette.textFaint)
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
                .padding(.horizontal, 2)
            }

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
        let tags = editableTags
        let outfitId = outfit.id
        store.updateOutfitTags(outfitId: outfitId, tags: tags)
        Task { try? await ProductLibraryService.updateOutfitTags(outfitId: outfitId, tags: tags) }
    }

    private func commitCalTag() {
        let t = newTagText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !editableTags.contains(t) else { return }
        editableTags.append(t); newTagText = ""
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
                Text(isPublished == true ? "UNPUBLISH" : "PUBLISH TO FEED")
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
                    .padding(.horizontal, 8)
                }
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
            guard hasLinkedOutfits(for: product) else { return }
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
                    .frame(width: 88)
            }
        }
        .buttonStyle(.plain)
    }

    private func hasLinkedOutfits(for product: Product) -> Bool {
        store.sortedOutfits.contains { linkedOutfit in
            linkedOutfit.id != outfit.id &&
            (linkedOutfit.products ?? []).contains(where: { $0.id == product.id })
        }
    }

    private func calendarProductImage(_ product: Product) -> some View {
        Group {
            if let imageURL = product.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
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
        .frame(width: 80, height: 80)
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


// MARK: - Calendar Transition Reveal (staggered per element)

private struct CalendarTransitionRevealModifier: ViewModifier {
    let phase: ViewTransitionPhase
    let isCalendar: Bool
    let staggerIndex: Int

    private var isRevealing: Bool {
        phase == .targetIn && isCalendar
    }

    private var isHidden: Bool {
        phase == .sourceOut && isCalendar
    }

    private var targetOpacity: Double {
        if isHidden { return 0 }
        if phase == .targetIn && isCalendar { return 1 }
        if phase == .idle { return 1 }
        return 1
    }

    private var targetBlur: CGFloat {
        if isHidden { return 6 }
        return 0
    }

    private var staggerDelay: Double {
        isRevealing ? Double(staggerIndex) * 0.03 : 0
    }

    func body(content: Content) -> some View {
        content
            .opacity(targetOpacity)
            .blur(radius: targetBlur)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.65).delay(staggerDelay),
                value: phase
            )
    }
}

extension View {
    func calendarTransitionReveal(phase: ViewTransitionPhase, isCalendar: Bool, staggerIndex: Int) -> some View {
        modifier(CalendarTransitionRevealModifier(phase: phase, isCalendar: isCalendar, staggerIndex: staggerIndex))
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

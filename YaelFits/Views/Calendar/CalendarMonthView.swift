import SwiftUI

struct CalendarMonthView: View {
    @Environment(OutfitStore.self) private var store
    private let calendar = Calendar.current
    private let monthTitleColor = AppPalette.textStrong
    private let activeDayColor = AppPalette.textPrimary
    private let inactiveDayColor = AppPalette.textFaint.opacity(0.48)

    @State private var contentVisible = false
    @State private var isScrubbing = false

    private let columns = [
        GridItem(.flexible(), spacing: 28, alignment: .top),
        GridItem(.flexible(), spacing: 28, alignment: .top),
    ]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(monthSections.enumerated()), id: \.element.id) { sectionIndex, section in
                        monthSection(section, sectionIndex: sectionIndex)
                    }

                    Color.clear
                        .frame(height: LayoutMetrics.floatingControlsInset)
                }
                .padding(.horizontal, LayoutMetrics.large)
                .padding(.top, LayoutMetrics.calendarTopInset)
            }
            .scrollDisabled(isScrubbing || store.selectedOutfitId != nil)
            .onAppear {
                contentVisible = false
                store.selectedOutfitId = nil
                Task { @MainActor in
                    await Task.yield()
                    contentVisible = true
                }
                scrollToPendingTarget(using: reader, animated: false)
            }
            .onChange(of: store.currentView) { _, currentView in
                guard currentView == .calendar else { return }
                scrollToPendingTarget(using: reader)
            }
            .onChange(of: store.pendingCalendarScrollOutfitId) { _, _ in
                guard store.currentView == .calendar else { return }
                scrollToPendingTarget(using: reader)
            }
        }
    }

    private func monthSection(_ section: MonthSection, sectionIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(monthTitleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blurFadeReveal(active: contentVisible, delay: monthDelay(for: sectionIndex))
                .viewportBlurFade()

            LazyVGrid(columns: columns, spacing: 34) {
                ForEach(Array(section.days.enumerated()), id: \.element.id) { dayIndex, day in
                    calendarDay(day)
                        .blurFadeReveal(
                            active: contentVisible,
                            delay: monthDelay(for: sectionIndex) + Double(dayIndex) * 0.012
                        )
                        .viewportBlurFade()
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
                } else {
                    Color.clear
                        .frame(height: 156)
                }
            }
        }
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

    private func monthDelay(for sectionIndex: Int) -> Double {
        Double(sectionIndex) * 0.04
    }

    private func scrollToPendingTarget(using reader: ScrollViewProxy, animated: Bool = true) {
        guard let targetOutfitId = store.pendingCalendarScrollOutfitId else { return }

        Task { @MainActor in
            await Task.yield()
            await Task.yield()

            guard store.currentView == .calendar else { return }

            if animated {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                    reader.scrollTo(targetOutfitId, anchor: .center)
                }
            } else {
                reader.scrollTo(targetOutfitId, anchor: .center)
            }

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

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .onTapGesture(perform: onDismiss)

            GeometryReader { geometry in
                let width = min(max(geometry.size.width - (LayoutMetrics.screenPadding * 2), 0), 600)
                let cardHeight = min(max(geometry.size.height - 194, 0), 620)
                let stageHeight = min(max(cardHeight * 0.58, 300), 420)

                VStack(spacing: 0) {
                    header
                    heroStage(stageHeight: stageHeight)
                    footer
                }
                .padding(.horizontal, LayoutMetrics.medium)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.small)
                .frame(width: width, height: cardHeight, alignment: .top)
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
                .scaleEffect(isVisible ? 1 : 0.985)
                .offset(y: isVisible ? 0 : 22)
                .opacity(isVisible ? 1 : 0)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55), value: isVisible)
            }
        }
        .sheet(item: $selectedLinkedProduct) { product in
            LinkedProductOutfitsSheet(product: product, sourceOutfit: outfit)
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
        VStack(spacing: 18) {
            FlowLayout(spacing: 8) {
                if let tags = outfit.tags, !tags.isEmpty {
                    ForEach(tags, id: \.self) { tag in
                        TagPill(tag: tag)
                    }
                }

                if showsDeleteAction {
                    deleteButton
                }

                likeButton
            }
            .frame(maxWidth: .infinity)

            if let products = outfit.products, !products.isEmpty {
                productRow(products)
            } else {
                emptyProductRow
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit and its saved frames from your archive.")
        }
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
        HStack {
            EmptyProductCard()
        }
        .frame(maxWidth: .infinity, alignment: .center)
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

    private func calendarProductImage(_ product: Product) -> some View {
        Group {
            if let imageURL = product.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .opacity(0.94)
                    case .failure:
                        placeholderProductImage
                    case .empty:
                        ProgressView()
                            .tint(AppPalette.textPrimary)
                    @unknown default:
                        placeholderProductImage
                    }
                }
            } else {
                placeholderProductImage
            }
        }
        .frame(width: 64, height: 64)
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

    private func hasLinkedOutfits(for product: Product) -> Bool {
        store.sortedOutfits.contains { linkedOutfit in
            linkedOutfit.id != outfit.id &&
            (linkedOutfit.products ?? []).contains(where: { $0.id == product.id })
        }
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

import SwiftUI

struct CarouselView: View {
    let outfits: [Outfit]
    @Binding var currentIndex: Int
    let backdropOpacity: Double
    let showsChrome: Bool
    let showsCurrentLiveSlide: Bool
    let showsEntryOverlay: Bool
    let entryFrame: CarouselEntryFrame?
    let entryImage: UIImage?
    let onHeroTargetFrameChange: (CGRect) -> Void
    let onCurrentFrameChange: (Int) -> Void
    let onCurrentDisplayedFrameChange: (Int?) -> Void
    let onCurrentScrubBegan: () -> Void
    let onDeleteOutfit: (Outfit) -> Void
    let onDismiss: () -> Void

    @Environment(OutfitStore.self) private var store
    @State private var dragOffset: CGFloat = 0
    @State private var verticalNudge: CGFloat = 0
    @State private var isScrubbingCurrentOutfit = false

    private var slideWidth: CGFloat {
        max(220, min(UIScreen.main.bounds.width * 0.78, 320))
    }

    private let gap: CGFloat = LayoutMetrics.xSmall

    var body: some View {
        ZStack {
            AppPalette.pageBackground
                .ignoresSafeArea()
                .opacity(backdropOpacity)
                .contentShape(Rectangle())
                .allowsHitTesting(backdropOpacity > 0.08)
                .onTapGesture {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    onDismiss()
                }

            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(backdropOpacity)

            VStack(spacing: LayoutMetrics.small) {
                if let outfit = currentOutfit, let weather = outfit.weather, !weather.condition.isEmpty {
                    ZStack {
                        WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
                            .opacity(showsChrome ? 1 : 0)
                            .allowsHitTesting(showsChrome)
                    }
                    .frame(height: 36)
                }

                ZStack {
                    carouselSlides
                    navButtons
                        .opacity(showsChrome ? 1 : 0)
                        .allowsHitTesting(showsChrome)
                }
                .frame(height: 318)

                if let outfit = currentOutfit {
                    CarouselDetailCard(
                        outfit: outfit,
                        onDelete: {
                            onDeleteOutfit(outfit)
                        }
                    )
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                        .opacity(showsChrome ? 1 : 0)
                        .allowsHitTesting(showsChrome)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, LayoutMetrics.carouselTopInset)
            .padding(.bottom, LayoutMetrics.xLarge)
            .compositingGroup()
        }
    }

    private var currentOutfit: Outfit? {
        outfits.indices.contains(currentIndex) ? outfits[currentIndex] : nil
    }

    private var carouselSlides: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let step = slideWidth + gap

            HStack(spacing: gap) {
                ForEach(Array(outfits.enumerated()), id: \.element.id) { index, outfit in
                    carouselSlide(outfit: outfit, index: index)
                }
            }
            .offset(
                x: center - slideWidth / 2 - CGFloat(currentIndex) * step + dragOffset,
                y: verticalNudge
            )
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56), value: currentIndex)
            .if(showsChrome) { view in
                view.gesture(carouselSwipeGesture(step: step))
            }
        }
        .onChange(of: currentIndex) { _, _ in
            isScrubbingCurrentOutfit = false
            store.selectedOutfitId = currentOutfit?.id
        }
        .onPreferenceChange(CarouselHeroTargetFramePreferenceKey.self) { frame in
            onHeroTargetFrameChange(frame)
        }
    }

    @ViewBuilder
    private func carouselSlide(outfit: Outfit, index: Int) -> some View {
        let distance = abs(index - currentIndex)
        let scale = max(0.82, 1.0 - Double(distance) * 0.16)
        let baseOpacity = max(0.38, 1.0 - Double(distance) * 0.34)
        let isCurrent = index == currentIndex
        let slideOpacity: Double = if isCurrent {
            showsCurrentLiveSlide ? baseOpacity : 0
        } else {
            showsChrome ? baseOpacity : 0
        }
        let entryFrameIndex = entryFrame?.outfitId == outfit.id ? entryFrame?.frameIndex : nil
        let entryFrameImage = entryFrame?.outfitId == outfit.id ? entryImage : nil

        ZStack {
            RotatableOutfitImage(
                outfit: outfit,
                height: 318,
                draggable: showsChrome && isCurrent,
                eagerLoad: isCurrent,
                preloadFullSequenceOnAppear: isCurrent,
                initialFrameIndex: entryFrameIndex,
                initialImage: entryFrameImage,
                syncFrameIndex: entryFrameIndex,
                syncImage: entryFrameImage,
                onHorizontalDragChange: showsChrome && isCurrent ? { isDragging in
                    if isDragging {
                        onCurrentScrubBegan()
                    }
                    isScrubbingCurrentOutfit = isDragging
                } : nil,
                onFrameChange: { frameIndex in
                    guard isCurrent else { return }
                    onCurrentFrameChange(frameIndex)
                },
                onDisplayedFrameChange: { frameIndex in
                    guard isCurrent else { return }
                    onCurrentDisplayedFrameChange(frameIndex)
                }
            )
            .opacity(slideOpacity)

            if isCurrent, let entryFrameImage {
                Image(uiImage: entryFrameImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
                    .opacity(showsEntryOverlay ? 1 : 0)
            }
        }
        .frame(width: slideWidth, height: 318)
        .scaleEffect(scale, anchor: .bottom)
        .allowsHitTesting(showsChrome && isCurrent)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CarouselHeroTargetFramePreferenceKey.self,
                    value: isCurrent ? proxy.frame(in: .global) : .null
                )
            }
        }
    }

    private func carouselSwipeGesture(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isScrubbingCurrentOutfit else { return }
                dragOffset = value.translation.width
                verticalNudge = max(-18, min(18, value.translation.height * 0.16))
            }
            .onEnded { value in
                guard !isScrubbingCurrentOutfit else {
                    dragOffset = 0
                    verticalNudge = 0
                    return
                }
                let threshold = max(48, step * 0.18)
                var changed = false

                if value.translation.width < -threshold, currentIndex < outfits.count - 1 {
                    currentIndex += 1
                    changed = true
                } else if value.translation.width > threshold, currentIndex > 0 {
                    currentIndex -= 1
                    changed = true
                }

                if changed {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                }

                withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)) {
                    dragOffset = 0
                    verticalNudge = 0
                }
            }
    }

    private var navButtons: some View {
        HStack {
            navButton(icon: .chevronLeft, disabled: currentIndex <= 0) {
                currentIndex -= 1
            }
            Spacer()
            navButton(icon: .chevronRight, disabled: currentIndex >= outfits.count - 1) {
                currentIndex += 1
            }
        }
        .padding(.horizontal, LayoutMetrics.xxSmall)
    }

    private func navButton(icon: AppIconGlyph, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)) {
                action()
            }
        } label: {
            AppIcon(glyph: icon, size: 16, color: AppPalette.iconPrimary)
                .frame(width: LayoutMetrics.touchTarget, height: LayoutMetrics.touchTarget)
                .appCircle(shadowRadius: 10, shadowY: 5)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}

private struct CarouselHeroTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

struct CarouselDetailCard: View {
    let outfit: Outfit
    let onDelete: () -> Void
    @Environment(OutfitStore.self) private var store
    @State private var showDeleteConfirmation = false
    @State private var selectedLinkedProduct: Product?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.small) {
                Text(outfit.numericDateLabel(useFahrenheit: store.useFahrenheit))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)

                Spacer(minLength: 0)

                if let outfitNumber = outfit.outfitNumber {
                    Text("\(outfitNumber)/\(store.sortedOutfits.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.textFaint)
                }
            }

            if let products = outfit.products, !products.isEmpty {
                productRow(products)
            } else {
                emptyProductRow
            }

            FlowLayout(spacing: 8) {
                if let tags = outfit.tags, !tags.isEmpty {
                    ForEach(tags, id: \.self) { tag in
                        TagPill(tag: tag)
                    }
                }

                if store.isLocalOutfit(outfit) {
                    deleteButton
                }

                likeButton
            }
            .frame(maxWidth: .infinity)
        }
        .padding(LayoutMetrics.medium)
        .appCard(cornerRadius: 26)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit and its saved frames from your archive.")
        }
        .sheet(item: $selectedLinkedProduct) { product in
            LinkedProductOutfitsSheet(product: product, sourceOutfit: outfit)
        }
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
                archiveProductImage(product)

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

    private func archiveProductImage(_ product: Product) -> some View {
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

    private var likeButton: some View {
        let isLiked = store.likedIds.contains(outfit.id)

        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                store.toggleLike(outfit.id)
            }
        } label: {
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
}

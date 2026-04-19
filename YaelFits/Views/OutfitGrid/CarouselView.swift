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
    @State private var verticalDismissOffset: CGFloat = 0
    @State private var isScrubbingCurrentOutfit = false
    @State private var isDismissing = false
    @State private var keyboardHeight: CGFloat = 0

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
                // Scale outfit down slightly when keyboard is open
                .scaleEffect(keyboardHeight > 0 ? 0.78 : 1.0, anchor: .top)
                .padding(.bottom, keyboardHeight > 0 ? -66 : 0)

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
            .offset(y: verticalDismissOffset - keyboardHeight)
            .opacity(isDismissing ? max(0.0, 1.0 - (verticalDismissOffset / 300.0)) : 1.0)
            .scaleEffect(isDismissing ? max(0.9, 1.0 - (verticalDismissOffset / 1500.0)) : 1.0, anchor: .top)
            .compositingGroup()
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

    private var carouselTempToggle: some View {
        HStack(spacing: 2) {
            carouselTempOption(label: "°F", isSelected: store.useFahrenheit) {
                withAnimation(.easeInOut(duration: 0.18)) { store.useFahrenheit = true }
            }
            carouselTempOption(label: "°C", isSelected: !store.useFahrenheit) {
                withAnimation(.easeInOut(duration: 0.18)) { store.useFahrenheit = false }
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(Capsule().fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98)))
        .overlay(Capsule().stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8))
    }

    private func carouselTempOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
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
        .onChange(of: currentIndex) { _, newIndex in
            isScrubbingCurrentOutfit = false
            store.selectedOutfitId = currentOutfit?.id
            // Preload current + adjacent so frames are ready instantly
            for offset in [-1, 0, 1] {
                let idx = newIndex + offset
                guard outfits.indices.contains(idx) else { continue }
                let outfit = outfits[idx]
                Task {
                    if offset == 0 {
                        await FrameLoader.shared.preloadFullSequence(for: outfit)
                    } else {
                        _ = await FrameLoader.shared.frame(for: outfit, index: 0)
                    }
                }
            }
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
        let isNear = distance <= 1
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
                eagerLoad: isNear,
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
                let horizontal = value.translation.width
                let vertical = value.translation.height

                // Only enter dismiss mode on a clear downward drag
                if !isDismissing && vertical > 50 && abs(vertical) > abs(horizontal) * 2.0 {
                    isDismissing = true
                }

                if isDismissing {
                    verticalDismissOffset = max(0, vertical * 0.6)
                } else {
                    dragOffset = horizontal
                    verticalNudge = max(-18, min(18, vertical * 0.16))
                }
            }
            .onEnded { value in
                guard !isScrubbingCurrentOutfit else {
                    dragOffset = 0
                    verticalNudge = 0
                    return
                }

                if isDismissing {
                    let velocity = value.predictedEndTranslation.height
                    if verticalDismissOffset > 80 || velocity > 400 {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onDismiss()
                    }
                    withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)) {
                        verticalDismissOffset = 0
                        isDismissing = false
                    }
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
    @State private var selectedLinkedTag: LinkedTagSelection?
    @State private var isPublished: Bool?
    @State private var isLoadingPublishState = false
    @State private var isTogglingPublish = false
    @State private var showShareComposer = false
    @State private var showPublishSheet = false
    @State private var showAddProduct = false
    // Edit mode
    @State private var isEditing = false
    @State private var editableTags: [String] = []
    @State private var showingTagInput = false
    @State private var newTagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Date + outfit counter + edit toggle
            HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.small) {
                Text(outfit.numericDateLabel(useFahrenheit: store.useFahrenheit))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isEditing { saveEdits() }
                        else { enterEditMode() }
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
                editableProductRow
            } else if let products = outfit.products, !products.isEmpty {
                productRow(products)
            } else {
                emptyProductRow
            }

            // Tags
            if isEditing {
                editableTagRow
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
                emptyTagRow
            }

            // Action bar — hidden in edit mode for more space
            if !isEditing {
                HStack(spacing: 8) {
                    publishButton
                    Spacer(minLength: 0)
                    deleteButton
                    likeButton
                    shareButton
                }
            }
        }
        .padding(LayoutMetrics.medium)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteOutfit(outfit)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit from your archive. Products and tags on other outfits are not affected.")
        }
        .sheet(item: $selectedLinkedProduct) { product in
            LinkedProductOutfitsSheet(product: product, sourceOutfit: outfit)
        }
        .sheet(item: $selectedLinkedTag) { selection in
            LinkedTagOutfitsSheet(tag: selection.tag, sourceOutfit: outfit)
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(outfit: outfit) { caption, products in
                isPublished = true
                store.updateOutfit(outfit.id, caption: caption, products: products)
            }
        }
        .sheet(isPresented: $showAddProduct) {
            if let userId = store.userId {
                AddProductSheet(userId: userId, outfitId: outfit.id) { product in
                    let newProduct = Product(
                        name: product.name,
                        price: nil,
                        image: product.imageURL,
                        productId: product.id,
                        tags: product.tags
                    )
                    store.updateOutfit(outfit.id, caption: outfit.caption,
                                       products: (outfit.products ?? []) + [newProduct])
                }
            }
        }
        .fullScreenCover(isPresented: $showShareComposer) {
            ShareCardComposer(outfit: outfit)
                .environment(store)
        }
        .task(id: outfit.id) {
            await loadPublishState()
        }
    }

    private func loadPublishState() async {
        isLoadingPublishState = true
        let published = await OutfitService.isPublished(outfitId: outfit.id)
        await MainActor.run {
            isPublished = published
            isLoadingPublishState = false
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
            HStack {
                EmptyProductCard()
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    private var emptyTagRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                enterEditMode()
                isEditing = true
            }
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
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Editable product row

    private var editableProductRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAddProduct = true
                } label: {
                    HStack(spacing: 8) {
                        AppIcon(glyph: .plusCircle, size: 32, color: AppPalette.textFaint, filled: true)
                        if (outfit.products ?? []).isEmpty {
                            Text("ADD PRODUCT")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(AppPalette.textFaint)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(outfit.products ?? [], id: \.id) { product in
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            archiveProductImage(product)
                            Text(product.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AppPalette.textMuted)
                                .lineLimit(1)
                                .frame(width: 64)
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            removeProduct(product)
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
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, -LayoutMetrics.medium)
    }

    // MARK: - Editable tag row

    private var editableTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation { showingTagInput.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            AppIcon(glyph: .plusCircle, size: 32, color: AppPalette.textFaint, filled: true)
                            if editableTags.isEmpty {
                                Text("ADD TAG")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(1.5)
                                    .foregroundStyle(AppPalette.textFaint)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(editableTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(AppPalette.textSecondary)
                            Button {
                                removeTag(tag)
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
                        .foregroundStyle(AppPalette.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitNewTag() }
                        if !newTagText.isEmpty {
                            Button("Add") { commitNewTag() }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppPalette.textSecondary)
                        }
                    }
                    .padding(LayoutMetrics.xSmall)
                    .background(AppPalette.pageBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 1))

                    // Suggestions dropdown
                    if !tagSuggestions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(tagSuggestions, id: \.self) { suggestion in
                                Button {
                                    newTagText = suggestion
                                    commitNewTag()
                                } label: {
                                    Text(suggestion)
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppPalette.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, LayoutMetrics.xSmall)
                                        .padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                if suggestion != tagSuggestions.last {
                                    Divider().opacity(0.5)
                                }
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

    // MARK: - Tag suggestions

    private var tagSuggestions: [String] {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return store.allOutfitTags
            .filter { $0.lowercased().hasPrefix(trimmed) && !editableTags.contains($0) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Edit mode logic

    private func enterEditMode() {
        editableTags = outfit.tags ?? []
    }

    private func saveEdits() {
        showingTagInput = false
        guard let userId = store.userId else { return }
        let tagsToSave = editableTags
        let outfitId = outfit.id
        store.updateOutfitTags(outfitId: outfitId, tags: tagsToSave)
        Task {
            try? await ProductLibraryService.updateOutfitTags(outfitId: outfitId, tags: tagsToSave)
        }
        _ = userId
    }

    private func removeProduct(_ product: Product) {
        store.removeProduct(product, fromOutfitId: outfit.id)
        Task { try? await ProductLibraryService.removeProductFromOutfit(outfitId: outfit.id, product: product) }
    }

    private func removeTag(_ tag: String) {
        editableTags.removeAll { $0 == tag }
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !editableTags.contains(trimmed) else { return }
        editableTags.append(trimmed)
        newTagText = ""
    }

    private func productCell(_ product: Product) -> some View {
        Button {
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
                    .frame(width: 80)
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

    private var publishButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isPublished == true {
                // Unpublish directly
                unpublish()
            } else {
                // Open publish sheet for caption + products
                showPublishSheet = true
            }
        } label: {
            Group {
                if isLoadingPublishState || isTogglingPublish {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                        .padding(.horizontal, 12)
                } else {
                    Text(isPublished == true ? "UNPUBLISH" : "PUBLISH TO FEED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(isPublished == true ? AppPalette.textMuted : AppPalette.textPrimary)
                        .padding(.horizontal, LayoutMetrics.xSmall)
                }
            }
            .frame(height: 36)
            .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingPublishState || isTogglingPublish)
    }

    private func unpublish() {
        isTogglingPublish = true
        isPublished = false
        Task {
            do {
                try await OutfitService.setPublished(false, outfitId: outfit.id)
            } catch {
                await MainActor.run { isPublished = true }
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

    private var shareButton: some View {
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
}

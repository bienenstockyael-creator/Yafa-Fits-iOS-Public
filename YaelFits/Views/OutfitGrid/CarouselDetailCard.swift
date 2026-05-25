import SwiftUI
import UIKit

struct CarouselDetailCard: View {
    let outfit: Outfit
    /// Single source of truth for whether the card is on screen.
    /// Driven by the carousel's Info button, swipe-up, swipe-down,
    /// and the card's own bottom-right chevron. The card has no
    /// intermediate "minimal" state — when `isVisible == true`, the
    /// full content (top row + middle + bottom row) renders.
    @Binding var isVisible: Bool
    /// Shared edit session. The under-the-pill date/location row
    /// in `CarouselView` reads from the same coordinator, so both
    /// surfaces agree on what's being edited without bindings or
    /// callbacks. See `CarouselEditCoordinator` for the lifecycle.
    @Bindable var editCoordinator: CarouselEditCoordinator
    /// When true, hides every owner-only affordance: publish toggle,
    /// delete, edit/save flip, and the "+ add" buttons on empty
    /// product/tag rows. Viewers can still like, share, tap on
    /// existing tags/products, and read the caption/location/date.
    var viewOnly: Bool = false
    @Environment(OutfitStore.self) private var store
    @State private var selectedLinkedProduct: Product?
    @State private var selectedLinkedTag: LinkedTagSelection?
    @State private var isPublished: Bool?
    @State private var isLoadingPublishState = false
    @State private var isTogglingPublish = false
    @State private var showPublishSheet = false
    @State private var showAddProduct = false
    @State private var autoDetectSource: QuickAddSource?
    @State private var isLoadingAutoDetect = false
    @State private var showingTagInput = false
    @State private var newTagText = ""

    /// Tracks focus on the inline "New tag…" TextField so the card
    /// can lift itself above the keyboard *only* when that field is
    /// being typed into. The carousel-chrome location/date fields
    /// live outside the card, so they don't trigger this lift —
    /// matching the asymmetric UX: location/date are at the top of
    /// the screen (plenty of room above the keyboard), the tag
    /// input is inside the card at the bottom (needs to be lifted).
    @FocusState private var isTagFieldFocused: Bool

    /// Live keyboard height from `UIResponder` notifications. App-
    /// wide keyboard avoidance is disabled at the `RootView` level
    /// (so location/date editing doesn't shove the carousel up); we
    /// re-introduce avoidance manually here for the tag-input case.
    @State private var keyboardHeight: CGFloat = 0

    /// Convenience: card reads `isEditing` from the coordinator.
    private var isEditing: Bool { editCoordinator.isEditing }
    var body: some View {
        // Card content with scale-in transition. The floating INFO
        // toggle that used to live here was lifted into the carousel's
        // new bottom action row (Save / Share / Info t-shirt).
        ZStack(alignment: .bottom) {
            if isVisible {
                cardContent
                    .frame(maxWidth: .infinity)
                    .transition(.cardGrowFromBottom)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isVisible)
        // Lift the card above the keyboard when (and only when) the
        // tag TextField is focused. `cardBottomInset` (30pt) already
        // sits above the screen edge, so subtracting it from the
        // keyboard height lands the card's bottom edge ~flush with
        // the keyboard top. `max(0, …)` guards against a hardware-
        // keyboard scenario where the field is focused but
        // `keyboardHeight` is 0 — without the clamp the card would
        // shift *down* by 30pt.
        .offset(y: isTagFieldFocused ? -max(0, keyboardHeight - 30) : 0)
        .animation(.easeOut(duration: 0.25), value: isTagFieldFocused)
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    private var cardContent: some View {
        // Single VStack with uniform spacing so every row → row gap
        // looks the same, regardless of which rows render. The
        // product row sizes to its tallest cell (1- or 2-line
        // names), so the gap below it adapts automatically — no
        // hardcoded offset needed.
        VStack(alignment: .leading, spacing: 18) {
            // Top row: Edit/Save toggle on the right. In edit mode,
            // Cancel appears on the left so the user can bail out
            // of in-flight changes without committing.
            if !viewOnly {
                HStack(spacing: 0) {
                    if isEditing {
                        cancelButton
                    }
                    Spacer(minLength: 0)
                    editSaveButton
                }
            }

            if isEditing {
                editableProductRow
            } else if let products = outfit.products, !products.isEmpty {
                productRow(products)
            } else if !viewOnly {
                // View-only mode omits the "+ add product" CTA
                // since the viewer can't tag products on someone
                // else's outfit.
                emptyProductRow
            }

            if isEditing {
                editableTagRow
            } else if let tags = outfit.tags, !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            selectedLinkedTag = LinkedTagSelection(id: tag)
                        } label: {
                            Text(tag.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(AppPalette.textMuted)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .appCapsule(shadowRadius: 0, shadowY: 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !viewOnly {
                // Same rationale as emptyProductRow above — hide
                // the "+ add tag" CTA when viewing.
                emptyTagRow
            }

            // Bottom row only renders in edit mode (Publish + Make
            // 3D). The card is closed by tapping outside or swiping
            // down — no in-card close affordance is needed.
            if !viewOnly && isEditing {
                HStack(spacing: 8) {
                    publishButton
                    // `Make 3D` is only meaningful for 2D outfits — 3D
                    // outfits already have a rotation, so promoting
                    // them is a no-op. Mirrors `is3DOutfit` in
                    // PublicFeedListView: 2D = frameCount == 1.
                    if outfit.frameCount == 1 {
                        make3DButton
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        // Equal padding on all four edges so the corner-anchored
        // controls (Edit pencil top-right, Cancel top-left, +
        // buttons in the row leaders, tag chips at the bottom) sit
        // the same visual distance from every edge of the card.
        .padding(LayoutMetrics.small)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        // Tapping inside the card on non-interactive content (i.e.
        // anything that isn't a button or the TextField itself) closes
        // the tag input and dismisses the keyboard. Buttons consume
        // taps before this fires, so the + tag button, the Quick Add
        // button, etc. still behave normally.
        .onTapGesture {
            if showingTagInput {
                withAnimation { showingTagInput = false }
            }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    // Drag-down on the card → close it. The carousel
                    // owns swipe-up-to-open, so the card itself only
                    // handles the dismissive direction.
                    let translation = value.translation.height
                    let velocity = value.predictedEndTranslation.height
                    if translation > 50 || velocity > 200 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        closeCard()
                    }
                }
        )
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
        .sheet(item: $autoDetectSource) { source in
            if let userId = store.userId {
                AutoDetectProductsView(
                    sourceImage: source.image,
                    userId: userId,
                    onAddManually: {
                        // AutoDetect dismisses itself; defer the
                        // manual sheet by one runloop tick so SwiftUI
                        // doesn't try to present back-to-back sheets.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            showAddProduct = true
                        }
                    }
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
        // `ViewThatFits` picks the first subview whose natural
        // size fits in the available space. Few products → the
        // centered HStack wins and the row looks identical on
        // owner and viewer surfaces. Many products → it falls
        // back to a horizontal ScrollView so the card width stays
        // consistent and content scrolls instead of pushing the
        // card frame past the viewport.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(products) { product in
                    productCell(product)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(products) { product in
                        productCell(product)
                    }
                }
                .padding(.horizontal, LayoutMetrics.medium)
            }
            .padding(.horizontal, -LayoutMetrics.medium)
        }
    }

    private var emptyProductRow: some View {
        // Pre-Phase-4 visual: centered EmptyProductCard placeholder.
        // Tapping it enters edit mode (which then surfaces the +
        // button + Quick Add).
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                editCoordinator.startEditing(outfit)
            }
        } label: {
            HStack {
                EmptyProductCard(size: 88, cornerRadius: 16, iconSize: 22)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    private var emptyTagRow: some View {
        // Pre-Phase-4 visual: small "+ ADD A TAG" capsule, centered.
        // Tap enters edit mode.
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                editCoordinator.startEditing(outfit)
            }
        } label: {
            HStack(spacing: 4) {
                AppIcon(glyph: .plusCircle, size: 9, color: AppPalette.textFaint)
                Text("ADD A TAG")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.textFaint)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Editable product row

    private var editableProductRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Single product-entry path — Quick Add. The manual
                // entry option (AddProductSheet) lives as an "Add
                // manually" affordance inside the AutoDetect sheet.
                addProductButton

                if (outfit.products ?? []).isEmpty {
                    // Mirrors the "Add a tag" hint label on the tag
                    // row — only shown until the first product is
                    // added, then the row swaps to product chips.
                    Text("Add a product")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AppPalette.textFaint)
                }

                ForEach(outfit.products ?? [], id: \.id) { product in
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 6) {
                            archiveProductImage(product)
                            Text(product.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppPalette.textMuted)
                                .lineLimit(1)
                                .frame(width: 100)
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
                    addTagButton

                    if editCoordinator.editableTags.isEmpty && !showingTagInput {
                        Text("Add a tag")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(AppPalette.textFaint)
                    }

                    ForEach(editCoordinator.editableTags, id: \.self) { tag in
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
                        .focused($isTagFieldFocused)
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
            .filter { $0.lowercased().hasPrefix(trimmed) && !editCoordinator.editableTags.contains($0) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Edit mode logic

    // Date, location, and tag lifecycle all live in
    // `CarouselEditCoordinator` now. The card just calls
    // `editCoordinator.startEditing(outfit)` / `save(into:)` /
    // `cancel()` from its buttons. Tag-row mutations go through
    // `editCoordinator.editableTags` directly.

    private func removeProduct(_ product: Product) {
        store.removeProduct(product, fromOutfitId: outfit.id)
        Task { try? await ProductLibraryService.removeProductFromOutfit(outfitId: outfit.id, product: product) }
    }

    private func openAutoDetect() async {
        guard !isLoadingAutoDetect else { return }
        await MainActor.run { isLoadingAutoDetect = true }
        defer { Task { @MainActor in isLoadingAutoDetect = false } }

        guard let image = await AutoDetectProductsView.loadCoverFrame(for: outfit) else { return }
        await MainActor.run { autoDetectSource = QuickAddSource(image: image) }
    }

    private func removeTag(_ tag: String) {
        editCoordinator.editableTags.removeAll { $0 == tag }
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !editCoordinator.editableTags.contains(trimmed) else { return }
        editCoordinator.editableTags.append(trimmed)
        newTagText = ""
    }

    private func productCell(_ product: Product) -> some View {
        VStack(spacing: 16) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                selectedLinkedProduct = product
            } label: {
                VStack(spacing: 8) {
                    archiveProductImage(product)

                    Text(product.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppPalette.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 100)
                }
            }
            .buttonStyle(.plain)

            // BUY pill on viewer surfaces — same capsule chrome as
            // the rest of the app's primary buttons (Publish, Save,
            // etc.) so it reads as a peer rather than a footnote.
            // Owner doesn't see this (they're not shopping their
            // own outfit).
            if viewOnly {
                Button {
                    ProductShopLink.open(product)
                } label: {
                    Text("BUY")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppPalette.textPrimary)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .appCapsule(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func archiveProductImage(_ product: Product) -> some View {
        Group {
            if let imageURL = product.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                            .frame(width: 100, height: 100)
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
        .frame(width: 100, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholderProductImage: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.22))
            .overlay {
                Text("Preview")
                    .font(.system(size: 9, weight: .semibold))
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
                size: 16,
                color: AppPalette.iconPrimary,
                filled: isLiked
            )
                .frame(width: 48, height: 48)
                .appCircle()
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
                        .controlSize(.small)
                        .tint(AppPalette.textMuted)
                } else {
                    Text(isPublished == true ? "Unpublish" : "Publish")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isPublished == true ? AppPalette.textMuted : AppPalette.textPrimary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
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

    /// Sibling of `publishButton` — same capsule style, placeholder
    /// action. Phase 3 wires this to route into `UploadPipelineView`
    /// seeded with the current 2D frame.
    private var make3DButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // TODO Phase 3: present UploadPipelineView seeded with the
            // currently-displayed frame so the user can promote a 2D
            // outfit to 3D.
        } label: {
            Text("Make 3D")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    /// Top-right Edit/Save toggle. Sits inline with the date/location
    /// row instead of the bottom row, so the bottom band is just
    /// Top-right Edit/Save toggle. Renders "Edit" in the resting
    /// state and "Save" in edit mode. Tap routes through the
    /// coordinator's `startEditing` / `save` methods, so both the
    /// card-side tag changes and the carousel-side date/location
    /// changes are committed (or seeded) atomically.
    @ViewBuilder
    private var editSaveButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isEditing {
                    editCoordinator.save(into: store)
                } else {
                    editCoordinator.startEditing(outfit)
                }
            }
        } label: {
            if isEditing {
                // Save: solid black pill, white label — primary
                // action styling that mirrors the "Add manually"
                // button inside the Quick Add flow.
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Capsule(style: .continuous).fill(Color.black))
            } else {
                // Edit: passive circular icon button — same chrome
                // as the other card affordances, just a pencil
                // glyph instead of a text label.
                AppIcon(glyph: .pencil, size: 16, color: AppPalette.textPrimary)
                    .frame(width: 48, height: 48)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
        }
        .buttonStyle(.plain)
    }

    /// Top-left Cancel button visible only in edit mode. Discards
    /// in-flight changes — the coordinator just drops the working
    /// values, nothing is written to the store.
    private var cancelButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                editCoordinator.cancel()
            }
        } label: {
            Text("Cancel")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    /// + button that triggers the Quick Add (auto-detect) flow.
    /// Same visual size as the rest of the card's action buttons so
    /// it reads as a peer. Paired with `addTagButton` so the two
    /// "+ add" affordances are visually identical. Shadowless — see
    /// the same note on `editSaveButton`.
    private var addProductButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await openAutoDetect() }
        } label: {
            Group {
                if isLoadingAutoDetect {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppPalette.iconPrimary)
                } else {
                    AppIcon(glyph: .plusCircle, size: 16, color: AppPalette.iconPrimary)
                }
            }
            .frame(width: 48, height: 48)
            .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingAutoDetect)
    }

    /// + button that drops the card into edit mode and opens the
    /// tag-input field. Matches `addProductButton` so the two
    /// affordances look like a pair. Shadowless.
    private var addTagButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                if !isEditing {
                    editCoordinator.startEditing(outfit)
                }
                showingTagInput = true
            }
        } label: {
            AppIcon(glyph: .plusCircle, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    /// Save any in-flight edits, then dismiss the card. Used by the
    /// in-card drag-down gesture; the carousel's tap-outside and
    /// outer drag-down go through `toggleCard()` on the carousel,
    /// which manages `cardExpandProgress` too.
    private func closeCard() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            if isEditing { editCoordinator.save(into: store) }
            isVisible = false
        }
    }

}


/// Card "grows" from a height of 0 with its bottom edge pinned to
/// its final position, matching the spec for the outfit detail
/// card's open/close animation. Implemented as a vertical-only
/// `scaleEffect` anchored at `.bottom`, combined with a quick
/// opacity ramp so the brief content squish during the spring is
/// imperceptible.
private struct CardGrowFromBottomModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: progress, anchor: .bottom)
            .opacity(Double(progress))
    }
}

extension AnyTransition {
    static var cardGrowFromBottom: AnyTransition {
        .modifier(
            active: CardGrowFromBottomModifier(progress: 0),
            identity: CardGrowFromBottomModifier(progress: 1)
        )
    }
}

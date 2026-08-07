import SwiftUI
import UIKit

// MARK: - Publish sheet

struct PublishSheet: View {
    let outfit: Outfit
    /// The quiet fallback path into the note editor for fits without a
    /// note — the carousel's floating pill was removed (gesture-first),
    /// so this row is where anyone who missed the long-press finds it.
    var onAddNote: (() -> Void)?
    var onPublished: (String?, [Product]) -> Void

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var caption: String
    @State private var taggedProducts: [ProductWithShopLink]
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var showAddProduct = false
    @State private var autoDetectSource: QuickAddSource?
    @State private var isLoadingAutoDetect = false
    /// Pending debounced save tasks, keyed by ProductWithShopLink.id. We
    /// cancel any in-flight task for a row when its shop URL changes,
    /// then schedule a fresh save 600 ms later — so the URL persists
    /// even if the user closes the sheet without tapping Publish.
    @State private var shopLinkSaveTasks: [UUID: Task<Void, Never>] = [:]

    // Shop links available to all users — products only appear on feed if linked

    /// Opt-in to showing the fit's diary note publicly. Only meaningful
    /// when the outfit has a note; the toggle row hides otherwise.
    @State private var shareNote = false

    // Tap-to-focus: the styled containers are bigger than the text
    // controls inside them — a tap anywhere on a field must focus it,
    // not just a tap on the text itself.
    @FocusState private var captionFocused: Bool
    @FocusState private var focusedLinkEntry: UUID?

    init(
        outfit: Outfit,
        onAddNote: (() -> Void)? = nil,
        onPublished: @escaping (String?, [Product]) -> Void
    ) {
        self.outfit = outfit
        self.onAddNote = onAddNote
        self.onPublished = onPublished
        _caption = State(initialValue: outfit.caption ?? "")
        _shareNote = State(initialValue: outfit.noteShared ?? false)
        _taggedProducts = State(initialValue: (outfit.products ?? []).map {
            ProductWithShopLink(product: $0, shopURL: $0.shopLink ?? "")
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.medium) {
                    captionSection
                    productsSection
                    diaryShareSection
                    feedNote
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, 100)
            }
            .background(AppPalette.groupedBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Publish to Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .overlay(alignment: .bottom) { publishButton }
            .sheet(isPresented: $showAddProduct) {
                if let userId = store.userId {
                    AddProductSheet(userId: userId, outfitId: outfit.id) { product, shopLink in
                        let p = Product(name: product.name, price: nil, image: product.imageURL,
                                        shopLink: shopLink, productId: product.id, tags: product.tags)
                        // Pre-fill the shop-link field — link-imported
                        // products arrive with their shop attached.
                        taggedProducts.append(ProductWithShopLink(product: p, shopURL: shopLink ?? ""))
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
                        guard !taggedProducts.contains(where: { $0.product.name == newProduct.name }) else { return }
                        taggedProducts.append(ProductWithShopLink(product: newProduct, shopURL: ""))
                    }
                    .roundedSheetBackground()
                }
            }
            .alert("Couldn't publish", isPresented: .constant(publishError != nil)) {
                Button("OK") { publishError = nil }
            } message: { Text(publishError ?? "") }
            .task {
                // Pre-fill empty shop-link fields from the DB truth.
                // Link-imported products save their link straight to
                // outfit_products at add time, but the in-memory
                // Product copy this sheet was seeded from can predate
                // that write — the field looked empty even though the
                // link was durably saved.
                struct Row: Decodable {
                    let productId: UUID?
                    let name: String?
                    let shopLink: String?
                    enum CodingKeys: String, CodingKey {
                        case productId = "product_id"
                        case name
                        case shopLink = "shop_link"
                    }
                }
                guard let rows: [Row] = try? await supabase
                    .from("outfit_products")
                    .select("product_id, name, shop_link")
                    .eq("outfit_id", value: outfit.id)
                    .execute()
                    .value
                else { return }
                for row in rows {
                    guard let link = row.shopLink, !link.isEmpty else { continue }
                    if let idx = taggedProducts.firstIndex(where: {
                        $0.shopURL.isEmpty && (
                            ($0.product.productId != nil && $0.product.productId == row.productId) ||
                            ($0.product.productId == nil && $0.product.name == row.name)
                        )
                    }) {
                        taggedProducts[idx].shopURL = link
                    }
                }

                // Second pass — the CANONICAL fallback. Link-imported
                // products durably store their shop page on the
                // products row itself (source_url, written at save).
                // Whatever happens to the per-fit copy (row rewritten
                // by an old publish, outfit id changed by a 3D accept,
                // a missed update), the canonical link fills the gap.
                let missingIds = taggedProducts.compactMap {
                    $0.shopURL.isEmpty ? $0.product.productId : nil
                }
                guard !missingIds.isEmpty else { return }
                struct CanonicalLink: Decodable {
                    let id: UUID
                    let sourceUrl: String?
                    enum CodingKeys: String, CodingKey {
                        case id
                        case sourceUrl = "source_url"
                    }
                }
                guard let canonical: [CanonicalLink] = try? await supabase
                    .from("products")
                    .select("id, source_url")
                    .in("id", values: missingIds.map(\.uuidString))
                    .execute()
                    .value
                else { return }
                for row in canonical {
                    guard let link = row.sourceUrl, !link.isEmpty else { continue }
                    if let idx = taggedProducts.firstIndex(where: {
                        $0.shopURL.isEmpty && $0.product.productId == row.id
                    }) {
                        taggedProducts[idx].shopURL = link
                    }
                }
            }
        }
    }

    // MARK: - Caption

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            label("CAPTION")
            ZStack(alignment: .topLeading) {
                if caption.isEmpty {
                    Text("Write a caption…")
                        .font(.system(size: 14))
                        .foregroundStyle(AppPalette.textFaint)
                        .padding(.top, 8).padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $caption)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(minHeight: 80, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .focused($captionFocused)
            }
            .padding(LayoutMetrics.xSmall)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .contentShape(Rectangle())
            .onTapGesture { captionFocused = true }
        }
    }

    // MARK: - Diary note share toggle

    @ViewBuilder
    private var diaryShareSection: some View {
        if let note = outfit.diaryNote, !note.isEmpty {
            VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
                label("DIARY NOTE")
                // Custom flat switch matching the generation card's
                // "Publish to Feed" toggle — not the system Toggle, which
                // picks up iOS's glassy/3D material look.
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    shareNote.toggle()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share your diary note")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppPalette.textSecondary)
                            Text("Show your note on this fit for others + on the share card.")
                                .font(.system(size: 12))
                                .foregroundStyle(AppPalette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        flatNoteToggleSwitch
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
                .onChange(of: shareNote) { _, newValue in
                    store.updateOutfitDiaryNote(
                        outfitId: outfit.id,
                        note: outfit.diaryNote,
                        style: DiaryNoteStyle.from(outfit.noteStyle),
                        shared: newValue
                    )
                }
                .padding(LayoutMetrics.small)
                .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            }
        } else if let onAddNote {
            // No note yet — the discoverable path into the editor now that
            // the carousel has no permanent note button.
            VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
                label("DIARY NOTE")
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onAddNote()
                } label: {
                    HStack(spacing: LayoutMetrics.xxSmall) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textSecondary)
                        Text("Add a note")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppPalette.textSecondary)
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
                .padding(LayoutMetrics.small)
                .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            }
        }
    }

    /// Same dimensions as the system switch, but a plain solid capsule
    /// track + white circle thumb — mirrors the generation card's
    /// `flatToggleSwitch` so the two publish surfaces look identical.
    private var flatNoteToggleSwitch: some View {
        ZStack(alignment: shareNote ? .trailing : .leading) {
            Capsule()
                .fill(shareNote ? AppPalette.uploadGlow : Color(white: 0.82))
                .frame(width: 44, height: 26)
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .padding(2)
                .shadow(color: Color.black.opacity(0.15), radius: 1.5, y: 0.5)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: shareNote)
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            label("PRODUCTS")

            VStack(spacing: 0) {
                ForEach($taggedProducts) { $entry in
                    productRow(entry: $entry)
                    if entry.id != taggedProducts.last?.id {
                        Divider().opacity(0.5).padding(.leading, 64)
                    }
                }

                if !taggedProducts.isEmpty { Divider().opacity(0.5) }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await openAutoDetect() }
                } label: {
                    HStack(spacing: LayoutMetrics.xSmall) {
                        if isLoadingAutoDetect {
                            ProgressView().tint(AppPalette.textFaint)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16))
                                .foregroundStyle(AppPalette.textFaint)
                        }
                        Text(isLoadingAutoDetect ? "LOADING…" : "QUICK ADD PRODUCTS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LayoutMetrics.medium)
                    // Whole row is the tap target, not just the label.
                    .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(isLoadingAutoDetect)

                Divider().opacity(0.5)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAddProduct = true
                } label: {
                    HStack(spacing: LayoutMetrics.xSmall) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(AppPalette.textFaint)
                        Text("ADD PRODUCTS MANUALLY")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LayoutMetrics.medium)
                    // Whole row is the tap target, not just the label.
                    .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
            }
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        }
    }

    private func openAutoDetect() async {
        guard !isLoadingAutoDetect else { return }
        await MainActor.run { isLoadingAutoDetect = true }
        defer { Task { @MainActor in isLoadingAutoDetect = false } }

        guard let image = await AutoDetectProductsView.loadCoverFrame(for: outfit) else {
            await MainActor.run { publishError = "Couldn't load the outfit frame." }
            return
        }
        await MainActor.run { autoDetectSource = QuickAddSource(image: image) }
    }

    private func productRow(entry: Binding<ProductWithShopLink>) -> some View {
        let product = entry.wrappedValue.product
        let hasShopURL = !entry.wrappedValue.shopURL.trimmingCharacters(in: .whitespaces).isEmpty

        return VStack(spacing: 0) {
            HStack(spacing: LayoutMetrics.xSmall) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.96))
                    if let productImageURL = URL(string: product.image) {
                        CachedRemoteImage(url: productImageURL, maxPixelSize: 640, contentMode: .fit) {
                            Color.clear
                        }
                        .padding(4)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(1)
                    if !hasShopURL {
                        Text("Add a shop link")
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.textFaint)
                    } else {
                        Text(entry.wrappedValue.shopURL)
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation { taggedProducts.removeAll { $0.id == entry.wrappedValue.id } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppPalette.textFaint)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.groupedBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(SolidPressButtonStyle())
            }
            .padding(LayoutMetrics.medium)

            // Shop link — available to everyone
            // Products without a link won't appear on the public feed card
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(hasShopURL ? AppPalette.textSecondary : AppPalette.textFaint)
                TextField("", text: entry.shopURL, prompt:
                    Text("Add shop link")
                        .foregroundColor(AppPalette.textFaint)
                )
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($focusedLinkEntry, equals: entry.wrappedValue.id)
                .onChange(of: entry.wrappedValue.shopURL) { _, newValue in
                    scheduleShopLinkSave(
                        entryId: entry.wrappedValue.id,
                        product: product,
                        url: newValue
                    )
                }
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.bottom, LayoutMetrics.xSmall)
            .contentShape(Rectangle())
            .onTapGesture { focusedLinkEntry = entry.wrappedValue.id }
        }
    }

    // MARK: - Pro note

    private var feedNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
            Text("Products without a shop link will open in Google Lens so viewers can still find them.")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textFaint)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Publish

    private var publishButton: some View {
        Button {
            Task { await publish() }
        } label: {
            Group {
                if isPublishing {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("PUBLISH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.xLarge)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isPublishing)
        .background(AppPalette.groupedBackground.ignoresSafeArea())
    }

    /// Debounced auto-save for a row's shop URL. Cancels any pending save
    /// for this row and schedules a new one 600 ms later, so a quick paste
    /// fires once. Failures are swallowed: the URL is still in local state
    /// and will be picked up by `publish()` if the live save was a no-op
    /// (e.g. the `outfit_products` row hasn't been created yet).
    private func scheduleShopLinkSave(entryId: UUID, product: Product, url: String) {
        shopLinkSaveTasks[entryId]?.cancel()
        let outfitId = outfit.id
        shopLinkSaveTasks[entryId] = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String? = trimmed.isEmpty ? nil : trimmed
            try? await ProductLibraryService.setShopURL(value, outfitId: outfitId, product: product)
        }
    }

    private func publish() async {
        isPublishing = true
        // Freshen every entry from the LIVE store copy first: this
        // sheet's snapshot was taken when it opened, and the
        // background thumbnail polish may have swapped in the clean
        // cutout since. Publishing the stale snapshot regressed the
        // card (and the feed row, until its re-sync) back to the raw
        // shot the moment PUBLISH was tapped.
        let liveProducts = store.outfitById[outfit.id]?.products ?? []
        func freshened(_ entry: ProductWithShopLink) -> Product {
            guard let pid = entry.product.productId,
                  let live = liveProducts.first(where: { $0.productId == pid })
            else { return entry.product }
            return live
        }
        // Build product inputs: for pro users, only include products with shop URL on the public card
        let inputs = taggedProducts.map { entry in
            ProductInput(
                outfitId: outfit.id,
                name: entry.product.name,
                price: nil,
                image: freshened(entry).image,
                shopLink: entry.shopURL.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : entry.shopURL.trimmingCharacters(in: .whitespaces),
                productId: entry.product.productId
            )
        }
        do {
            guard let userId = store.userId else { throw PublishError.notAuthenticated }
            try await OutfitService.publishOutfit(
                outfitId: outfit.id,
                caption: caption.isEmpty ? nil : caption,
                products: inputs,
                outfit: outfit,
                userId: userId
            )
            let updatedProducts = taggedProducts.map { entry -> Product in
                var p = freshened(entry)
                let url = entry.shopURL.trimmingCharacters(in: .whitespaces)
                p.shopLink = url.isEmpty ? nil : url
                return p
            }
            await MainActor.run {
                onPublished(caption.isEmpty ? nil : caption, updatedProducts)
                dismiss()
            }
        } catch {
            await MainActor.run { publishError = error.localizedDescription; isPublishing = false }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
    }
}

private enum PublishError: LocalizedError {
    case notAuthenticated
    var errorDescription: String? { "You must be signed in to publish." }
}

// MARK: - Helper

private struct ProductWithShopLink: Identifiable {
    let id = UUID()
    let product: Product
    var shopURL: String
}


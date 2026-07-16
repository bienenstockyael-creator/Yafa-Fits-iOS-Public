import PhotosUI
import SwiftUI

/// Presented when adding a product to an outfit.
/// Two modes: create a new product, or pick one from the library.
struct AddProductSheet: View {
    let userId: UUID
    let outfitId: String
    /// Called with the tagged product and its shop link (nil when the
    /// product has none) — callers thread the link into the in-memory
    /// Product so the Publish sheet and feed BUY see it immediately.
    var onAdded: (ProductLibraryItem, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .create

    enum Mode { case create, library }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .create:  CreateProductView(
                    userId: userId,
                    outfitId: outfitId,
                    onAdded: finish,
                    onOpenCloset: {
                        withAnimation(.easeInOut(duration: 0.2)) { mode = .library }
                    }
                )
                case .library: LibraryPickerView(userId: userId, outfitId: outfitId, onAdded: finish)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(mode == .create ? "New Product" : "Your Closet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if mode == .library {
                        // Entered from the form's FROM YOUR CLOSET
                        // button — standard back chevron returns there.
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { mode = .create }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(AppPalette.textMuted)
                    } else {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
            }
        }
    }

    private func finish(_ item: ProductLibraryItem, shopLink: String?) {
        onAdded(item, shopLink)
        dismiss()
    }
}

// MARK: - Create new product

private struct CreateProductView: View {
    let userId: UUID
    let outfitId: String
    var onAdded: (ProductLibraryItem, String?) -> Void
    /// Flips the sheet to the closet picker — the "it's already in my
    /// closet" path, surfaced INLINE in the form (the old top-right
    /// toolbar toggle sat in the commit slot and nobody found it).
    var onOpenCloset: () -> Void

    @State private var name = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var processedImageURL: String?
    @State private var processingStatus: String?
    @State private var processingError: String?
    @State private var processingTask: Task<Void, Never>?

    // Link import — same scrape the save flow uses (PageScraper:
    // JSON-LD -> og: metas, image re-encoded to a bounded JPEG), then
    // the standard thumbnail pipeline. The link is stored as the
    // product's shop link on save.
    @State private var linkText = ""
    @State private var isImportingLink = false
    @State private var linkError: String?
    @State private var importedShopLink: String?
    /// The raw scraped image, kept so the clean catalog thumbnail can
    /// be generated in the BACKGROUND after save — saving never waits
    /// on the generation.
    @State private var pendingPolishSource: UIImage?

    @State private var isSaving = false
    @State private var saveError: String?

    // Tap-to-focus: the styled field containers are bigger than the
    // text controls inside — a tap anywhere on a field focuses it.
    @FocusState private var linkFocused: Bool
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: LayoutMetrics.medium) {
                    linkSection
                    imageSection
                    nameSection
                    closetButton
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.medium)
            }
            .scrollDismissesKeyboard(.interactively)

            saveButton
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadAndProcess(item) }
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    // MARK: Link import

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            sectionLabel("PRODUCT LINK")

            HStack(spacing: LayoutMetrics.xxSmall) {
                TextField("", text: $linkText, prompt:
                    Text("Paste a product link")
                        .foregroundColor(AppPalette.textFaint)
                )
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($linkFocused)
                .onSubmit { Task { await importFromLink() } }
                .onChange(of: linkText) { oldValue, newValue in
                    // A paste (big jump that looks like a URL) imports
                    // immediately — no separate import button to find.
                    guard !isImportingLink,
                          newValue.count - oldValue.count > 10,
                          newValue.contains(".")
                    else { return }
                    Task { await importFromLink() }
                }

                // One-tap clear, so a long pasted URL can be swapped
                // for another without hammering backspace.
                if !linkText.isEmpty || isImportingLink {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        linkText = ""
                        linkError = nil
                        importedShopLink = nil
                    } label: {
                        Group {
                            if isImportingLink {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(AppPalette.textMuted)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(AppPalette.textFaint)
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .disabled(isImportingLink)
                }
            }
            .padding(LayoutMetrics.xSmall)
            // Same input container as the Publish sheet's fields —
            // frosted appCard, no outlined box.
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .contentShape(Rectangle())
            .onTapGesture { linkFocused = true }

            if let err = linkError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
            } else {
                Text("Fills the photo and name from the shop's page.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.textFaint)
            }
        }
    }

    /// Scrape the pasted page (name + hero image) and feed the image
    /// through the exact pipeline the photo picker uses — so a link
    /// import and a manual photo produce identical products.
    private func importFromLink() async {
        let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isImportingLink else { return }
        let normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), url.host != nil else {
            await MainActor.run { linkError = "That doesn't look like a link" }
            return
        }
        await MainActor.run {
            isImportingLink = true
            linkError = nil
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        defer { Task { @MainActor in isImportingLink = false } }

        guard let enriched = await PageScraper.enrich(url: url) else {
            await MainActor.run { linkError = "Couldn't read a product from that page" }
            return
        }
        // The scrape returns the hero as a base64 JPEG data URI.
        guard let comma = enriched.imageData.range(of: ","),
              let data = Data(base64Encoded: String(enriched.imageData[comma.upperBound...])),
              UIImage(data: data) != nil else {
            await MainActor.run { linkError = "Couldn't load the product photo" }
            return
        }
        await MainActor.run {
            importedShopLink = url.absoluteString
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let scraped = enriched.name {
                name = scraped
            }
        }
        await processLinkImage(data)
    }

    /// Link imports: upload the raw page shot immediately so SAVE
    /// enables in seconds. The REAL thumbnail generation (the save
    /// flow's nano -> tight-crop catalog pipeline) runs in the
    /// background AFTER save via ProductThumbnailPolisher and swaps
    /// into the product when ready — nobody waits on it.
    private func processLinkImage(_ data: Data) async {
        processingTask?.cancel()
        processingTask = nil

        guard let image = UIImage(data: data) else { return }
        let label = await MainActor.run { () -> String in
            selectedImage = image
            processedImageURL = nil
            processingError = nil
            processingStatus = "Uploading…"
            pendingPolishSource = image
            return name.trimmingCharacters(in: .whitespaces)
        }

        processingTask = Task {
            do {
                let url = try await ProductImageService.uploadThumbnail(
                    image,
                    userId: userId,
                    productName: label.isEmpty ? "product" : label
                )
                await MainActor.run { processedImageURL = url; processingStatus = nil }
            } catch {
                await MainActor.run {
                    processingError = error.localizedDescription
                    processingStatus = nil
                    pendingPolishSource = nil
                }
            }
        }
    }

    // MARK: Image

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            sectionLabel("PRODUCT PHOTO")

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack {
                    if let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppPalette.pageBackground)
                            .frame(height: 160)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(AppPalette.cardBorder, lineWidth: 1)
                            )
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(AppPalette.textFaint)
                                    Text("Choose a photo")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppPalette.textMuted)
                                    Text("For best results, use a clean photo or\nscreenshot without people or hangers.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppPalette.textFaint)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 16)
                                }
                            }
                    }

                    // Processing overlay — spinner only, no distracting status text
                    if processingStatus != nil {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.4))
                            .frame(height: 160)
                        ProgressView().tint(.white).scaleEffect(1.2)
                    }

                    // Link import ready: the raw shot will be polished
                    // into a clean thumbnail in the background after
                    // save — same sparkle language as generating fits.
                    if pendingPolishSource != nil, processedImageURL != nil, processingStatus == nil {
                        GenerationStarField(starSize: 140, interactive: false)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .allowsHitTesting(false)
                    }

                    // Done checkmark
                    if processedImageURL != nil && processingStatus == nil {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .background(Color.green.clipShape(Circle()))
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .buttonStyle(SolidPressButtonStyle())

            if let err = processingError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
            } else if pendingPolishSource != nil, processedImageURL != nil {
                // The sparkles mean "polishes in the background" —
                // NOT "wait here". Say so, or people wait at the sheet.
                Text("Save now — the thumbnail cleans itself up in the background.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.textFaint)
            }
        }
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            sectionLabel("PRODUCT NAME")
            TextField("", text: $name, prompt:
                Text("e.g. Wide Leg Jeans")
                    .foregroundColor(AppPalette.textFaint)
            )
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textPrimary)
            .focused($nameFocused)
            .padding(LayoutMetrics.xSmall)
            // Same input container as the Publish sheet's fields.
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .contentShape(Rectangle())
            .onTapGesture { nameFocused = true }
        }
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("SAVE PRODUCT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(canSave ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.vertical, LayoutMetrics.xSmall)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(!canSave || isSaving)
        .background(AppPalette.groupedBackground)
    }

    /// Alternative source, peer of link/photo: pick something already
    /// saved in the closet and tag it on this fit (no duplicate row).
    /// The app's standard elevated capsule (appCapsule — SHARE/Cancel
    /// family): soft drop shadow, icon + sentence-case label.
    private var closetButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onOpenCloset()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tshirt")
                    .font(.system(size: 13, weight: .semibold))
                Text("From your closet")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && processedImageURL != nil
    }

    // MARK: Logic

    private func loadAndProcess(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              UIImage(data: data) != nil else { return }
        // A hand-picked photo is not a shop import — drop any link
        // (and pending polish) carried over from a previous import so
        // the save stays honest.
        await MainActor.run { importedShopLink = nil; pendingPolishSource = nil }
        await processImageData(data)
    }

    /// Shared tail of both flows (photo picker + link import):
    /// preview immediately, then segment/upload for the thumbnail.
    private func processImageData(_ data: Data) async {
        // Cancel any in-flight upload before starting a new one
        processingTask?.cancel()
        processingTask = nil

        guard let image = UIImage(data: data) else { return }

        await MainActor.run { selectedImage = image; processedImageURL = nil; processingError = nil }

        processingTask = Task {
            do {
                let url = try await ProductImageService.processAndUpload(
                    imageData: data,
                    userId: userId,
                    productName: name.isEmpty ? "product" : name,
                    onStatus: { status in
                        await MainActor.run { processingStatus = status }
                    }
                )
                await MainActor.run { processedImageURL = url; processingStatus = nil }
            } catch {
                await MainActor.run { processingError = error.localizedDescription; processingStatus = nil }
            }
        }
    }

    private func save() async {
        guard let imageURL = processedImageURL else { return }
        isSaving = true
        do {
            let item = try await ProductLibraryService.createProduct(
                userId: userId,
                name: name.trimmingCharacters(in: .whitespaces),
                imageURL: imageURL,
                tags: []
            )
            // Retry tagging once — product is created, we must not orphan it
            do {
                try await ProductLibraryService.tagOutfit(outfitId: outfitId, productId: item.id)
            } catch {
                try await ProductLibraryService.tagOutfit(outfitId: outfitId, productId: item.id)
            }
            // Link-imported products keep their shop link (powers the
            // BUY button). Best-effort — the product itself is saved.
            if let link = importedShopLink {
                try? await ProductLibraryService.setShopURL(link, outfitId: outfitId, productId: item.id)
                // Also on the products row itself (source_url), so
                // future closet picks of this item carry the link.
                try? await WardrobeService.updateItem(id: item.id, sourceURL: link)
            }
            // Kick the catalog-thumbnail generation into the
            // background — it outlives this sheet and swaps the
            // interim raw shot when ready.
            if let source = pendingPolishSource {
                await ProductThumbnailPolisher.shared.polish(
                    productId: item.id,
                    outfitId: outfitId,
                    label: name.trimmingCharacters(in: .whitespaces),
                    userId: userId,
                    raw: source
                )
            }
            await MainActor.run { onAdded(item, importedShopLink) }
        } catch {
            await MainActor.run { saveError = error.localizedDescription; isSaving = false }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
    }
}

// MARK: - Pick from library

private struct LibraryPickerView: View {
    let userId: UUID
    let outfitId: String
    var onAdded: (ProductLibraryItem, String?) -> Void

    @State private var products: [ProductLibraryItem] = []
    @State private var isLoading = true
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [ProductLibraryItem] {
        guard !search.isEmpty else { return products }
        let q = search.lowercased()
        return products.filter {
            $0.name.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppPalette.textFaint)
                TextField("", text: $search, prompt:
                    Text("Search your closet…")
                        .foregroundColor(AppPalette.textFaint)
                )
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textPrimary)
                .focused($searchFocused)
            }
            .padding(LayoutMetrics.xSmall)
            // Same input container as the sheet's other fields — the
            // old groupedBackground-on-groupedBackground box was
            // invisible (a floating magnifier, no field).
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.vertical, LayoutMetrics.xSmall)

            if isLoading {
                Spacer()
                ProgressView().tint(AppPalette.textMuted)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(products.isEmpty ? "Nothing in your closet yet" : "No results")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textFaint)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { product in
                            Button {
                                Task {
                                    try? await ProductLibraryService.tagOutfit(
                                        outfitId: outfitId,
                                        productId: product.id
                                    )
                                    // Closet items keep their shop link
                                    // on the fit too.
                                    if let link = product.sourceURL, !link.isEmpty {
                                        try? await ProductLibraryService.setShopURL(
                                            link, outfitId: outfitId, productId: product.id
                                        )
                                    }
                                    onAdded(product, product.sourceURL)
                                }
                            } label: {
                                libraryRow(product)
                            }
                            .buttonStyle(SolidPressButtonStyle())
                            Divider().opacity(0.5).padding(.leading, 72)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
            }
        }
        .task { await load() }
    }

    private func libraryRow(_ product: ProductLibraryItem) -> some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.96))
                if let productImageURL = URL(string: product.imageURL) {
                    CachedRemoteImage(url: productImageURL, maxPixelSize: 640, contentMode: .fit) {
                        Color.clear
                    }
                    .padding(4)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(product.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.textPrimary)
                if !product.tags.isEmpty {
                    Text(product.tags.prefix(3).joined(separator: " · ").uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(AppPalette.textFaint)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(AppPalette.textFaint)
        }
        .padding(.vertical, LayoutMetrics.xSmall)
    }

    private func load() async {
        do {
            let items = try await ProductLibraryService.fetchProducts(userId: userId)
            await MainActor.run { products = items; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

import SwiftUI

/// The wardrobe (product closet): every product the user has tagged,
/// shown as a filterable grid.
///
/// Sources items from the *union* of two places, so it shows
/// everything ever tagged without any data migration (mirroring how
/// the try-on closet already sources items):
///   1. The `products` table — canonical owned + wishlist items
///      (`WardrobeItem`, editable, carrying category/status/etc.).
///   2. Inline products attached to the user's outfits
///      (`Outfit.products`) that never landed in `products` — shown
///      read-only with an inferred category until promoted.
///
/// Deduped by normalized name AND image URL; real `products` rows win
/// over inline duplicates so the editable copy is the one that shows.
struct WardrobeView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let userId: UUID

    @State private var libraryItems: [WardrobeItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var categoryFilter: WardrobeCategory? = nil  // nil == All
    @State private var statusFilter: WardrobeStatus? = nil      // nil == All
    @State private var searchText: String = ""
    @State private var selectedItem: WardrobeDisplayItem?

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            content
                .background(AppPalette.groupedBackground)
                .navigationTitle("Closet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.light, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search your closet"
                )
                .sheet(item: $selectedItem) { item in
                    WardrobeItemDetailSheet(item: item, userId: userId) {
                        await load()
                    }
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppPalette.groupedBackground)
                }
                .task { await load() }
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allItems.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            if filteredItems.isEmpty {
                noMatchesState
                    .padding(.top, LayoutMetrics.xLarge)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredItems) { item in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedItem = item
                        } label: {
                            WardrobeItemCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.large)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "All", isOn: categoryFilter == nil) { categoryFilter = nil }
                    ForEach(availableCategories, id: \.self) { cat in
                        chip(title: cat.label, isOn: categoryFilter == cat) {
                            categoryFilter = (categoryFilter == cat) ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
            }

            // Owned / Wishlist only appears once the user actually has
            // wishlist items (e.g. from the future Chrome extension) —
            // otherwise it's noise.
            if hasWishlistItems {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(title: "All items", isOn: statusFilter == nil) { statusFilter = nil }
                        chip(title: "Owned", isOn: statusFilter == .owned) {
                            statusFilter = (statusFilter == .owned) ? nil : .owned
                        }
                        chip(title: "Wishlist", isOn: statusFilter == .wishlist) {
                            statusFilter = (statusFilter == .wishlist) ? nil : .wishlist
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
            }
        }
        .padding(.top, LayoutMetrics.xSmall)
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.white : AppPalette.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? AppPalette.textPrimary : AppPalette.cardFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: isOn ? 0 : 0.75)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .tshirt, size: 28, color: AppPalette.textFaint)
            Text("Your closet is empty")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
            Text("Tag products on your outfits and they'll collect here.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutMetrics.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            Text("No items match")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
            Text("Try a different filter or search.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Union + filtering

    /// The full deduped closet (products table ∪ inline outfit products).
    private var allItems: [WardrobeDisplayItem] {
        var seenNames = Set<String>()
        var seenURLs = Set<String>()
        var items: [WardrobeDisplayItem] = []

        func consider(name: String, url: String) -> Bool {
            let n = Self.nameKey(name)
            let u = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && seenNames.contains(n) { return false }
            if !u.isEmpty && seenURLs.contains(u) { return false }
            if !n.isEmpty { seenNames.insert(n) }
            if !u.isEmpty { seenURLs.insert(u) }
            return true
        }

        // Real products-table rows first (so they win dedup).
        for item in libraryItems {
            guard consider(name: item.name, url: item.imageURL) else { continue }
            // Stored category wins; fall back to keyword inference while
            // most rows still carry the default 'unknown' (decoded as
            // `.other`).
            let category = WardrobeCategory(rawValue: item.category)
                ?? WardrobeCategory.inferring(from: item.name)
            items.append(WardrobeDisplayItem(
                id: item.id.uuidString,
                name: item.name,
                imageURL: item.imageURL,
                category: category,
                status: WardrobeStatus(rawValue: item.status) ?? .owned,
                brand: item.brand,
                price: item.price,
                sourceURL: item.sourceURL,
                productId: item.id
            ))
        }

        // Inline outfit products (read-only, inferred category, owned).
        for outfit in store.outfits {
            for product in outfit.products ?? [] {
                guard let resolved = product.resolvedImageURL?.absoluteString else { continue }
                guard consider(name: product.name, url: resolved) else { continue }
                items.append(WardrobeDisplayItem(
                    id: "outfit-\(product.id)-\(outfit.id)",
                    name: product.name,
                    imageURL: resolved,
                    category: WardrobeCategory.inferring(from: product.name),
                    status: .owned,
                    brand: nil,
                    price: product.price,
                    sourceURL: product.shopLink,
                    productId: product.productId
                ))
            }
        }
        return items
    }

    private var filteredItems: [WardrobeDisplayItem] {
        let query = Self.nameKey(searchText)
        return allItems.filter { item in
            if let categoryFilter, item.category != categoryFilter { return false }
            if let statusFilter, item.status != statusFilter { return false }
            if !query.isEmpty {
                let haystack = Self.nameKey(item.name) + " " + (item.brand.map(Self.nameKey) ?? "")
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    /// Categories actually present, in a stable display order.
    private var availableCategories: [WardrobeCategory] {
        let present = Set(allItems.map(\.category))
        return WardrobeCategory.displayOrder.filter { present.contains($0) }
    }

    private var hasWishlistItems: Bool {
        allItems.contains { $0.status == .wishlist }
    }

    /// Aggressive normalization shared by dedup + search: lowercase,
    /// trim, strip trailing "(2)" / " 3" counters, collapse spaces.
    private static func nameKey(_ s: String) -> String {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = lower.replacingOccurrences(
            of: "\\s*\\(?\\s*\\d+\\s*\\)?\\s*$",
            with: "",
            options: .regularExpression
        )
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Loading

    private func load() async {
        do {
            let items = try await WardrobeService.fetchCloset(userId: userId)
            await MainActor.run {
                libraryItems = items
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Display model

/// UI-layer unification of a `products`-table `WardrobeItem` and an
/// inline `Outfit.products` entry. `productId` is non-nil only when
/// the item is backed by an editable `products` row.
struct WardrobeDisplayItem: Identifiable, Hashable {
    let id: String
    let name: String
    let imageURL: String
    let category: WardrobeCategory
    let status: WardrobeStatus
    let brand: String?
    let price: String?
    let sourceURL: String?
    let productId: UUID?

    /// Resolves possibly-relative image paths against the site base URL
    /// (same as `Product.resolvedImageURL`).
    var resolvedImageURL: URL? {
        let trimmed = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let abs = URL(string: trimmed), abs.scheme != nil { return abs }
        let normalized = trimmed.hasPrefix("/")
            ? String(trimmed.dropFirst())
            : trimmed.replacingOccurrences(of: "^\\./?", with: "", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }
        return AppConfig.siteBaseURL.appendingPathComponent(normalized)
    }
}

// MARK: - Cell

private struct WardrobeItemCell: View {
    let item: WardrobeDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Trimmed product on a clean tile — consistent sizing across
            // items, matching the app's soft card surfaces.
            TrimmedRemoteImage(url: item.resolvedImageURL, contentPadding: 16)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                )
                .overlay(alignment: .topLeading) {
                    if item.status == .wishlist {
                        Text("WISHLIST")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppPalette.uploadGlow))
                            .padding(8)
                    }
                }
                .shadow(color: AppPalette.cardShadow, radius: 9, y: 4)

            Text(item.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppPalette.textStrong)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
    }
}

// MARK: - Item detail / edit

/// Tap-to-edit sheet for a wardrobe item.
///
/// Two modes, keyed on whether the item is backed by a `products`
/// row (`item.productId != nil`):
///   • Backed → edits update that row in place.
///   • Inline (an `Outfit.products` entry not yet in the closet) →
///     saving *promotes* it by creating a real `products` row. The
///     union dedup then collapses the inline copy into the new row,
///     so it becomes editable from then on.
private struct WardrobeItemDetailSheet: View {
    let item: WardrobeDisplayItem
    let userId: UUID
    /// Called after a successful save so the closet can reload.
    var onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var name: String
    @State private var category: WardrobeCategory
    @State private var brand: String
    @State private var price: String
    @State private var sourceURL: String
    @State private var status: WardrobeStatus
    @State private var isSaving = false
    @State private var saveError: String?

    private var isBacked: Bool { item.productId != nil }

    init(item: WardrobeDisplayItem, userId: UUID, onChanged: @escaping () async -> Void) {
        self.item = item
        self.userId = userId
        self.onChanged = onChanged
        _name = State(initialValue: item.name)
        _category = State(initialValue: item.category)
        _brand = State(initialValue: item.brand ?? "")
        _price = State(initialValue: item.price ?? "")
        _sourceURL = State(initialValue: item.sourceURL ?? "")
        _status = State(initialValue: item.status)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.medium) {
                    image
                    if !isBacked {
                        Text("This item is tagged on an outfit. Saving adds it to your closet so you can edit it.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    fields
                    if !sourceURL.isEmpty, let linkURL = URL(string: sourceURL) {
                        Button { openURL(linkURL) } label: {
                            Text("Open product link")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppPalette.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Capsule().fill(AppPalette.cardFill))
                                .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(LayoutMetrics.screenPadding)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(isBacked ? "Edit item" : "Add to closet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isBacked ? "Save" : "Add") { Task { await save() } }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSave ? AppPalette.textPrimary : AppPalette.textFaint)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var image: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(AppPalette.cardFill)
            AsyncImage(url: URL(string: item.imageURL)) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFit().padding(LayoutMetrics.small)
                } else if phase.error != nil {
                    AppIcon(glyph: .tshirt, size: 32, color: AppPalette.textFaint)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(height: 220)
    }

    private var fields: some View {
        VStack(spacing: LayoutMetrics.small) {
            labeledField("NAME") {
                TextField("Item name", text: $name)
                    .textInputAutocapitalization(.words)
            }
            labeledField("CATEGORY") {
                Menu {
                    ForEach(WardrobeCategory.displayOrder, id: \.self) { c in
                        Button(c.label) { category = c }
                    }
                } label: {
                    HStack {
                        Text(category.label)
                            .foregroundStyle(AppPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
            }
            labeledField("BRAND") {
                TextField("Optional", text: $brand)
                    .textInputAutocapitalization(.words)
            }
            labeledField("PRICE") {
                TextField("Optional", text: $price)
            }
            labeledField("LINK") {
                TextField("Optional product URL", text: $sourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            labeledField("STATUS") {
                Picker("", selection: $status) {
                    Text("Owned").tag(WardrobeStatus.owned)
                    Text("Wishlist").tag(WardrobeStatus.wishlist)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)
            content()
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppPalette.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() async {
        isSaving = true
        saveError = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let pid = item.productId {
                try await WardrobeService.updateItem(
                    id: pid,
                    name: trimmed,
                    category: category.rawValue,
                    brand: brand,
                    price: price,
                    sourceURL: sourceURL,
                    status: status
                )
            } else {
                _ = try await WardrobeService.createItem(
                    userId: userId,
                    name: trimmed,
                    imageURL: item.imageURL,
                    category: category.rawValue,
                    brand: brand.isEmpty ? nil : brand,
                    price: price.isEmpty ? nil : price,
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    status: status
                )
            }
            await onChanged()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}


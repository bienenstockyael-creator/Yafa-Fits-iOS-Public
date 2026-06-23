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
    /// Items deleted this session — filtered out immediately so the grid
    /// updates even before the (cached) outfit list re-syncs.
    @State private var deletedItemIDs: Set<String> = []

    /// Apple Photos–style zoom: pinch to change how many columns the grid
    /// shows. Persisted so the closet remembers your preferred density.
    @AppStorage("yafa.closetColumns") private var columnCount: Int = 2
    /// Live, damped scale applied to the grid during a pinch for continuous
    /// feedback; springs back to 1 (and commits a new column count) on
    /// release — so the zoom feels fluid instead of snapping mid-gesture.
    /// Small compensating scale so tile *size* stays continuous while the
    /// column count steps during a pinch (the integer layout can only jump,
    /// the scale fills the gaps). Always ~0.85–1.2, so it never shoves
    /// content off-screen.
    @State private var pinchScale: CGFloat = 1
    /// Column count when the current pinch began, so the gesture maps
    /// absolute (not incrementally drifting).
    @State private var pinchStartColumns: Int?
    /// True while a pinch is in progress — used to lock scrolling so the
    /// content doesn't drift as you zoom.
    @State private var isPinching = false
    /// The focal point of the current pinch (midpoint of the two fingers),
    /// in the grid's unit space — so the zoom originates from your fingers
    /// rather than the content's center.
    @State private var pinchAnchor: UnitPoint = .center

    private static let minColumns = 2
    private static let maxColumns = 4
    private let gridSpacing: CGFloat = 14

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    /// Changes when the category/status filter changes (NOT on search or
    /// zoom), so the grid re-identifies and the swap animates as a clean
    /// scale + fade instead of items sliding.
    private var gridIdentity: String {
        "\(categoryFilter?.rawValue ?? "all")|\(statusFilter?.rawValue ?? "all")"
    }

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
                .sheet(item: $selectedItem) { item in
                    WardrobeItemDetailSheet(
                        item: item,
                        userId: userId,
                        onChanged: { await load() },
                        onDeleted: {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                                _ = deletedItemIDs.insert(item.id)
                            }
                        }
                    )
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppPalette.groupedBackground)
                }
                .task { await load() }
        }
        // Fixed light palette across the app — keep the sheet light so the
        // search field text stays readable in dark mode.
        .preferredColorScheme(.light)
    }

    /// Same look as the public-feed search bar (appCard 14 / search icon /
    /// 13pt), but a live text field that filters the grid.
    private var searchBar: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .search, size: 14, color: AppPalette.textFaint)
            TextField("Search your closet", text: $searchText)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textStrong)
                .tint(AppPalette.textStrong)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppPalette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, LayoutMetrics.small)
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
                searchBar
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
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(filteredItems) { item in
                        Button {
                            // Ignore the stray tap that a finger-lift after a
                            // pinch can register.
                            guard !isPinching else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedItem = item
                        } label: {
                            WardrobeItemCell(item: item, showCategory: columnCount <= 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.large)
                // Zoom from the pinch focal point, not the content center.
                .scaleEffect(pinchScale, anchor: pinchAnchor)
                // Gesture lives on the grid so `startAnchor` is in the grid's
                // own coordinate space (the finger midpoint).
                .simultaneousGesture(zoomGesture)
                // Category/status change swaps the grid's identity, so it's a
                // clean scale + fade (no items sliding to new positions). The
                // thumbnail cache keeps the new grid from flickering.
                .id(gridIdentity)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .scrollIndicators(.hidden)
        // Lock the scroll while pinching so the content doesn't drift under
        // your fingers as you zoom (two-finger pinch was also reading as a
        // scroll).
        .scrollDisabled(isPinching)
    }

    /// Pinch out → fewer/bigger tiles; pinch in → more/smaller. Mirrors the
    /// Photos app: the grid scales live under your fingers, then springs to
    /// the new column count when you let go. Two-finger pinch coexists with
    /// one-finger scroll.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                pinchAnchor = value.startAnchor   // finger midpoint
                if pinchStartColumns == nil { pinchStartColumns = columnCount }
                let start = pinchStartColumns ?? columnCount
                // Continuous desired column count (zoom out → bigger tiles →
                // fewer columns), then the nearest whole layout to render.
                let desired = min(
                    Double(Self.maxColumns),
                    max(Double(Self.minColumns), Double(start) / value.magnification)
                )
                let whole = Int(desired.rounded())
                if whole != columnCount {
                    columnCount = whole          // steps 2→3→4 mid-pinch
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                // Fill the gap between the whole layout and the continuous
                // desired size with scale → tile size never jumps.
                pinchScale = CGFloat(columnCount) / CGFloat(desired)
            }
            .onEnded { _ in
                pinchStartColumns = nil
                // Softer settle to the clean column width.
                withAnimation(.easeInOut(duration: 0.45)) { pinchScale = 1 }
                // Keep `isPinching` true a beat longer so the finger-lift
                // doesn't register as a tap (opening an item) and scrolling
                // doesn't snap back mid-settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    isPinching = false
                }
            }
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
            // Soft fade for the grid swap — no springiness.
            withAnimation(.easeInOut(duration: 0.3)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.white : AppPalette.textMuted)
                .padding(.horizontal, 14)
                .frame(height: 34)
                // Selected: solid dark fill on top of the frosted capsule.
                .background {
                    if isOn {
                        Capsule(style: .continuous).fill(AppPalette.textStrong)
                    }
                }
                // Unselected: the app's standard frosted-glass capsule (same
                // treatment as TagPill / appCapsule everywhere else).
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.medium) {
            AppIcon(glyph: .tshirt, size: 30, color: AppPalette.textMuted)
                .frame(width: 76, height: 76)
                .appCircle(shadowRadius: 0, shadowY: 0)
            VStack(spacing: 7) {
                Text("Your closet is empty")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text("Tag products on your outfits and they’ll collect here automatically.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, LayoutMetrics.xLarge)
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
        return items.filter { !deletedItemIDs.contains($0.id) }
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
    /// Show the category pill only when the grid is sparse (2 columns) —
    /// hidden when dense so tiles stay clean.
    var showCategory: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Product floats with no card behind it (minimal). A fixed
            // aspect box scales the tile with the column width so the grid
            // reflows cleanly when you pinch-zoom.
            Color.clear
                .aspectRatio(0.85, contentMode: .fit)
                .overlay {
                    TrimmedRemoteImage(url: item.resolvedImageURL, contentPadding: 6)
                }
                .overlay(alignment: .topLeading) {
                    if item.status == .wishlist {
                        Text("WISHLIST")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppPalette.uploadGlow))
                    }
                }

            // Quiet caption — the garment is the hero.
            Text(item.name)
                .font(.system(size: 11.5))
                .foregroundStyle(AppPalette.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 1)

            if showCategory, item.category != .other {
                TagPill(tag: item.category.label)
                    .scaleEffect(0.85, anchor: .leading)
            }
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
    /// Called after a successful delete so the closet can drop it locally.
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(OutfitStore.self) private var store

    @State private var name: String
    @State private var category: WardrobeCategory
    @State private var brand: String
    @State private var price: String
    @State private var sourceURL: String
    @State private var status: WardrobeStatus
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirm = false

    init(
        item: WardrobeDisplayItem,
        userId: UUID,
        onChanged: @escaping () async -> Void,
        onDeleted: @escaping () -> Void = {}
    ) {
        self.item = item
        self.userId = userId
        self.onChanged = onChanged
        self.onDeleted = onDeleted
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
                VStack(spacing: LayoutMetrics.large) {
                    productImage
                    formCard
                    statusSection
                    if !sourceURL.isEmpty, let linkURL = URL(string: sourceURL) {
                        openLinkButton(linkURL)
                    }
                    taggedOnSection
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    deleteButton
                }
                .padding(LayoutMetrics.screenPadding)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 14))
                        .foregroundStyle(AppPalette.textMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSave ? AppPalette.textStrong : AppPalette.textFaint)
                        .disabled(!canSave)
                }
            }
        }
        // The app uses a fixed light palette; pin the sheet to light so
        // system controls (text fields, segmented picker) stay readable
        // even when the phone is in dark mode.
        .preferredColorScheme(.light)
        .alert("Remove from closet?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) { Task { await deleteItem() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes “\(item.name)” from your closet and untags it from any outfits it's on.")
        }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showDeleteConfirm = true
        } label: {
            Text("Remove from closet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.plain)
        .padding(.top, LayoutMetrics.xSmall)
    }

    private func deleteItem() async {
        do {
            try await WardrobeService.deleteItem(productId: item.productId, name: item.name)
            onDeleted()
            await onChanged()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Product floats directly on the grouped background — no card.
    private var productImage: some View {
        TrimmedRemoteImage(url: item.resolvedImageURL)
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .padding(.top, LayoutMetrics.xSmall)
    }

    /// All editable fields in one inset card with hairline row dividers
    /// (iOS grouped-form feel) instead of a stack of separate cards.
    private var formCard: some View {
        VStack(spacing: 0) {
            formRow("Name") {
                TextField("Item name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            rowDivider
            HStack {
                Text("Category")
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                Spacer(minLength: 16)
                Menu {
                    ForEach(WardrobeCategory.displayOrder, id: \.self) { c in
                        Button(c.label) { category = c }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(category.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppPalette.textStrong)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            rowDivider
            formRow("Brand") {
                TextField("Add brand", text: $brand)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            rowDivider
            formRow("Price") {
                TextField("Add price", text: $price)
                    .multilineTextAlignment(.trailing)
            }
            rowDivider
            formRow("Link") {
                TextField("Add URL", text: $sourceURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }
        .padding(.vertical, 2)
        // Same frosted-glass card as the carousel's product detail card.
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
    }

    private func formRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.textMuted)
            Spacer(minLength: 16)
            content()
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.textStrong)
                .tint(AppPalette.textStrong)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppPalette.cardBorder)
            .frame(height: 0.75)
            .padding(.leading, 16)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STATUS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)
            Picker("", selection: $status) {
                Text("Owned").tag(WardrobeStatus.owned)
                Text("Wishlist").tag(WardrobeStatus.wishlist)
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLinkButton(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: "bag")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open product link")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppPalette.textStrong)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    /// Mini carousel of the outfits this product is currently tagged on.
    @ViewBuilder
    private var taggedOnSection: some View {
        let outfits = taggedOutfits
        if !outfits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("TAGGED ON")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppPalette.textFaint)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(outfits) { outfit in
                            RotatableOutfitImage(outfit: outfit, height: 150, draggable: false, eagerLoad: true)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taggedOutfits: [Outfit] {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let myName = norm(item.name)
        let myURL = item.resolvedImageURL?.absoluteString
        return store.outfits.filter { outfit in
            (outfit.products ?? []).contains { p in
                if let pid = item.productId, let ppid = p.productId { return ppid == pid }
                if !myName.isEmpty && norm(p.name) == myName { return true }
                if let myURL, p.resolvedImageURL?.absoluteString == myURL { return true }
                return false
            }
        }
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


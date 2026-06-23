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

    @State private var categoryFilter: ProductCategory? = nil  // nil == All
    @State private var statusFilter: WardrobeStatus? = nil      // nil == All
    @State private var searchText: String = ""

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
                        WardrobeItemCell(item: item)
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
                        chip(title: cat.wardrobeLabel, isOn: categoryFilter == cat) {
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
            // most rows still carry the default 'unknown'.
            let category = item.categoryEnum == .unknown
                ? ProductCategory.inferring(from: item.name)
                : item.categoryEnum
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
                    category: ProductCategory.inferring(from: product.name),
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
    private var availableCategories: [ProductCategory] {
        let present = Set(allItems.map(\.category))
        let order: [ProductCategory] = [.top, .bottom, .fullBody, .shoes, .unknown]
        return order.filter { present.contains($0) }
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
    let category: ProductCategory
    let status: WardrobeStatus
    let brand: String?
    let price: String?
    let sourceURL: String?
    let productId: UUID?
}

// MARK: - Cell

private struct WardrobeItemCell: View {
    let item: WardrobeDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: LayoutMetrics.compactCornerRadius, style: .continuous)
                    .fill(AppPalette.cardFill)
                AsyncImage(url: URL(string: item.imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(8)
                    case .empty:
                        ProgressView().scaleEffect(0.7)
                    case .failure:
                        AppIcon(glyph: .tshirt, size: 22, color: AppPalette.textFaint)
                    @unknown default:
                        Color.clear
                    }
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.compactCornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if item.status == .wishlist {
                    Text("Wishlist")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppPalette.uploadGlow))
                        .padding(6)
                }
            }

            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)

            if let price = item.price, !price.isEmpty {
                Text(price)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.textMuted)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Category labels

private extension ProductCategory {
    var wardrobeLabel: String {
        switch self {
        case .top: return "Tops"
        case .bottom: return "Bottoms"
        case .fullBody: return "Full body"
        case .shoes: return "Shoes"
        case .unknown: return "Other"
        }
    }
}

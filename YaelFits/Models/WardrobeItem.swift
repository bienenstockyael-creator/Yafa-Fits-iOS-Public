import Foundation

/// One item in a user's wardrobe (the product closet).
///
/// Backed by the `public.products` table, which the Phase 0
/// migration extended with wardrobe columns (`brand`, `color`,
/// `category`, `price`, `source_url`, `status`). This is the richer
/// successor to `ProductLibraryItem` — kept as a separate type so
/// the legacy product-library/try-on flows that decode
/// `ProductLibraryItem` are untouched while the wardrobe feature is
/// built on `feature/wardrobe`. Old call sites can migrate onto this
/// type later.
///
/// Decoded only from full-row sources (`select()` / the
/// `find_similar_products` RPC which returns `setof products`), so
/// the NOT-NULL columns (`category`, `status`) are non-optional.
struct WardrobeItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// Nullable in the DB (`user_id` is nullable on `products`), so
    /// optional here to avoid a decode failure on any legacy row that
    /// predates per-user ownership.
    let userId: UUID?
    let name: String
    let imageURL: String
    let tags: [String]?

    // Wardrobe columns (Phase 0).
    let brand: String?
    let color: String?
    /// Free-form category string. NOT NULL in the DB (default
    /// `'unknown'`). Mapped to `ProductCategory` via `categoryEnum`
    /// where the value is a known case.
    let category: String
    let price: String?
    /// Purchase / shop link. Unifies the legacy per-outfit
    /// `shop_link` and the future wishlist URL captured by the Chrome
    /// extension.
    let sourceURL: String?
    /// `"owned"` | `"wishlist"`. NOT NULL in the DB (default
    /// `'owned'`), enforced by a check constraint.
    let status: String

    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, tags, brand, color, category, price, status
        case userId = "user_id"
        case imageURL = "image_url"
        case sourceURL = "source_url"
        case createdAt = "created_at"
    }

    /// Title-cased name for display. Mirrors `ProductLibraryItem`.
    var displayName: String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Best-effort map to the existing keyword taxonomy. Falls back
    /// to `.unknown` for values outside `ProductCategory`'s cases
    /// (e.g. future `outerwear` / `accessory` labels).
    var categoryEnum: ProductCategory {
        ProductCategory(rawValue: category) ?? .unknown
    }

    var isWishlist: Bool { status == WardrobeStatus.wishlist.rawValue }
}

/// The two ownership states a wardrobe item can be in. String-backed
/// so it round-trips the `products.status` column directly.
enum WardrobeStatus: String, Codable, Sendable, CaseIterable {
    case owned
    case wishlist
}

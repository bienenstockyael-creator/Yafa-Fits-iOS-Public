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
    /// `'unknown'`). Mapped to `WardrobeCategory` via `categoryValue`
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

    /// The stored category as a `WardrobeCategory`, or `.other` when
    /// the column holds an unrecognized value (e.g. the `'unknown'`
    /// default before anything has been labeled). Callers that want
    /// keyword inference for unlabeled items should fall back to
    /// `WardrobeCategory.inferring(from:)` themselves.
    var categoryValue: WardrobeCategory {
        WardrobeCategory(rawValue: category) ?? .other
    }

    var isWishlist: Bool { status == WardrobeStatus.wishlist.rawValue }
}

/// A fuzzy "already in your closet?" match returned by the
/// `find_similar_products` RPC. Unlike `WardrobeItem`, this spans both
/// real `products` rows AND inline `outfit_products` tags, so
/// `productId` is nil for inline matches (which have no products row).
struct ClosetMatch: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let imageURL: String
    let sourceURL: String?
    let price: String?
    let productId: UUID?

    enum CodingKeys: String, CodingKey {
        case name, price
        case imageURL = "image_url"
        case sourceURL = "source_url"
        case productId = "product_id"
    }

    /// Stable identity for ForEach — the products id when present, else
    /// the (deduped) name.
    var id: String { productId?.uuidString ?? name.lowercased() }

    var displayName: String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Resolves a possibly-relative image path (e.g. `/products/x.webp`,
    /// common on inline outfit-product tags) to an absolute URL, the
    /// same way `Product.resolvedImageURL` does. Absolute URLs pass
    /// through unchanged.
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

/// The wardrobe's own, richer clothing taxonomy — independent of the
/// try-on `ProductCategory` (which only needs top/bottom/shoes for its
/// carousels). Drives the closet's filter chips. String-backed so it
/// round-trips the `products.category` column.
enum WardrobeCategory: String, CaseIterable, Sendable {
    case top
    case outerwear
    case dress
    case pants
    case skirt
    case shoes
    case accessory
    case other

    var label: String {
        switch self {
        case .top:       return "Tops"
        case .outerwear: return "Outerwear"
        case .dress:     return "Dresses"
        case .pants:     return "Pants"
        case .skirt:     return "Skirts"
        case .shoes:     return "Shoes"
        case .accessory: return "Accessories"
        case .other:     return "Other"
        }
    }

    /// Stable order for the filter chips.
    static let displayOrder: [WardrobeCategory] =
        [.top, .outerwear, .dress, .pants, .skirt, .shoes, .accessory, .other]

    /// Infer a category from a product name via keyword matching.
    ///
    /// Order is deliberate: shoes and outerwear are checked before
    /// generic tops/bottoms (a "denim jacket" is outerwear, not
    /// pants; a "sweater dress" is a dress, not a top), and the
    /// accessory net is cast LAST so layering words like "belted"
    /// trench/dress don't get miscaught as a belt. Keyword tokens are
    /// chosen to avoid common substring collisions (e.g. "shorts" not
    /// "short" → won't grab "short sleeve"; "boots" not "boot" →
    /// won't grab "bootcut").
    static func inferring(from name: String) -> WardrobeCategory {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }

        if has(["shoe", "sneaker", "trainer", "boots", "bootie", "heel",
                "sandal", "loafer", "mule", "clog", "slipper", "espadrille",
                "ballet flat", "flats", "pump", "stiletto", "wedge"]) {
            return .shoes
        }
        if has(["coat", "jacket", "blazer", "parka", "trench", "puffer",
                "anorak", "windbreaker", "raincoat", "overcoat", "cardigan",
                "poncho", "cape", "gilet", "vest"]) {
            return .outerwear
        }
        if has(["dress", "gown", "jumpsuit", "romper", "playsuit", "bodysuit"]) {
            return .dress
        }
        if has(["skirt", "skort"]) {
            return .skirt
        }
        if has(["pant", "trouser", "jean", "denim", "shorts", "legging",
                "chino", "cargo", "culotte", "sweatpant", "jogger", "slack",
                "capri", "palazzo", "flare"]) {
            return .pants
        }
        if has(["top", "shirt", "tee", "t-shirt", "tshirt", "blouse",
                "sweater", "jumper", "knit", "hoodie", "sweatshirt", "tank",
                "cami", "camisole", "turtleneck", "polo", "bralette", "crop",
                "henley", "tunic", "bodice", "corset", "bustier"]) {
            return .top
        }
        if has(["bag", "tote", "clutch", "purse", "backpack", "handbag",
                "belt", "scarf", "hat", "beanie", "beret", "glove", "sunglass",
                "necklace", "earring", "bracelet", "watch", "jewel", "wallet",
                "sock", "tights"]) {
            return .accessory
        }
        return .other
    }
}

/// The two ownership states a wardrobe item can be in. String-backed
/// so it round-trips the `products.status` column directly.
enum WardrobeStatus: String, Codable, Sendable, CaseIterable {
    case owned
    case wishlist
}

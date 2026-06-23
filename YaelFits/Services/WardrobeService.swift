import Foundation

/// Data access for the wardrobe (product closet).
///
/// The `public.products` table is the canonical store of a user's
/// owned + wishlist items. This service reads/writes the wardrobe
/// columns added in Phase 0. It supersedes `ProductLibraryService`
/// for the wardrobe feature; legacy product-library / outfit-tagging
/// paths still use `ProductLibraryService` until they're migrated.
enum WardrobeService {

    // MARK: - Read

    /// All wardrobe items owned by `userId`, newest first.
    static func fetchCloset(userId: UUID) async throws -> [WardrobeItem] {
        try await supabase
            .from("products")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Fuzzy "already in your closet?" matches for a candidate item
    /// name, used by the tagging dedup hook. Backed by the
    /// `find_similar_products` SQL function (pg_trgm similarity on
    /// `norm_name`), which is RLS-scoped to the caller.
    ///
    /// Returns `[]` (rather than throwing) is *not* done here — the
    /// caller decides how to treat failure; a thrown error simply
    /// means "couldn't check", and the dedup strip should degrade to
    /// the normal new-item flow.
    static func findSimilar(query: String, limit: Int = 6) async throws -> [ClosetMatch] {
        struct Params: Encodable {
            let p_query: String
            let p_limit: Int
        }
        return try await supabase
            .rpc("find_similar_products", params: Params(p_query: query, p_limit: limit))
            .execute()
            .value
    }

    // MARK: - Write

    /// Create a new wardrobe item (owned by default).
    @discardableResult
    static func createItem(
        userId: UUID,
        name: String,
        imageURL: String,
        category: String = "unknown",
        brand: String? = nil,
        color: String? = nil,
        price: String? = nil,
        sourceURL: String? = nil,
        status: WardrobeStatus = .owned,
        tags: [String] = []
    ) async throws -> WardrobeItem {
        struct Insert: Encodable {
            let user_id: String
            let name: String
            let image_url: String
            let category: String
            let brand: String?
            let color: String?
            let price: String?
            let source_url: String?
            let status: String
            let tags: [String]
        }
        let inserted: [WardrobeItem] = try await supabase
            .from("products")
            .insert(Insert(
                user_id: userId.uuidString,
                name: name,
                image_url: imageURL,
                category: category,
                brand: brand,
                color: color,
                price: price,
                source_url: sourceURL,
                status: status.rawValue,
                tags: tags
            ))
            .select()
            .execute()
            .value
        guard let item = inserted.first else { throw WardrobeError.insertFailed }
        return item
    }

    /// Update mutable labels / status on an item. Only non-nil
    /// arguments are sent — the synthesized `Encodable` uses
    /// `encodeIfPresent` for optionals, so a nil field is omitted
    /// from the PATCH rather than nulling the column.
    static func updateItem(
        id: UUID,
        name: String? = nil,
        category: String? = nil,
        brand: String? = nil,
        color: String? = nil,
        price: String? = nil,
        sourceURL: String? = nil,
        status: WardrobeStatus? = nil
    ) async throws {
        struct Update: Encodable {
            let name: String?
            let category: String?
            let brand: String?
            let color: String?
            let price: String?
            let source_url: String?
            let status: String?
        }
        try await supabase
            .from("products")
            .update(Update(
                name: name,
                category: category,
                brand: brand,
                color: color,
                price: price,
                source_url: sourceURL,
                status: status?.rawValue
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }
}

enum WardrobeError: LocalizedError {
    case insertFailed

    var errorDescription: String? {
        switch self {
        case .insertFailed: return "Failed to save wardrobe item."
        }
    }
}

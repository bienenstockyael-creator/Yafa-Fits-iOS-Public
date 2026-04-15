import Foundation

struct ProductLibraryService {

    // MARK: - Product CRUD

    static func fetchProducts(userId: UUID) async throws -> [ProductLibraryItem] {
        try await supabase
            .from("products")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    static func createProduct(
        userId: UUID,
        name: String,
        imageURL: String,
        tags: [String]
    ) async throws -> ProductLibraryItem {
        struct Insert: Encodable {
            let userId: String
            let name: String
            let imageURL: String
            let tags: [String]
            enum CodingKeys: String, CodingKey {
                case name, tags
                case userId = "user_id"
                case imageURL = "image_url"
            }
        }
        let inserted: [ProductLibraryItem] = try await supabase
            .from("products")
            .insert(Insert(userId: userId.uuidString, name: name, imageURL: imageURL, tags: tags))
            .select()
            .execute()
            .value
        guard let item = inserted.first else {
            throw ProductLibraryError.insertFailed
        }
        return item
    }

    // MARK: - Tags

    /// All unique tags the user has used across their product library.
    static func fetchAllTags(userId: UUID) async throws -> [String] {
        let products = try await fetchProducts(userId: userId)
        let all = products.flatMap { $0.tags }
        // Deduplicate preserving first-seen order
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    // MARK: - Outfit tagging

    static func tagOutfit(outfitId: String, productId: UUID) async throws {
        struct Params: Encodable {
            let p_outfit_id: String
            let p_product_id: String
        }
        try await supabase
            .rpc("tag_outfit_product", params: Params(
                p_outfit_id: outfitId,
                p_product_id: productId.uuidString
            ))
            .execute()
    }

    static func removeProductTag(outfitId: String, productId: UUID) async throws {
        try await supabase
            .from("outfit_products")
            .delete()
            .eq("outfit_id", value: outfitId)
            .eq("product_id", value: productId.uuidString)
            .execute()
    }

    static func updateOutfitTags(outfitId: String, tags: [String]) async throws {
        struct Update: Encodable { let tags: [String] }
        try await supabase
            .from("outfits")
            .update(Update(tags: tags))
            .eq("id", value: outfitId)
            .execute()
    }

    /// Removes a product from an outfit. Handles both library products (by product_id)
    /// and legacy products (by name).
    static func removeProductFromOutfit(outfitId: String, product: Product) async throws {
        if let productId = product.productId {
            try await removeProductTag(outfitId: outfitId, productId: productId)
        } else {
            try await supabase
                .from("outfit_products")
                .delete()
                .eq("outfit_id", value: outfitId)
                .eq("name", value: product.name)
                .execute()
        }
    }

    static func setShopURL(_ url: String?, outfitId: String, productId: UUID) async throws {
        struct Update: Encodable {
            let shopLink: String?
            enum CodingKeys: String, CodingKey { case shopLink = "shop_link" }
        }
        try await supabase
            .from("outfit_products")
            .update(Update(shopLink: url))
            .eq("outfit_id", value: outfitId)
            .eq("product_id", value: productId.uuidString)
            .execute()
    }

    /// Fetch full product library items tagged on a specific outfit.
    static func fetchTaggedProducts(outfitId: String) async throws -> [ProductLibraryItem] {
        struct Row: Decodable {
            let products: ProductLibraryItem?
        }
        // products!inner(*) only returns rows where product_id is non-null (inner join)
        let rows: [Row] = try await supabase
            .from("outfit_products")
            .select("products!inner(*)")
            .eq("outfit_id", value: outfitId)
            .execute()
            .value
        return rows.compactMap(\.products)
    }
}

enum ProductLibraryError: LocalizedError {
    case insertFailed

    var errorDescription: String? {
        switch self {
        case .insertFailed: return "Failed to save product."
        }
    }
}

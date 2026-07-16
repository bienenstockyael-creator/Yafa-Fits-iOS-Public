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

    /// Swap a library product's image in place (background thumbnail
    /// polish after a link-import save). Updates BOTH the canonical
    /// products row and the inline copies on outfit_products — the
    /// join table carries its own image column, so without the second
    /// update a reloaded fit resurrects the old image.
    static func updateProductImage(productId: UUID, imageURL: String) async throws {
        struct Update: Encodable {
            let imageURL: String
            enum CodingKeys: String, CodingKey { case imageURL = "image_url" }
        }
        try await supabase
            .from("products")
            .update(Update(imageURL: imageURL))
            .eq("id", value: productId.uuidString)
            .execute()

        struct JoinUpdate: Encodable { let image: String }
        try await supabase
            .from("outfit_products")
            .update(JoinUpdate(image: imageURL))
            .eq("product_id", value: productId.uuidString)
            .execute()
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

    /// outfit_products has NO client UPDATE grant — updates silently
    /// match zero rows (verified against prod 2026-07-16). Writes go
    /// through the proven verbs instead: read the row, delete it,
    /// re-insert with the new link.
    static func setShopURL(_ url: String?, outfitId: String, productId: UUID) async throws {
        try await rebuildRowWithShopLink(url, outfitId: outfitId, productId: productId, name: nil)
    }

    private struct JoinRowSnapshot: Decodable {
        let name: String?
        let price: String?
        let image: String?
        let productId: UUID?
        enum CodingKeys: String, CodingKey {
            case name, price, image
            case productId = "product_id"
        }
    }

    private static func rebuildRowWithShopLink(
        _ url: String?, outfitId: String, productId: UUID?, name: String?
    ) async throws {
        var query = supabase
            .from("outfit_products")
            .select("name, price, image, product_id")
            .eq("outfit_id", value: outfitId)
        if let productId {
            query = query.eq("product_id", value: productId.uuidString)
        } else if let name {
            query = query.eq("name", value: name)
        } else {
            return
        }
        let rows: [JoinRowSnapshot] = try await query.execute().value
        guard let row = rows.first else { return }

        var deletion = supabase.from("outfit_products").delete().eq("outfit_id", value: outfitId)
        if let productId {
            deletion = deletion.eq("product_id", value: productId.uuidString)
        } else if let name {
            deletion = deletion.eq("name", value: name)
        }
        try await deletion.execute()

        struct FullRow: Encodable {
            let outfitId: String
            let name: String
            let price: String?
            let image: String
            let shopLink: String?
            let productId: String?
            enum CodingKeys: String, CodingKey {
                case name, price, image
                case outfitId = "outfit_id"
                case shopLink = "shop_link"
                case productId = "product_id"
            }
        }
        try await supabase
            .from("outfit_products")
            .insert(FullRow(
                outfitId: outfitId,
                name: row.name ?? name ?? "",
                price: row.price,
                image: row.image ?? "",
                shopLink: url,
                productId: (row.productId ?? productId)?.uuidString
            ))
            .execute()
    }

    /// Persists a product's shop URL for live-save flows (e.g. typing in
    /// PublishSheet). Routes by `product_id` when available, falls back to
    /// `name` for legacy/manually-added products. Safe to call even if the
    /// `outfit_products` row hasn't been inserted yet — the UPDATE simply
    /// matches zero rows in that case, and the URL is picked up later when
    /// the publish flow creates the row.
    static func setShopURL(_ url: String?, outfitId: String, product: Product) async throws {
        if let productId = product.productId {
            try await rebuildRowWithShopLink(url, outfitId: outfitId, productId: productId, name: nil)
        } else {
            try await rebuildRowWithShopLink(url, outfitId: outfitId, productId: nil, name: product.name)
        }
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

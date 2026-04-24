import Foundation

// Encodable product row for inserting into outfit_products
struct ProductInput: Encodable {
    let outfitId: String
    let name: String
    let price: String?
    let image: String
    let shopLink: String?

    enum CodingKeys: String, CodingKey {
        case name, price, image
        case outfitId = "outfit_id"
        case shopLink = "shop_link"
    }
}

struct OutfitService {

    private struct OutfitUpsert: Encodable {
        let id: String
        let userId: String
        let name: String
        let date: String
        let frameCount: Int
        let folder: String
        let prefix: String
        let frameExt: String?
        let remoteBaseURL: String?
        let scale: Double?
        let isRotationReversed: Bool
        let tags: [String]?
        let activity: String?
        let weatherTempF: Int?
        let weatherTempC: Int?
        let weatherCondition: String?
        let isPublic: Bool
        let publishedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, date, folder, prefix, scale, tags, activity
            case userId = "user_id"
            case frameCount = "frame_count"
            case frameExt = "frame_ext"
            case remoteBaseURL = "remote_base_url"
            case isRotationReversed = "is_rotation_reversed"
            case weatherTempF = "weather_temp_f"
            case weatherTempC = "weather_temp_c"
            case weatherCondition = "weather_condition"
            case isPublic = "is_public"
            case publishedAt = "published_at"
        }
    }

    static func isPublished(outfitId: String) async -> Bool {
        struct Row: Decodable {
            let isPublic: Bool?
            enum CodingKeys: String, CodingKey { case isPublic = "is_public" }
        }
        guard let row: Row = try? await supabase
            .from("outfits")
            .select("is_public")
            .eq("id", value: outfitId)
            .single()
            .execute()
            .value
        else { return false }
        return row.isPublic ?? false
    }

    static func deleteOutfit(_ outfitId: String) async throws {
        try await supabase
            .from("outfits")
            .delete()
            .eq("id", value: outfitId)
            .execute()
    }

    static func updateOutfitDate(outfitId: String, date: String) async throws {
        struct DateUpdate: Encodable { let date: String }
        try await supabase
            .from("outfits")
            .update(DateUpdate(date: date))
            .eq("id", value: outfitId)
            .execute()
    }

    static func setPublished(_ isPublic: Bool, outfitId: String) async throws {
        struct PublishUpdate: Encodable {
            let is_public: Bool
            let published_at: String?
        }
        let now = ISO8601DateFormatter().string(from: Date())
        try await supabase
            .from("outfits")
            .update(PublishUpdate(
                is_public: isPublic,
                published_at: isPublic ? now : nil
            ))
            .eq("id", value: outfitId)
            .execute()
    }

    /// Publishes an outfit with caption + products. Replaces all outfit_products.
    static func publishOutfit(
        outfitId: String,
        caption: String?,
        products: [ProductInput],
        outfit: Outfit,
        userId: UUID
    ) async throws {
        try await saveArchiveOutfit(outfit, userId: userId, isPublic: true)

        // Update caption — graceful skip if schema cache is stale
        let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCaption.isEmpty {
            struct CaptionUpdate: Encodable { let caption: String }
            _ = try? await supabase
                .from("outfits")
                .update(CaptionUpdate(caption: trimmedCaption))
                .eq("id", value: outfitId)
                .execute()
        }

        try await supabase
            .from("outfit_products")
            .delete()
            .eq("outfit_id", value: outfitId)
            .execute()

        if !products.isEmpty {
            // Insert core fields first (always in schema)
            struct ProductInsertCore: Encodable {
                let outfitId: String
                let name: String
                let price: String?
                let image: String
                enum CodingKeys: String, CodingKey {
                    case name, price, image
                    case outfitId = "outfit_id"
                }
            }
            let coreInserts = products.map {
                ProductInsertCore(outfitId: $0.outfitId, name: $0.name, price: $0.price, image: $0.image)
            }
            try await supabase
                .from("outfit_products")
                .insert(coreInserts)
                .execute()

            // Update shop_link per product using name as key
            // (ProductInput doesn't carry product_id; name is unique per outfit insert)
            for product in products {
                guard let shopLink = product.shopLink, !shopLink.isEmpty else { continue }
                struct ShopLinkUpdate: Encodable {
                    let shopLink: String
                    enum CodingKeys: String, CodingKey { case shopLink = "shop_link" }
                }
                _ = try? await supabase
                    .from("outfit_products")
                    .update(ShopLinkUpdate(shopLink: shopLink))
                    .eq("outfit_id", value: outfitId)
                    .eq("name", value: product.name)
                    .execute()
            }
        }
    }

    static func saveArchiveOutfit(_ outfit: Outfit, userId: UUID, isPublic: Bool = false) async throws {
        try await supabase
            .from("outfits")
            .upsert(OutfitUpsert(
                id: outfit.id,
                userId: userId.uuidString,
                name: outfit.name,
                date: outfit.date,
                frameCount: outfit.frameCount,
                folder: outfit.folder,
                prefix: outfit.prefix,
                frameExt: outfit.frameExt,
                remoteBaseURL: outfit.remoteBaseURL,
                scale: outfit.scale,
                isRotationReversed: outfit.rotationReversed,
                tags: outfit.tags,
                activity: outfit.activity,
                weatherTempF: outfit.weather?.tempF,
                weatherTempC: outfit.weather?.tempC,
                weatherCondition: outfit.weather?.condition,
                isPublic: isPublic,
                publishedAt: isPublic ? ISO8601DateFormatter().string(from: Date()) : nil
            ))
            .execute()
    }
}

import Foundation

// Encodable product row for inserting into outfit_products
struct ProductInput: Encodable {
    let outfitId: String
    let name: String
    let price: String?
    let image: String
    let shopLink: String?
    /// Link back to the canonical products row. WITHOUT this the
    /// publish rewrite orphans the row — the background thumbnail
    /// polish (which matches by product_id) can never reach it and
    /// the feed freezes whatever image existed at publish time.
    let productId: UUID?

    enum CodingKeys: String, CodingKey {
        case name, price, image
        case outfitId = "outfit_id"
        case shopLink = "shop_link"
        case productId = "product_id"
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
        let location: String?
        let isPublic: Bool
        let publishedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, date, folder, prefix, scale, tags, activity, location
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

    static func updateOutfitLocation(outfitId: String, location: String?) async throws {
        struct LocationUpdate: Encodable { let location: String? }
        try await supabase
            .from("outfits")
            .update(LocationUpdate(location: location))
            .eq("id", value: outfitId)
            .execute()
    }

    static func updateOutfitDiaryNote(
        outfitId: String,
        note: String?,
        style: String?,
        shared: Bool,
        x: Double?,
        y: Double?,
        scale: Double?,
        rotation: Double?,
        colorIndex: Int?
    ) async throws {
        struct NoteUpdate: Encodable {
            let diary_note: String?
            let note_style: String?
            let note_shared: Bool
            let note_x: Double?
            let note_y: Double?
            let note_scale: Double?
            let note_rotation: Double?
            let note_color: Int?
        }
        do {
            try await supabase
                .from("outfits")
                .update(NoteUpdate(
                    diary_note: note, note_style: style, note_shared: shared,
                    note_x: x, note_y: y, note_scale: scale, note_rotation: rotation,
                    note_color: colorIndex
                ))
                .eq("id", value: outfitId)
                .execute()
        } catch {
            // If the position columns don't exist yet (migration pending),
            // PostgREST rejects the WHOLE update — which used to mean the
            // note text never reached the server and any refresh wiped it.
            // Fall back to the base columns so the note itself persists.
            struct BaseNoteUpdate: Encodable {
                let diary_note: String?
                let note_style: String?
                let note_shared: Bool
            }
            try await supabase
                .from("outfits")
                .update(BaseNoteUpdate(diary_note: note, note_style: style, note_shared: shared))
                .eq("id", value: outfitId)
                .execute()
        }
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
            // Resolve canonical values FIRST, then insert rows that
            // are BORN COMPLETE — image (possibly polished since the
            // sheet opened), shop link (sheet value, else the
            // product's durable source_url), and product_id all in the
            // insert itself. The previous shape (minimal insert +
            // follow-up UPDATEs) depended on updates that can silently
            // match zero rows — which ate shop links (feed fell back
            // to Google Lens), dropped product_id (the thumbnail
            // polish could never reach published rows), and let raw
            // images resurrect after publish.
            struct CanonicalRow: Decodable {
                let id: UUID
                let imageUrl: String?
                let sourceUrl: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case imageUrl = "image_url"
                    case sourceUrl = "source_url"
                }
            }
            var canonicalById: [UUID: CanonicalRow] = [:]
            let productIds = products.compactMap(\.productId)
            if !productIds.isEmpty,
               let rows: [CanonicalRow] = try? await supabase
                   .from("products")
                   .select("id, image_url, source_url")
                   .in("id", values: productIds.map(\.uuidString))
                   .execute()
                   .value {
                canonicalById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            }

            struct FullInsert: Encodable {
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
            let fullInserts = products.map { p -> FullInsert in
                let canon = p.productId.flatMap { canonicalById[$0] }
                let image: String = {
                    if let c = canon?.imageUrl, !c.isEmpty { return c }
                    return p.image
                }()
                let link: String? = {
                    if let l = p.shopLink, !l.isEmpty { return l }
                    if let src = canon?.sourceUrl, !src.isEmpty { return src }
                    return nil
                }()
                return FullInsert(
                    outfitId: p.outfitId,
                    name: p.name,
                    price: p.price,
                    image: image,
                    shopLink: link,
                    productId: p.productId?.uuidString
                )
            }

            do {
                try await supabase
                    .from("outfit_products")
                    .insert(fullInserts)
                    .execute()
            } catch {
                // Schema-cache fallback (the historical reason inserts
                // were minimal): core columns only, then best-effort
                // enrichment updates.
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
                let coreInserts = fullInserts.map {
                    ProductInsertCore(outfitId: $0.outfitId, name: $0.name, price: $0.price, image: $0.image)
                }
                try await supabase
                    .from("outfit_products")
                    .insert(coreInserts)
                    .execute()
                for row in fullInserts {
                    struct Enrich: Encodable {
                        let shopLink: String?
                        let productId: String?
                        enum CodingKeys: String, CodingKey {
                            case shopLink = "shop_link"
                            case productId = "product_id"
                        }
                    }
                    guard row.shopLink != nil || row.productId != nil else { continue }
                    _ = try? await supabase
                        .from("outfit_products")
                        .update(Enrich(shopLink: row.shopLink, productId: row.productId))
                        .eq("outfit_id", value: outfitId)
                        .eq("name", value: row.name)
                        .execute()
                }
            }
        }
    }

    /// Short share slug for yafafits.com/fit/<slug> — minted on first
    /// share, stable forever after. Unambiguous alphabet (no 0/O/1/I/L),
    /// unique-collision retried. Returns nil when the slug column
    /// doesn't exist yet or every attempt fails — callers fall back to
    /// the raw outfit id, which the web page also accepts.
    static func ensureShareSlug(outfitId: String) async -> String? {
        struct Row: Decodable { let slug: String? }
        guard let rows: [Row] = try? await supabase
            .from("outfits")
            .select("slug")
            .eq("id", value: outfitId)
            .limit(1)
            .execute()
            .value
        else { return nil }
        if let existing = rows.first?.slug, !existing.isEmpty { return existing }

        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        for _ in 0..<3 {
            let candidate = String((0..<5).map { _ in alphabet.randomElement()! })
            struct Update: Encodable { let slug: String }
            do {
                struct Updated: Decodable { let slug: String? }
                let updated: [Updated] = try await supabase
                    .from("outfits")
                    .update(Update(slug: candidate))
                    .eq("id", value: outfitId)
                    .is("slug", value: nil)
                    .select("slug")
                    .execute()
                    .value
                if updated.first?.slug == candidate { return candidate }
                // Zero rows: someone else minted concurrently — read it.
                if let rows2: [Row] = try? await supabase
                    .from("outfits").select("slug").eq("id", value: outfitId).limit(1).execute().value,
                   let won = rows2.first?.slug, !won.isEmpty {
                    return won
                }
            } catch {
                continue // unique collision or transient — retry
            }
        }
        return nil
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
                location: outfit.location,
                isPublic: isPublic,
                publishedAt: isPublic ? ISO8601DateFormatter().string(from: Date()) : nil
            ))
            .execute()
    }
}

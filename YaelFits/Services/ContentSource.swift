import Foundation
import OSLog

/// Joined product detail when product_id is set.
private struct SupabaseProductDetail: Decodable {
    let id: UUID
    let name: String
    let imageURL: String
    let tags: [String]?
    let sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tags
        case imageURL = "image_url"
        case sourceURL = "source_url"
    }
}

/// Product row from the Supabase `outfit_products` table.
/// Handles both legacy rows (name/image columns) and new rows (product_id → products join).
private struct SupabaseProductRow: Decodable {
    let name: String?
    let price: String?
    let image: String?
    let shopLink: String?
    let productId: UUID?
    let products: SupabaseProductDetail?   // joined when product_id is set

    enum CodingKeys: String, CodingKey {
        case name, price, image, products
        case shopLink = "shop_link"
        case productId = "product_id"
    }

    var effectiveName: String  { products?.name  ?? name  ?? "" }
    var effectiveImage: String { products?.imageURL ?? image ?? "" }
    /// Inline link, else the product's durable source_url — the
    /// inline copy is lost whenever a row is rebuilt without it.
    var effectiveShopLink: String? {
        if let l = shopLink, !l.isEmpty { return l }
        if let s = products?.sourceURL, !s.isEmpty { return s }
        return nil
    }
    var effectiveTags: [String]? { products?.tags }
    var effectiveId: UUID? { products?.id ?? productId }

    func toProduct() -> Product? {
        let n = effectiveName
        guard !n.isEmpty else { return nil }
        return Product(
            name: n,
            price: price,
            image: effectiveImage,
            shopLink: effectiveShopLink,
            productId: effectiveId,
            tags: effectiveTags
        )
    }
}

/// Row shape returned by the Supabase `outfits` table with joined products.
private struct SupabaseOutfitRow: Decodable {
    let id: String
    let userId: String
    let name: String
    let date: String          // yyyy-MM-dd
    let frameCount: Int
    let folder: String
    let prefix: String
    let frameExt: String?
    let remoteBaseURL: String?
    let scale: Double?
    let isRotationReversed: Bool?
    let tags: [String]?
    let activity: String?
    let caption: String?
    let weatherTempF: Int?
    let weatherTempC: Int?
    let weatherCondition: String?
    let location: String?
    let isPublic: Bool?
    // Diary note — these were MISSING from this DTO, so every server fetch
    // returned note-less outfits and refreshOutfits() wiped local notes.
    let diaryNote: String?
    let noteStyle: String?
    let noteShared: Bool?
    let noteX: Double?
    let noteY: Double?
    let noteScale: Double?
    let noteRotation: Double?
    let noteColor: Int?
    let outfitProducts: [SupabaseProductRow]?

    enum CodingKeys: String, CodingKey {
        case id, name, date, folder, prefix, tags, activity, scale, caption, location
        case userId = "user_id"
        case frameCount = "frame_count"
        case frameExt = "frame_ext"
        case remoteBaseURL = "remote_base_url"
        case isRotationReversed = "is_rotation_reversed"
        case weatherTempF = "weather_temp_f"
        case weatherTempC = "weather_temp_c"
        case weatherCondition = "weather_condition"
        case isPublic = "is_public"
        case diaryNote = "diary_note"
        case noteStyle = "note_style"
        case noteShared = "note_shared"
        case noteX = "note_x"
        case noteY = "note_y"
        case noteScale = "note_scale"
        case noteRotation = "note_rotation"
        case noteColor = "note_color"
        case outfitProducts = "outfit_products"
    }

    func toOutfit() -> Outfit {
        var weather: Weather?
        if let f = weatherTempF, let c = weatherTempC {
            weather = Weather(tempF: f, tempC: c, condition: weatherCondition ?? "")
        }
        let products: [Product]? = outfitProducts?.compactMap { $0.toProduct() }
        return Outfit(
            id: id,
            name: name,
            date: date,
            frameCount: frameCount,
            folder: folder,
            prefix: prefix,
            frameExt: frameExt,
            remoteBaseURL: remoteBaseURL,
            scale: scale,
            isRotationReversed: isRotationReversed,
            tags: tags,
            activity: activity,
            weather: weather,
            products: products,
            caption: caption,
            location: location,
            isPublic: isPublic,
            diaryNote: diaryNote,
            noteStyle: noteStyle,
            noteShared: noteShared,
            noteX: noteX,
            noteY: noteY,
            noteScale: noteScale,
            noteRotation: noteRotation,
            noteColorIndex: noteColor
        )
    }
}

/// Select string that joins outfit_products + nested products library item.
private let outfitSelectWithProducts = "*, caption, remote_base_url, outfit_products(name, price, image, shop_link, product_id, products(id, name, image_url, tags, source_url))"

struct ContentSource {

    // MARK: - Bundled data (instant, no network)

    static func getBundledOutfits() -> [Outfit] {
        guard let url = Bundle.main.url(forResource: "outfits", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let outfitData = try? JSONDecoder().decode(OutfitData.self, from: data) else {
            return []
        }
        return outfitData.outfits.filter { outfit in
            !AppConfig.excludedOutfitIDs.contains(outfit.id)
                && !AppConfig.excludedOutfitNumbers.contains(outfit.outfitNumber ?? -1)
        }
    }

    static func getBundledFeed() -> [FeedPost] {
        guard let url = Bundle.main.url(forResource: "public-feed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let feedData = try? JSONDecoder().decode(FeedData.self, from: data) else {
            return []
        }
        return feedData.posts.filter { !AppConfig.excludedOutfitIDs.contains($0.outfitId) }
    }

    // MARK: - Supabase data (network)

    static func getUserOutfits(userId: UUID) async -> [Outfit] {
        #if DEBUG
        print("[DIAG] getUserOutfits start uid=\(userId.uuidString.prefix(8))")
        #endif
        // Primary path: single query with the outfit_products join.
        // If PostgREST's relationship inference is happy, this returns outfits + products.
        let joined: [SupabaseOutfitRow]?
        do {
            joined = try await supabase
                .from("outfits")
                .select(outfitSelectWithProducts)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            let total = joined?.count ?? 0
            let withProducts = joined?.filter { !($0.outfitProducts ?? []).isEmpty }.count ?? 0
            #if DEBUG
            print("[DIAG] joined query: \(total) outfits, \(withProducts) with products")
            #endif
        } catch {
            joined = nil
            #if DEBUG
            print("[DIAG] joined query FAILED: \(error.localizedDescription)")
            #endif
        }
        if let joined, joined.contains(where: { !($0.outfitProducts ?? []).isEmpty }) {
            #if DEBUG
            print("[DIAG] using join path, returning \(joined.count) outfits")
            #endif
            return joined.map { $0.toOutfit() }
        }

        #if DEBUG
        print("[DIAG] taking fallback two-query path")
        #endif
        // Fallback: fetch outfits and outfit_products separately, then stitch.
        // This is robust against PostgREST schema-cache staleness, where the join
        // can silently return rows without their nested products.
        let outfitRows: [SupabaseOutfitRow]
        do {
            outfitRows = try await supabase
                .from("outfits")
                .select("*, caption, remote_base_url")
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            #if DEBUG
            print("[DIAG] fallback outfits query: \(outfitRows.count) rows")
            #endif
        } catch {
            #if DEBUG
            print("[DIAG] fallback outfits query FAILED: \(error.localizedDescription)")
            #endif
            return (joined ?? []).map { $0.toOutfit() }
        }

        let outfitIds = outfitRows.map(\.id)
        guard !outfitIds.isEmpty else {
            #if DEBUG
            print("[DIAG] no outfit IDs, returning empty-products outfits")
            #endif
            return outfitRows.map { $0.toOutfit() }
        }

        struct StandaloneProductRow: Decodable {
            let outfitId: String
            let name: String?
            let price: String?
            let image: String?
            let shopLink: String?
            let productId: UUID?
            /// Canonical products row — its image_url wins over the
            /// inline copy (which freezes at tag/publish time; the
            /// background thumbnail polish updates the canonical row).
            let products: SupabaseProductDetail?
            enum CodingKeys: String, CodingKey {
                case name, price, image, products
                case outfitId = "outfit_id"
                case shopLink = "shop_link"
                case productId = "product_id"
            }
        }
        let productRows: [StandaloneProductRow]
        do {
            productRows = try await supabase
                .from("outfit_products")
                .select("outfit_id, name, price, image, shop_link, product_id, products(id, name, image_url, tags, source_url)")
                .in("outfit_id", values: outfitIds)
                .execute()
                .value
            #if DEBUG
            print("[DIAG] outfit_products query: \(productRows.count) rows for \(outfitIds.count) outfits")
            #endif
        } catch {
            #if DEBUG
            print("[DIAG] outfit_products query FAILED: \(error.localizedDescription)")
            #endif
            productRows = []
        }

        let productsByOutfit: [String: [Product]] = Dictionary(grouping: productRows, by: \.outfitId)
            .mapValues { rows in
                rows.compactMap { row -> Product? in
                    let n = row.products?.name ?? row.name ?? ""
                    guard !n.isEmpty else { return nil }
                    let link: String? = {
                        if let l = row.shopLink, !l.isEmpty { return l }
                        if let s = row.products?.sourceURL, !s.isEmpty { return s }
                        return nil
                    }()
                    return Product(
                        name: n,
                        price: row.price,
                        image: row.products?.imageURL ?? row.image ?? "",
                        shopLink: link,
                        productId: row.products?.id ?? row.productId,
                        tags: row.products?.tags
                    )
                }
            }
        let outfitsWithProducts = productsByOutfit.values.filter { !$0.isEmpty }.count
        #if DEBUG
        print("[DIAG] stitched: \(outfitsWithProducts)/\(outfitRows.count) outfits got products")
        #endif

        return outfitRows.map { row in
            var outfit = row.toOutfit()
            if let products = productsByOutfit[row.id], !products.isEmpty {
                outfit.products = products
            }
            return outfit
        }
    }

    static func getPublicOutfits() async -> [Outfit] {
        if let rows: [SupabaseOutfitRow] = try? await supabase
            .from("outfits")
            .select(outfitSelectWithProducts)
            .eq("is_public", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value {
            return rows
                .filter { remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId) }
                .map { $0.toOutfit() }
        }
        let rows: [SupabaseOutfitRow] = (try? await supabase
            .from("outfits")
            .select("*")
            .eq("is_public", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        return rows
            .filter { remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId) }
            .map { $0.toOutfit() }
    }

    static func getAllOutfits(userId: UUID) async -> [Outfit] {
        let remote = await getUserOutfits(userId: userId)
        let local = getLocalOutfits(userId: userId)
        let remoteIds = Set(remote.map(\.id))
        let uniqueLocal = local.filter { !remoteIds.contains($0.id) }

        // Bundled outfits are Yael's personal archive — only included for her account
        let isOwnerAccount = userId.uuidString.lowercased() == AppConfig.archiveOwnerUserId
        if isOwnerAccount {
            let bundled = getBundledOutfits()
            let allIds = remoteIds.union(local.map(\.id))
            let uniqueBundled = bundled.filter { !allIds.contains($0.id) }
            return remote + uniqueLocal + uniqueBundled
        }
        return remote + uniqueLocal
    }

    static func getLocalOutfits(userId: UUID) -> [Outfit] {
        LocalOutfitStore.shared.loadOutfits(userId: userId)
    }

    /// Fetch public outfits for a specific user.
    static func getPublicOutfits(forUser userId: UUID) async -> [Outfit] {
        // Try full query with products join
        if let rows: [SupabaseOutfitRow] = try? await supabase
            .from("outfits")
            .select(outfitSelectWithProducts)
            .eq("user_id", value: userId.uuidString)
            .eq("is_public", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value {
            return rows
                .filter { remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId) }
                .map { $0.toOutfit() }
        }
        // Fallback: all columns, no joins — survives stale schema cache
        let rows: [SupabaseOutfitRow] = (try? await supabase
            .from("outfits")
            .select("*")
            .eq("user_id", value: userId.uuidString)
            .eq("is_public", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        return rows
            .filter { remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId) }
            .map { $0.toOutfit() }
    }

    /// Fetch multiple public outfits by id, returning each with its author
    /// user_id. Used by the Saved sheet to render feed-style cards that
    /// route correctly to the original author's profile on tap. Preserves
    /// the input ordering of `ids` so the saved grid shows newest-saved
    /// first when the caller passes them in that order.
    static func getPublicOutfitsByIds(_ ids: [String]) async -> [(outfit: Outfit, authorId: UUID)] {
        guard !ids.isEmpty else { return [] }
        let rows: [SupabaseOutfitRow] = (try? await supabase
            .from("outfits")
            .select(outfitSelectWithProducts)
            .in("id", values: ids)
            .eq("is_public", value: true)
            .execute()
            .value) ?? []
        let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, (Outfit, UUID))? in
            guard let authorId = UUID(uuidString: row.userId) else { return nil }
            return (row.id, (row.toOutfit(), authorId))
        })
        return ids.compactMap { byId[$0] }
    }

    /// Fetch feed from followed users' public outfits + their profile info.
    /// Fetch a single public outfit with its products — used for feed cards
    /// belonging to other users whose outfits aren't in the local store.
    static func getPublicOutfit(id: String) async -> Outfit? {
        // Try full query with products join
        if let rows: [SupabaseOutfitRow] = try? await supabase
            .from("outfits")
            .select(outfitSelectWithProducts)
            .eq("id", value: id)
            .eq("is_public", value: true)
            .limit(1)
            .execute()
            .value, let outfit = rows.first?.toOutfit() {
            return outfit
        }
        // Fallback: all columns, no joins — survives stale PostgREST schema cache
        if let rows: [SupabaseOutfitRow] = try? await supabase
            .from("outfits")
            .select("*")
            .eq("id", value: id)
            .eq("is_public", value: true)
            .limit(1)
            .execute()
            .value, let outfit = rows.first?.toOutfit() {
            return outfit
        }
        return nil
    }

    /// Whether a public outfit row is renderable on OTHER users'
    /// devices. Frames must be reachable remotely — except the archive
    /// owner's legacy outfits, whose frames ship on yafafits.com and
    /// predate `remote_base_url`. A public row failing this is the
    /// "empty feed card" bug: published while its frame upload
    /// silently failed, so every other device renders a blank card.
    static func remotelyRenderable(remoteBaseURL: String?, userId: String?) -> Bool {
        if let remote = remoteBaseURL, !remote.isEmpty { return true }
        return userId?.lowercased() == AppConfig.archiveOwnerUserId
    }

    static func getFollowedFeed(followingIds: Set<UUID>) async -> [FeedPost] {
        guard !followingIds.isEmpty else { return [] }
        let userIdStrings = followingIds.map(\.uuidString)
        do {
            struct FeedOutfitRow: Decodable {
                let id: String
                let userId: String
                let date: String
                let caption: String?
                let createdAt: String?
                let remoteBaseURL: String?
                enum CodingKeys: String, CodingKey {
                    case id, date, caption
                    case userId = "user_id"
                    case createdAt = "published_at"
                    case remoteBaseURL = "remote_base_url"
                }
            }
            let outfitRows: [FeedOutfitRow]
            if let withCaption: [FeedOutfitRow] = try? await supabase
                .from("outfits")
                .select("id, user_id, date, caption, published_at, remote_base_url")
                .eq("is_public", value: true)
                .in("user_id", values: userIdStrings)
                .not("published_at", operator: .is, value: "null")
                .order("published_at", ascending: false)
                .limit(50)
                .execute()
                .value {
                outfitRows = withCaption
            } else {
                outfitRows = try await supabase
                    .from("outfits")
                    .select("id, user_id, date, published_at, remote_base_url")
                    .eq("is_public", value: true)
                    .in("user_id", values: userIdStrings)
                    .not("published_at", operator: .is, value: "null")
                    .order("published_at", ascending: false)
                    .limit(50)
                    .execute()
                    .value
            }

            let renderableRows = outfitRows.filter {
                remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId)
            }
            guard !renderableRows.isEmpty else { return [] }

            let uniqueUserIds = Array(Set(renderableRows.map(\.userId)))
            let profiles: [Profile] = try await supabase
                .from("profiles")
                .select()
                .in("id", values: uniqueUserIds)
                .execute()
                .value
            let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString.lowercased(), $0) })

            return renderableRows.map { row in
                let profile = profileMap[row.userId.lowercased()]
                return FeedPost(
                    id: "feed-\(row.id)",
                    // Instagram-style: username is the primary identity
                    // shown on posts. Falls back to displayName if no
                    // username is set.
                    authorName: profile?.handle ?? "User",
                    outfitId: row.id,
                    caption: row.caption,
                    height: nil, size: nil,
                    profileImage: nil,
                    avatarUrl: profile?.avatarUrl,
                    authorId: UUID(uuidString: row.userId),
                    isAuthorPro: profile?.isPro,
                    createdAt: row.createdAt
                )
            }
        } catch {
            AppLogger.data.error("ContentSource query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Fallback: all public outfits (used when not following anyone yet).
    ///
    /// `featuredFirst` floats each featured account's latest post to the
    /// top — wanted ONLY on the Community feed (culture-setting surface);
    /// the main feed stays purely chronological since it's headed toward
    /// being the following-only feed.
    static func getPublicFeed(featuredFirst: Bool = false) async -> [FeedPost] {
        do {
            struct FeedOutfitRow: Decodable {
                let id: String
                let userId: String?
                let caption: String?
                let createdAt: String?
                let remoteBaseURL: String?
                enum CodingKeys: String, CodingKey {
                    case id, caption
                    case userId = "user_id"
                    case createdAt = "published_at"
                    case remoteBaseURL = "remote_base_url"
                }
            }
            let rows: [FeedOutfitRow]
            if let withCaption: [FeedOutfitRow] = try? await supabase
                .from("outfits")
                .select("id, user_id, caption, published_at, remote_base_url")
                .eq("is_public", value: true)
                .not("published_at", operator: .is, value: "null")
                .order("published_at", ascending: false)
                .limit(50)
                .execute()
                .value {
                rows = withCaption
            } else {
                rows = try await supabase
                    .from("outfits")
                    .select("id, user_id, published_at, remote_base_url")
                    .eq("is_public", value: true)
                    .not("published_at", operator: .is, value: "null")
                    .order("published_at", ascending: false)
                    .limit(50)
                    .execute()
                    .value
            }

            let renderable = rows.filter {
                remotelyRenderable(remoteBaseURL: $0.remoteBaseURL, userId: $0.userId)
            }

            let uniqueUserIds = Array(Set(renderable.compactMap(\.userId)))
            var profileMap: [String: Profile] = [:]
            if !uniqueUserIds.isEmpty {
                // Surface profile-fetch failures rather than silently
                // dropping avatars/names — `try?` here was masking
                // RLS/decoding/network issues that left every post
                // looking like an unknown author.
                do {
                    let profiles: [Profile] = try await supabase
                        .from("profiles").select()
                        .in("id", values: uniqueUserIds)
                        .execute().value
                    profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString.lowercased(), $0) })
                } catch {
                    AppLogger.data.error("getPublicFeed profiles fetch failed: \(error.localizedDescription)")
                }
            }

            let posts = renderable.map { row -> FeedPost in
                let profile = row.userId.flatMap { profileMap[$0.lowercased()] }
                return FeedPost(
                    id: "feed-\(row.id)",
                    authorName: profile?.handle ?? "Yael",
                    outfitId: row.id,
                    caption: row.caption,
                    height: nil, size: nil,
                    profileImage: nil,
                    avatarUrl: profile?.avatarUrl,
                    authorId: row.userId.flatMap { UUID(uuidString: $0) },
                    isAuthorPro: profile?.isPro,
                    isAuthorFeatured: profile?.isFeatured,
                    createdAt: row.createdAt
                )
            }

            guard featuredFirst else { return posts }

            // Featured rail: each featured account's MOST RECENT post floats
            // to the top (newest-first among them); everything else — incl.
            // featured users' older posts — stays chronological below. Sets
            // the feed's tone without freezing its freshness.
            var rail: [FeedPost] = []
            var railAuthors = Set<UUID>()
            var rest: [FeedPost] = []
            for post in posts {   // rows arrive newest-first
                if post.isAuthorFeatured == true,
                   let author = post.authorId,
                   !railAuthors.contains(author) {
                    rail.append(post)
                    railAuthors.insert(author)
                } else {
                    rest.append(post)
                }
            }
            return rail + rest
        } catch {
            AppLogger.data.error("ContentSource getPublicFeed failed: \(error.localizedDescription)")
            let publicOutfits = await getPublicOutfits()
            return publicOutfits.map { outfit in
                FeedPost(id: "feed-\(outfit.id)", authorName: "Yael",
                         outfitId: outfit.id, caption: outfit.caption,
                         height: nil, size: nil, profileImage: nil, avatarUrl: nil)
            }
        }
    }
}

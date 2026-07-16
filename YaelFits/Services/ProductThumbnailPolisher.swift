import UIKit

/// Finishes link-imported products AFTER save: the clean catalog
/// thumbnail (nano -> tight-crop, the save flow's pipeline) is
/// generated in the background and swapped into the product row, the
/// inline `outfit_products` copies, and the loaded outfits when
/// ready. Saving never waits on the generation.
///
/// Durability mirrors WishlistBackfillService: each polish is
/// remembered in UserDefaults and the row marked
/// `thumb_status = "generating"` BEFORE work starts, so a polish that
/// dies with the app (force-quit, crash) is healed on next launch —
/// re-generated from the raw upload the product saved with. A per-id
/// attempt cap stops eternal retries: after 3 failed sessions the row
/// is marked ready and simply keeps the raw shot.
@Observable
@MainActor
final class ProductThumbnailPolisher {
    static let shared = ProductThumbnailPolisher()

    /// Wired at app start; polishes outlive the Add Product sheet,
    /// so the store hookup cannot come from the (dismissed) view.
    @ObservationIgnored weak var store: OutfitStore?

    /// Products whose thumbnail is cooking right now — cells overlay
    /// the sparkle field while their id is in here.
    private(set) var polishingIds: Set<UUID> = []

    private var isHealing = false

    // MARK: Durable pending state (the wishlist backfill pattern)

    private static let pendingKey = "yafa.productPolish.pending"
    private static let attemptsKey = "yafa.productPolish.attempts"
    private static let maxAttempts = 3

    /// productId -> label used for the generation prompt.
    @ObservationIgnored private var pending: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }
    @ObservationIgnored private var attemptCounts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Self.attemptsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.attemptsKey) }
    }

    private func remember(_ id: UUID, label: String) {
        var p = pending
        p[id.uuidString] = label
        pending = p
    }
    private func forget(_ id: UUID) {
        var p = pending
        p.removeValue(forKey: id.uuidString)
        pending = p
        var a = attemptCounts
        a.removeValue(forKey: id.uuidString)
        attemptCounts = a
    }

    // MARK: Live polish (save-time)

    func polish(productId: UUID, outfitId: String, label: String, userId: UUID, raw: UIImage) {
        remember(productId, label: label)
        polishingIds.insert(productId)
        Task {
            defer { polishingIds.remove(productId) }
            // Durable marker FIRST — if the app dies mid-generation,
            // the heal pass finds the row still "generating".
            try? await WardrobeService.updateItem(id: productId, thumbStatus: "generating")
            do {
                try await generateAndApply(productId: productId, label: label, userId: userId, raw: raw)
                forget(productId)
            } catch {
                // Leave the pending record + "generating" status —
                // healed on next launch.
                #if DEBUG
                print("[Polish] failed for \(productId): \(error) — will heal next launch")
                #endif
            }
        }
    }

    // MARK: Heal pass (launch-time)

    /// Retries polishes that died with the app. Called once per
    /// session from the app root after sign-in.
    func healIfNeeded(userId: UUID) {
        guard !isHealing, !pending.isEmpty else { return }
        isHealing = true
        Task {
            defer { isHealing = false }
            for (idString, label) in pending {
                guard let id = UUID(uuidString: idString) else {
                    forget(UUID()) // unreachable id — drop the record
                    var p = pending; p.removeValue(forKey: idString); pending = p
                    continue
                }
                let tried = attemptCounts[idString] ?? 0
                guard tried < Self.maxAttempts else {
                    // Several sessions of failure — keep the raw shot,
                    // stop the sparkles and the retries.
                    try? await WardrobeService.updateItem(id: id, thumbStatus: "ready")
                    forget(id)
                    continue
                }
                var a = attemptCounts; a[idString] = tried + 1; attemptCounts = a

                // Row check: someone (or a prior success whose forget
                // was lost) may have finished it already.
                struct Row: Decodable {
                    let imageUrl: String?
                    let thumbStatus: String?
                    enum CodingKeys: String, CodingKey {
                        case imageUrl = "image_url"
                        case thumbStatus = "thumb_status"
                    }
                }
                let row: Row?
                do {
                    let rows: [Row] = try await supabase
                        .from("products")
                        .select("image_url, thumb_status")
                        .eq("id", value: id.uuidString)
                        .limit(1)
                        .execute()
                        .value
                    row = rows.first
                } catch {
                    continue // transient — retry next launch
                }
                guard let row, row.thumbStatus == "generating",
                      let rawURLString = row.imageUrl, let rawURL = URL(string: rawURLString) else {
                    forget(id)
                    continue
                }

                polishingIds.insert(id)
                defer { polishingIds.remove(id) }
                guard let (data, _) = try? await URLSession.shared.data(from: rawURL),
                      let raw = UIImage(data: data) else { continue }
                do {
                    try await generateAndApply(productId: id, label: label, userId: userId, raw: raw)
                    forget(id)
                } catch {
                    // Retry next launch (until the attempt cap).
                }
            }
        }
    }

    // MARK: Shared pipeline tail

    private func generateAndApply(productId: UUID, label: String, userId: UUID, raw: UIImage) async throws {
        let thumb = try await FalProductThumbnailService.shared.generateCatalogThumbnail(
            fromProduct: raw,
            label: label.isEmpty ? "item" : label
        )
        let url = try await ProductImageService.uploadThumbnail(
            thumb,
            userId: userId,
            productName: label.isEmpty ? "product" : label
        )
        // Canonical row + the inline copy on EVERY fit it's tagged on
        // (outfit_products carries its own image column).
        try await ProductLibraryService.updateProductImage(productId: productId, imageURL: url)
        try? await WardrobeService.updateItem(id: productId, thumbStatus: "ready")

        // VERIFY the join-table write actually landed. An UPDATE that
        // silently matches zero rows (RLS/schema drift) strands
        // published fits on the raw image forever — so re-read the
        // rows and REBUILD (delete + full re-insert) any that still
        // carry a stale image. Inserts and deletes are the proven
        // paths; nothing here depends on updates succeeding.
        struct JoinRow: Decodable {
            let outfitId: String
            let name: String?
            let price: String?
            let image: String?
            let shopLink: String?
            enum CodingKeys: String, CodingKey {
                case name, price, image
                case outfitId = "outfit_id"
                case shopLink = "shop_link"
            }
        }
        if let rows: [JoinRow] = try? await supabase
            .from("outfit_products")
            .select("outfit_id, name, price, image, shop_link")
            .eq("product_id", value: productId.uuidString)
            .execute()
            .value {
            for row in rows where row.image != url {
                #if DEBUG
                print("[Polish] stale row on \(row.outfitId) after update — rebuilding")
                #endif
                struct FullRow: Encodable {
                    let outfitId: String
                    let name: String
                    let price: String?
                    let image: String
                    let shopLink: String?
                    let productId: String
                    enum CodingKeys: String, CodingKey {
                        case name, price, image
                        case outfitId = "outfit_id"
                        case shopLink = "shop_link"
                        case productId = "product_id"
                    }
                }
                _ = try? await supabase
                    .from("outfit_products")
                    .delete()
                    .eq("outfit_id", value: row.outfitId)
                    .eq("product_id", value: productId.uuidString)
                    .execute()
                _ = try? await supabase
                    .from("outfit_products")
                    .insert(FullRow(
                        outfitId: row.outfitId,
                        name: row.name ?? label,
                        price: row.price,
                        image: url,
                        shopLink: row.shopLink,
                        productId: productId.uuidString
                    ))
                    .execute()
            }
        }

        // Refresh every loaded outfit that embeds this product.
        if let store {
            for outfit in store.outfits {
                guard let products = outfit.products,
                      products.contains(where: { $0.productId == productId }) else { continue }
                let updated = products.map { p -> Product in
                    guard p.productId == productId else { return p }
                    return Product(
                        name: p.name,
                        price: p.price,
                        image: url,
                        shopLink: p.shopLink,
                        productId: p.productId,
                        tags: p.tags
                    )
                }
                store.updateOutfit(outfit.id, caption: outfit.caption, products: updated)
            }
        }
    }
}

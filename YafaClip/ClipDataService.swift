import Foundation

// Minimal REST layer over Supabase's PostgREST — the clip carries no
// SDKs (size budget) and touches only anon-readable public data.

struct ClipFit: Sendable {
    let outfitId: String
    let username: String
    let avatarURL: URL?
    let caption: String?
    let dateLabel: String
    let weatherCondition: String?
    let weatherTempC: Int?
    let frameCount: Int
    let isRotationReversed: Bool
    let frameBase: String   // "<base>/<folder>/<prefix>" — append 00000.ext
    let frameExt: String
    let products: [ClipProduct]
    let likeCount: Int
    let commentCount: Int
}

struct ClipProduct: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let imageURL: URL?
    let shopURL: URL?
}

enum ClipDataService {
    private static let base = "https://dqvwutzoakfmnhbsefsw.supabase.co"
    private static let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRxdnd1dHpvYWtmbW5oYnNlZnN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUzNDQzMDUsImV4cCI6MjA5MDkyMDMwNX0.PWe0-qve1pz9dZilQ1FUwFphcvqXy6N-vr4qj5pKRvI"

    private static func get(_ path: String) async -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func count(_ path: String) async -> Int {
        guard let url = URL(string: base + path) else { return 0 }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "content-range"),
              let total = range.split(separator: "/").last.flatMap({ Int($0) })
        else { return 0 }
        return total
    }

    private struct OutfitRow: Decodable {
        let id: String
        let user_id: String
        let folder: String?
        let prefix: String?
        let frame_ext: String?
        let frame_count: Int?
        let is_rotation_reversed: Bool?
        let remote_base_url: String?
        let caption: String?
        let date: String?
        let weather_temp_c: Int?
        let weather_condition: String?
    }
    private struct ProfileRow: Decodable {
        let username: String?
        let avatar_url: String?
    }
    private struct ProductRow: Decodable {
        struct Canonical: Decodable {
            let name: String?
            let image_url: String?
            let source_url: String?
        }
        let name: String?
        let image: String?
        let shop_link: String?
        let products: Canonical?
    }

    static func loadFit(slugOrId: String) async -> ClipFit? {
        let cols = "id,user_id,folder,prefix,frame_ext,frame_count,is_rotation_reversed,remote_base_url,caption,date,weather_temp_c,weather_condition"
        let esc = slugOrId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? slugOrId

        var row: OutfitRow?
        for filter in ["slug=eq.\(esc)", "id=eq.\(esc)"] {
            if let data = await get("/rest/v1/outfits?\(filter)&is_public=eq.true&select=\(cols)&limit=1"),
               let rows = try? JSONDecoder().decode([OutfitRow].self, from: data),
               let first = rows.first {
                row = first
                break
            }
        }
        guard let outfit = row,
              let folder = outfit.folder, let prefix = outfit.prefix,
              let remoteBase = outfit.remote_base_url, !remoteBase.isEmpty
        else { return nil }

        async let profileData = get("/rest/v1/profiles?id=eq.\(outfit.user_id)&select=username,avatar_url&limit=1")
        async let productData = get("/rest/v1/outfit_products?outfit_id=eq.\(outfit.id)&select=name,image,shop_link,products(name,image_url,source_url)")
        async let likes = count("/rest/v1/likes?outfit_id=eq.\(outfit.id)&select=user_id")
        async let comments = count("/rest/v1/comments?outfit_id=eq.\(outfit.id)&select=id")

        let profile = (try? JSONDecoder().decode([ProfileRow].self, from: await profileData ?? Data()))?.first
        let productRows = (try? JSONDecoder().decode([ProductRow].self, from: await productData ?? Data())) ?? []

        let products: [ClipProduct] = productRows.compactMap { p in
            let name = p.products?.name ?? p.name ?? ""
            guard !name.isEmpty else { return nil }
            let image = p.products?.image_url ?? p.image
            let shop = [p.shop_link, p.products?.source_url]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return ClipProduct(
                name: name,
                imageURL: image.flatMap(URL.init(string:)),
                shopURL: shop.flatMap(URL.init(string:))
            )
        }

        var ext = (outfit.frame_ext ?? "webp").lowercased().trimmingCharacters(in: .whitespaces)
        if ext.hasPrefix(".") { ext.removeFirst() }
        if ext == "webmp" { ext = "webp" }

        return ClipFit(
            outfitId: outfit.id,
            username: profile?.username ?? "yafa",
            avatarURL: profile?.avatar_url.flatMap(URL.init(string:)),
            caption: outfit.caption,
            dateLabel: Self.dateLabel(outfit.date),
            weatherCondition: outfit.weather_condition,
            weatherTempC: outfit.weather_temp_c,
            frameCount: outfit.frame_count ?? 1,
            isRotationReversed: outfit.is_rotation_reversed ?? false,
            frameBase: remoteBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(folder)/\(prefix)",
            frameExt: ext,
            products: products,
            likeCount: await likes,
            commentCount: await comments
        )
    }

    private static func dateLabel(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: iso) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "EEE MMM d"
        return out.string(from: date).uppercased()
    }
}

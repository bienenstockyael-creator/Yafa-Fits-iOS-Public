import Foundation

/// Simple JSON-to-disk cache for Supabase data so the app loads instantly on relaunch.
enum LocalCache {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("supabase-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Generic read/write

    static func save<T: Encodable>(_ value: T, key: String) {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Typed helpers

    static func saveOutfits(_ outfits: [Outfit], userId: UUID) {
        save(outfits, key: "outfits-\(userId.uuidString)")
    }

    static func loadOutfits(userId: UUID) -> [Outfit]? {
        load([Outfit].self, key: "outfits-\(userId.uuidString)")
    }

    static func saveLikedIds(_ ids: Set<String>, userId: UUID) {
        save(Array(ids), key: "likes-\(userId.uuidString)")
    }

    static func loadLikedIds(userId: UUID) -> Set<String>? {
        guard let arr = load([String].self, key: "likes-\(userId.uuidString)") else { return nil }
        return Set(arr)
    }

    static func saveSavedIds(_ ids: Set<String>, userId: UUID) {
        save(Array(ids), key: "saves-\(userId.uuidString)")
    }

    static func loadSavedIds(userId: UUID) -> Set<String>? {
        guard let arr = load([String].self, key: "saves-\(userId.uuidString)") else { return nil }
        return Set(arr)
    }

    static func saveFollowingIds(_ ids: Set<UUID>, userId: UUID) {
        save(Array(ids.map(\.uuidString)), key: "following-\(userId.uuidString)")
    }

    static func loadFollowingIds(userId: UUID) -> Set<UUID>? {
        guard let arr = load([String].self, key: "following-\(userId.uuidString)") else { return nil }
        return Set(arr.compactMap { UUID(uuidString: $0) })
    }

    static func saveProfile(_ profile: Profile, userId: UUID) {
        save(profile, key: "profile-\(userId.uuidString)")
    }

    static func loadProfile(userId: UUID) -> Profile? {
        load(Profile.self, key: "profile-\(userId.uuidString)")
    }

    static func saveFeedPosts(_ posts: [FeedPost], userId: UUID) {
        save(posts, key: "feed-\(userId.uuidString)")
    }

    static func loadFeedPosts(userId: UUID) -> [FeedPost]? {
        load([FeedPost].self, key: "feed-\(userId.uuidString)")
    }

    static func clearAll(userId: UUID) {
        let keys = ["outfits", "likes", "saves", "following", "profile", "feed"]
        for key in keys {
            let url = directory.appendingPathComponent("\(key)-\(userId.uuidString).json")
            try? FileManager.default.removeItem(at: url)
        }
    }
}

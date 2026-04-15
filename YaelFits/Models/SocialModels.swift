import Foundation

struct LikeRecord: Codable, Sendable {
    let userId: UUID
    let outfitId: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case outfitId = "outfit_id"
        case createdAt = "created_at"
    }
}

struct SaveRecord: Codable, Sendable {
    let userId: UUID
    let outfitId: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case outfitId = "outfit_id"
        case createdAt = "created_at"
    }
}

struct Comment: Codable, Identifiable, Sendable {
    let id: Int64?
    let userId: UUID
    let outfitId: String
    var body: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case outfitId = "outfit_id"
        case body
        case createdAt = "created_at"
    }
}

struct FollowRecord: Codable, Sendable {
    let followerId: UUID
    let followingId: UUID
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case followerId = "follower_id"
        case followingId = "following_id"
        case createdAt = "created_at"
    }
}

struct OutfitLikeCount: Codable, Sendable {
    let outfitId: String
    let likeCount: Int

    enum CodingKeys: String, CodingKey {
        case outfitId = "outfit_id"
        case likeCount = "like_count"
    }
}

struct OutfitCommentCount: Codable, Sendable {
    let outfitId: String
    let commentCount: Int

    enum CodingKeys: String, CodingKey {
        case outfitId = "outfit_id"
        case commentCount = "comment_count"
    }
}

struct FollowCounts: Codable, Sendable {
    let userId: UUID
    let followerCount: Int
    let followingCount: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case followerCount = "follower_count"
        case followingCount = "following_count"
    }
}

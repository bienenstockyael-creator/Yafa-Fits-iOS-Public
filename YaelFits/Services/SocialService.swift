import Foundation

struct SocialService {
    // MARK: - Profile

    /// Creates a profile row if it doesn't exist yet (idempotent upsert).
    static func ensureProfile(userId: UUID, displayName: String? = nil) async {
        struct ProfileUpsert: Encodable {
            let id: String
            let username: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id, username
                case displayName = "display_name"
            }
        }
        _ = try? await supabase
            .from("profiles")
            .upsert(
                ProfileUpsert(id: userId.uuidString, username: displayName.map { Profile.sanitizeUsername($0) }, displayName: displayName),
                onConflict: "id",
                ignoreDuplicates: true
            )
            .execute()
    }

    static func getProfile(userId: UUID) async throws -> Profile {
        try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value
    }

    static func getProfiles(userIds: Set<UUID>) async throws -> [Profile] {
        guard !userIds.isEmpty else { return [] }
        return try await supabase
            .from("profiles")
            .select()
            .in("id", values: userIds.map(\.uuidString))
            .execute()
            .value
    }

    static func updateProfile(_ profile: Profile) async throws {
        struct ProfileUpsertFull: Encodable {
            let id: String
            let username: String?
            let display_name: String?
            let avatar_url: String?
            let bio: String?
        }
        try await supabase
            .from("profiles")
            .upsert(ProfileUpsertFull(
                id: profile.id.uuidString,
                username: profile.username,
                display_name: profile.displayName,
                avatar_url: profile.avatarUrl,
                bio: profile.bio
            ), onConflict: "id")
            .execute()
    }

    // MARK: - Likes

    static func getLikedOutfitIds(userId: UUID) async throws -> Set<String> {
        let likes: [LikeRecord] = try await supabase
            .from("likes")
            .select("user_id,outfit_id,created_at")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value
        return Set(likes.map(\.outfitId))
    }

    static func likeOutfit(userId: UUID, outfitId: String) async throws {
        struct LikeInsert: Encodable {
            let user_id: UUID
            let outfit_id: String
        }
        try await supabase
            .from("likes")
            .upsert(LikeInsert(user_id: userId, outfit_id: outfitId))
            .execute()
    }

    static func unlikeOutfit(userId: UUID, outfitId: String) async throws {
        try await supabase
            .from("likes")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .eq("outfit_id", value: outfitId)
            .execute()
    }

    // MARK: - Saves

    static func getSavedOutfitIds(userId: UUID) async throws -> Set<String> {
        let saves: [SaveRecord] = try await supabase
            .from("saves")
            .select("user_id,outfit_id,created_at")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value
        return Set(saves.map(\.outfitId))
    }

    static func saveOutfit(userId: UUID, outfitId: String) async throws {
        struct SaveInsert: Encodable {
            let user_id: UUID
            let outfit_id: String
        }
        try await supabase
            .from("saves")
            .upsert(SaveInsert(user_id: userId, outfit_id: outfitId))
            .execute()
    }

    static func unsaveOutfit(userId: UUID, outfitId: String) async throws {
        try await supabase
            .from("saves")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .eq("outfit_id", value: outfitId)
            .execute()
    }

    // MARK: - Comments

    static func getComments(outfitId: String) async throws -> [Comment] {
        try await supabase
            .from("comments")
            .select()
            .eq("outfit_id", value: outfitId)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    static func addComment(userId: UUID, outfitId: String, body: String) async throws -> Comment {
        struct CommentInsert: Encodable {
            let user_id: UUID
            let outfit_id: String
            let body: String
        }
        return try await supabase
            .from("comments")
            .insert(CommentInsert(user_id: userId, outfit_id: outfitId, body: body))
            .select()
            .single()
            .execute()
            .value
    }

    static func deleteComment(commentId: Int64) async throws {
        try await supabase
            .from("comments")
            .delete()
            .eq("id", value: String(commentId))
            .execute()
    }

    // MARK: - Follows

    static func getFollowingIds(userId: UUID) async throws -> Set<UUID> {
        let follows: [FollowRecord] = try await supabase
            .from("follows")
            .select("follower_id,following_id,created_at")
            .eq("follower_id", value: userId.uuidString)
            .execute()
            .value
        return Set(follows.map(\.followingId))
    }

    static func getFollowerIds(userId: UUID) async throws -> Set<UUID> {
        let follows: [FollowRecord] = try await supabase
            .from("follows")
            .select("follower_id,following_id,created_at")
            .eq("following_id", value: userId.uuidString)
            .execute()
            .value
        return Set(follows.map(\.followerId))
    }

    static func follow(followerId: UUID, followingId: UUID) async throws {
        struct FollowInsert: Encodable {
            let follower_id: UUID
            let following_id: UUID
        }
        try await supabase
            .from("follows")
            .upsert(FollowInsert(follower_id: followerId, following_id: followingId))
            .execute()
    }

    static func unfollow(followerId: UUID, followingId: UUID) async throws {
        try await supabase
            .from("follows")
            .delete()
            .eq("follower_id", value: followerId.uuidString)
            .eq("following_id", value: followingId.uuidString)
            .execute()
    }

    // MARK: - Counts

    static func getLikeCounts(outfitIds: [String]) async throws -> [String: Int] {
        let counts: [OutfitLikeCount] = try await supabase
            .from("outfit_like_counts")
            .select()
            .in("outfit_id", values: outfitIds)
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: counts.map { ($0.outfitId, $0.likeCount) })
    }

    static func getCommentCounts(outfitIds: [String]) async throws -> [String: Int] {
        let counts: [OutfitCommentCount] = try await supabase
            .from("outfit_comment_counts")
            .select()
            .in("outfit_id", values: outfitIds)
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: counts.map { ($0.outfitId, $0.commentCount) })
    }

    static func getFollowCounts(userId: UUID) async throws -> FollowCounts {
        try await supabase
            .from("follow_counts")
            .select()
            .eq("user_id", value: userId.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Search

    static func searchOutfits(query: String) async throws -> [Outfit] {
        // Search by tags using the contains operator
        try await supabase
            .from("outfits")
            .select()
            .eq("is_public", value: true)
            .contains("tags", value: [query.lowercased()])
            .order("date", ascending: false)
            .limit(50)
            .execute()
            .value
    }

    static func searchProfiles(query: String) async throws -> [Profile] {
        if query.isEmpty {
            // Return all users when no query (for suggestions)
            return try await supabase
                .from("profiles")
                .select()
                .limit(50)
                .execute()
                .value
        }
        return try await supabase
            .from("profiles")
            .select()
            .or("username.ilike.%\(query)%,display_name.ilike.%\(query)%")
            .limit(30)
            .execute()
            .value
    }
}

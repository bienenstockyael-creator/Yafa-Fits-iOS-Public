import Foundation

struct SocialService {
    // MARK: - Profile

    /// Creates a profile row if it doesn't exist yet (idempotent upsert).
    /// Always seeds a non-null username — sanitized display name first,
    /// email local-part fallback, random user-XXXX last resort. Users
    /// are never left with a null handle. They can customize via the
    /// onboarding screen or profile editor afterwards.
    static func ensureProfile(
        userId: UUID,
        displayName: String? = nil,
        email: String? = nil
    ) async {
        struct ProfileUpsert: Encodable {
            let id: String
            let username: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id, username
                case displayName = "display_name"
            }
        }
        let suggested = Profile.suggestedUsername(displayName: displayName, email: email)
        _ = try? await supabase
            .from("profiles")
            .upsert(
                ProfileUpsert(id: userId.uuidString, username: suggested, displayName: displayName),
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

    /// Write just the phone hash on the caller's profile.
    /// Separate from `updateProfile` so it can be called from
    /// the contacts flow without touching unrelated fields
    /// (display name, bio, etc.) and without needing the full
    /// profile object in hand.
    static func updatePhoneHash(userId: UUID, hash: String?) async throws {
        struct PhoneUpdate: Encodable { let phone_e164_hash: String? }
        try await supabase
            .from("profiles")
            .update(PhoneUpdate(phone_e164_hash: hash))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Atomically updates the three columns that drive the
    /// customizable profile header: style choice, accent color,
    /// and the bg-removed avatar URL. Passing nil for any field
    /// clears it (used when switching back to `minimal`, which
    /// shouldn't carry forward a stale accent color).
    static func updateHeaderCustomization(
        userId: UUID,
        style: ProfileHeaderStyle,
        accentColorHex: String?,
        cutoutURL: String?
    ) async throws {
        struct HeaderUpdate: Encodable {
            let header_style: String
            let header_accent_color: String?
            let avatar_cutout_url: String?
        }
        try await supabase
            .from("profiles")
            .update(HeaderUpdate(
                header_style: style.rawValue,
                header_accent_color: accentColorHex,
                avatar_cutout_url: cutoutURL
            ))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Flips the `is_onboarded` flag to true after the user
    /// completes (or skips through) the first-launch onboarding
    /// flow. Separate from `updateProfile` because the timing is
    /// different — this fires once, at the end of onboarding,
    /// and never again unless the column is manually reset.
    static func setOnboardingComplete(userId: UUID) async throws {
        struct OnboardingUpdate: Encodable { let is_onboarded: Bool }
        try await supabase
            .from("profiles")
            .update(OnboardingUpdate(is_onboarded: true))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Returns true when the given username has no existing
    /// `profiles` row. Used by the onboarding flow's username
    /// step to give the user inline feedback ("yael — taken")
    /// before they tap Continue. Case-insensitive at the DB
    /// layer (we lowercase here too for the network call so the
    /// caller doesn't have to remember).
    ///
    /// Treats network errors as "available" (returns true) — the
    /// authoritative uniqueness check is the DB constraint on
    /// commit. We don't want a flaky network to block the user
    /// from finishing onboarding when their pick is actually
    /// free.
    static func isUsernameAvailable(_ username: String) async -> Bool {
        struct UsernameRow: Decodable { let id: UUID }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let rows: [UsernameRow]? = try? await supabase
            .from("profiles")
            .select("id")
            .eq("username", value: normalized)
            .limit(1)
            .execute()
            .value
        return (rows?.isEmpty ?? true)
    }

    /// Plain UPDATE keyed by id (the profile row always exists for an
    /// established user — it's created by the signup trigger). NOT an upsert:
    /// upsert is INSERT … ON CONFLICT, which Postgres evaluates against the
    /// INSERT RLS policy too — and if the profiles table only grants UPDATE to
    /// the owner (the common setup), the upsert silently fails and edits (e.g.
    /// a new username) never reach the server, reverting on the next launch.
    static func updateProfile(_ profile: Profile) async throws {
        struct ProfileUpdate: Encodable {
            let username: String?
            let display_name: String?
            let avatar_url: String?
            let bio: String?
        }
        try await supabase
            .from("profiles")
            .update(ProfileUpdate(
                username: profile.username,
                display_name: profile.displayName,
                avatar_url: profile.avatarUrl,
                bio: profile.bio
            ))
            .eq("id", value: profile.id.uuidString)
            .execute()
    }

    /// Targeted display-name write keyed by user id. Unlike
    /// `updateProfile(_:)`, it needs no loaded `Profile` object — so
    /// it works during onboarding for a brand-new user whose profile
    /// row hasn't been fetched into the client yet (the row already
    /// exists server-side via the signup trigger).
    static func updateDisplayName(userId: UUID, displayName: String) async throws {
        try await supabase
            .from("profiles")
            .update(["display_name": displayName])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Targeted username write keyed by user id. See
    /// `updateDisplayName` for why this doesn't take a `Profile`.
    static func updateUsername(userId: UUID, username: String) async throws {
        try await supabase
            .from("profiles")
            .update(["username": username])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Targeted avatar-cutout-URL write keyed by user id. Used by the
    /// share card's on-demand bust generation to persist the cutout so
    /// the web/OG card and the next app launch reuse it. Deliberately
    /// does NOT touch header_style — the user keeps whatever profile
    /// style they're on; only the share card features the bust.
    static func updateAvatarCutoutUrl(userId: UUID, url: String) async throws {
        try await supabase
            .from("profiles")
            .update(["avatar_cutout_url": url])
            .eq("id", value: userId.uuidString)
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

    /// Records a like. Uses `onConflict: "user_id,outfit_id"` so a
    /// repeat tap on the same outfit (rapid double-tap, retry after
    /// network blip, etc.) is a no-op rather than inserting a new
    /// row. Without this, the default upsert conflicts on the
    /// primary key `id` (a freshly-generated UUID per call), which
    /// means every tap inserts a duplicate — inflating
    /// `outfit_like_counts` while the de-duped likers list shows
    /// the real count. The DB also has a unique constraint on
    /// `(user_id, outfit_id)` as a belt-and-suspenders guarantee.
    static func likeOutfit(userId: UUID, outfitId: String) async throws {
        struct LikeInsert: Encodable {
            let user_id: UUID
            let outfit_id: String
        }
        try await supabase
            .from("likes")
            .upsert(
                LikeInsert(user_id: userId, outfit_id: outfitId),
                onConflict: "user_id,outfit_id"
            )
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

    /// Profiles of every user who liked the given outfit, newest first.
    static func getLikersForOutfit(_ outfitId: String) async throws -> [Profile] {
        struct LikeRow: Decodable {
            let userId: UUID
            let createdAt: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case createdAt = "created_at"
            }
        }
        let likes: [LikeRow] = try await supabase
            .from("likes")
            .select("user_id, created_at")
            .eq("outfit_id", value: outfitId)
            .order("created_at", ascending: false)
            .execute()
            .value
        let userIds = Set(likes.map(\.userId))
        guard !userIds.isEmpty else { return [] }
        let profiles = try await getProfiles(userIds: userIds)
        // Preserve like-time ordering (most recent liker first).
        let profileById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return likes.compactMap { profileById[$0.userId] }
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
            .upsert(
                SaveInsert(user_id: userId, outfit_id: outfitId),
                onConflict: "user_id,outfit_id"
            )
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
            .upsert(
                FollowInsert(follower_id: followerId, following_id: followingId),
                onConflict: "follower_id,following_id"
            )
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

    // MARK: - Blocks & Reports

    /// User IDs this user has blocked. Used to filter blocked accounts
    /// out of the feed, comments, and follow lists client-side.
    static func getBlockedUserIds(userId: UUID) async throws -> Set<UUID> {
        struct BlockRow: Decodable { let blocked_id: UUID }
        let rows: [BlockRow] = try await supabase
            .from("blocks")
            .select("blocked_id")
            .eq("blocker_id", value: userId.uuidString)
            .execute()
            .value
        return Set(rows.map(\.blocked_id))
    }

    /// Block a user. Idempotent (upsert on the composite key). Also drops
    /// the blocker's follow of the target; the reverse direction and all
    /// other surfaces are hidden by client-side filtering on the
    /// blocked-id set.
    static func block(blockerId: UUID, blockedId: UUID) async throws {
        struct BlockInsert: Encodable {
            let blocker_id: UUID
            let blocked_id: UUID
        }
        try await supabase
            .from("blocks")
            .upsert(
                BlockInsert(blocker_id: blockerId, blocked_id: blockedId),
                onConflict: "blocker_id,blocked_id"
            )
            .execute()
        try? await unfollow(followerId: blockerId, followingId: blockedId)
    }

    static func unblock(blockerId: UUID, blockedId: UUID) async throws {
        try await supabase
            .from("blocks")
            .delete()
            .eq("blocker_id", value: blockerId.uuidString)
            .eq("blocked_id", value: blockedId.uuidString)
            .execute()
    }

    /// File a moderation report. `contentType` is "outfit" / "comment" /
    /// "user"; pass the matching id and leave the others nil. Reports are
    /// append-only from the client (RLS allows insert + read-own only).
    static func reportContent(
        reporterId: UUID,
        contentType: String,
        reportedUserId: UUID? = nil,
        reportedOutfitId: String? = nil,
        reportedCommentId: Int64? = nil,
        reason: String? = nil,
        details: String? = nil
    ) async throws {
        struct ReportInsert: Encodable {
            let reporter_id: UUID
            let content_type: String
            let reported_user_id: UUID?
            let reported_outfit_id: String?
            let reported_comment_id: Int64?
            let reason: String?
            let details: String?
        }
        try await supabase
            .from("reports")
            .insert(ReportInsert(
                reporter_id: reporterId,
                content_type: contentType,
                reported_user_id: reportedUserId,
                reported_outfit_id: reportedOutfitId,
                reported_comment_id: reportedCommentId,
                reason: reason,
                details: details
            ))
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

    /// Count of this user's PUBLIC outfits, independent of the
    /// viewer's follow status or the target's privacy. Used to
    /// render "X outfits" on profile views — see
    /// `project_yafa_outfit_count_display.md`. The RPC runs as
    /// SECURITY DEFINER and only returns an integer, so we don't
    /// leak any content of private users to non-followers; we
    /// just expose the public-sharing volume as a social signal.
    static func publicOutfitCount(userId: UUID) async throws -> Int {
        struct Params: Encodable { let p_user_id: String }
        let value: Int = try await supabase
            .rpc("public_outfit_count", params: Params(p_user_id: userId.uuidString))
            .execute()
            .value
        return value
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

    /// Tier 0 suggested-profiles ranking for the empty-friends feed.
    /// Fetches profiles + their follower counts, excludes self and
    /// anyone the user already follows, sorts by follower count desc
    /// (ties broken randomly so the same handful of accounts don't
    /// always dominate), and returns the top `limit`.
    ///
    /// No new server schema — composes existing `profiles` +
    /// `follow_counts` view client-side. Future tiers (contact
    /// matching, friends-of-friends) layer on top of the same call site.
    static func getSuggestedProfiles(
        excluding: Set<UUID>,
        currentUserId: UUID?,
        limit: Int = 20
    ) async throws -> [Profile] {
        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select()
            .limit(200)
            .execute()
            .value

        let filtered = profiles.filter { profile in
            profile.id != currentUserId && !excluding.contains(profile.id)
        }
        guard !filtered.isEmpty else { return [] }

        // Batch-fetch follower counts; tolerate missing rows (profile
        // with zero followers may not have a follow_counts entry).
        let ids = filtered.map(\.id.uuidString)
        let counts: [FollowCounts] = (try? await supabase
            .from("follow_counts")
            .select()
            .in("user_id", values: ids)
            .execute()
            .value) ?? []
        let countById = Dictionary(uniqueKeysWithValues: counts.map { ($0.userId, $0.followerCount) })

        return filtered
            .sorted { a, b in
                let lhs = countById[a.id] ?? 0
                let rhs = countById[b.id] ?? 0
                if lhs == rhs { return Bool.random() }
                return lhs > rhs
            }
            .prefix(limit)
            .map { $0 }
    }
}

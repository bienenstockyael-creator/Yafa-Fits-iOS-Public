import Foundation

/// Client around the vibes Supabase RPCs.
///
/// Vibes are a scarce reaction system: 3 per user per ISO week
/// (Monday UTC reset), accruing on the recipient's profile.
/// The give_vibe RPC handles all the rules (quota, self-vibe,
/// double-vibe) atomically — we just convert its result into a
/// typed enum the UI can pattern-match on.
enum VibesService {

    /// Outcome of a `giveVibe` call. Matches the RPC's
    /// `error_code` field plus a success case carrying the
    /// updated quota for live UI updates.
    enum GiveResult {
        case success(remainingThisWeek: Int)
        case quotaExhausted
        case alreadyVibed(remainingThisWeek: Int)
        case selfVibe
        case outfitNotFound
        case unauthenticated
        case networkError(Error)
    }

    static func giveVibe(outfitId: String) async -> GiveResult {
        struct Params: Encodable { let p_outfit_id: String }
        struct Row: Decodable {
            let success: Bool
            let remaining_this_week: Int
            let error_code: String?
        }
        do {
            let rows: [Row] = try await supabase
                .rpc("give_vibe", params: Params(p_outfit_id: outfitId))
                .execute()
                .value
            guard let row = rows.first else {
                return .networkError(VibesError.emptyResponse)
            }
            if row.success {
                return .success(remainingThisWeek: row.remaining_this_week)
            }
            switch row.error_code {
            case "quota_exhausted": return .quotaExhausted
            case "already_vibed":
                return .alreadyVibed(remainingThisWeek: row.remaining_this_week)
            case "self_vibe": return .selfVibe
            case "outfit_not_found": return .outfitNotFound
            case "unauthenticated": return .unauthenticated
            default: return .networkError(VibesError.unknownErrorCode(row.error_code ?? ""))
            }
        } catch {
            return .networkError(error)
        }
    }

    /// How many vibes the current user has left this ISO week.
    /// Returns 0 on any failure so the UI fails closed (better
    /// to under-report quota than to let the user spam taps
    /// that fail server-side).
    static func remainingThisWeek() async -> Int {
        do {
            let value: Int = try await supabase
                .rpc("vibes_remaining_this_week")
                .execute()
                .value
            return value
        } catch {
            return 0
        }
    }

    /// All-time vibes received by `userId`. Drives the profile
    /// stats row.
    static func receivedCount(userId: UUID) async -> Int {
        struct Params: Encodable { let p_user_id: String }
        do {
            let value: Int = try await supabase
                .rpc("vibes_received_count", params: Params(p_user_id: userId.uuidString))
                .execute()
                .value
            return value
        } catch {
            return 0
        }
    }

    /// Vibe-count tally per outfit id, used to render the count
    /// badge next to the fire icon on each feed card.
    static func vibeCounts(outfitIds: [String]) async -> [String: Int] {
        guard !outfitIds.isEmpty else { return [:] }
        struct VibeRow: Decodable { let outfit_id: String }
        do {
            let rows: [VibeRow] = try await supabase
                .from("vibes")
                .select("outfit_id")
                .in("outfit_id", values: outfitIds)
                .execute()
                .value
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row.outfit_id, default: 0] += 1
            }
            return counts
        } catch {
            return [:]
        }
    }

    /// Outfit ids the current user has already vibed on. Used
    /// to render the button in its "vibed" state so they don't
    /// see "tap to vibe" on outfits they've already vibed.
    static func vibedOutfitIds(currentUserId: UUID) async -> Set<String> {
        struct VibeRow: Decodable { let outfit_id: String }
        do {
            let rows: [VibeRow] = try await supabase
                .from("vibes")
                .select("outfit_id")
                .eq("giver_id", value: currentUserId.uuidString)
                .execute()
                .value
            return Set(rows.map(\.outfit_id))
        } catch {
            return []
        }
    }

    /// Profiles that vibed any outfit owned by `receiverId`,
    /// most recent first. Drives the profile-level vibers list
    /// (tap the "Vibes" stat on your own profile).
    ///
    /// A single user may appear multiple times in vibes (one
    /// row per outfit they vibed). We dedupe to one entry per
    /// giver, preserving order by their most recent vibe.
    static func vibersForUser(
        receiverId: UUID,
        limit: Int = 100
    ) async throws -> [Profile] {
        struct VibeRow: Decodable { let giver_id: UUID }
        let rows: [VibeRow] = try await supabase
            .from("vibes")
            .select("giver_id, created_at")
            .eq("receiver_id", value: receiverId.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        // Dedupe preserving first-occurrence order (= most recent).
        var seen = Set<UUID>()
        var orderedGiverIds: [UUID] = []
        for row in rows where seen.insert(row.giver_id).inserted {
            orderedGiverIds.append(row.giver_id)
        }
        guard !orderedGiverIds.isEmpty else { return [] }
        let profiles = try await SocialService
            .getProfiles(userIds: Set(orderedGiverIds))
        let order = Dictionary(
            uniqueKeysWithValues: orderedGiverIds.enumerated().map { ($1, $0) }
        )
        return profiles.sorted {
            (order[$0.id] ?? .max) < (order[$1.id] ?? .max)
        }
    }

    /// Profiles that vibed a specific outfit. Drives the
    /// VibersListSheet shown when the user taps the count.
    static func vibers(outfitId: String) async throws -> [Profile] {
        struct VibeRow: Decodable { let giver_id: UUID }
        let rows: [VibeRow] = try await supabase
            .from("vibes")
            .select("giver_id")
            .eq("outfit_id", value: outfitId)
            .order("created_at", ascending: false)
            .execute()
            .value
        let giverIds = Set(rows.map(\.giver_id))
        guard !giverIds.isEmpty else { return [] }
        let profiles = try await SocialService.getProfiles(userIds: giverIds)
        // Preserve creation-time order from the rows query —
        // getProfiles returns in whatever order Supabase sends.
        let order = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.giver_id, $0) })
        return profiles.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    // MARK: - Leaderboard

    /// Current ISO week in UTC, matching the `iso_week` column `give_vibe`
    /// writes (`IYYY-"W"IW`, e.g. "2026-W25").
    static func currentISOWeek() -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let now = Date()
        return String(
            format: "%04d-W%02d",
            cal.component(.yearForWeekOfYear, from: now),
            cal.component(.weekOfYear, from: now)
        )
    }

    /// Top users by vibes RECEIVED in the window, ranked desc. Aggregated
    /// client-side from the vibes table — fine at this scale; move to a
    /// server RPC if the table grows large.
    static func leaderboard(window: VibeWindow, limit: Int = 100) async -> [VibeRankEntry] {
        struct VibeRow: Decodable { let receiver_id: UUID }
        do {
            let rows: [VibeRow]
            switch window {
            case .thisWeek:
                rows = try await supabase
                    .from("vibes").select("receiver_id")
                    .eq("iso_week", value: currentISOWeek())
                    .execute().value
            case .allTime:
                rows = try await supabase
                    .from("vibes").select("receiver_id")
                    .execute().value
            }
            var counts: [UUID: Int] = [:]
            for row in rows { counts[row.receiver_id, default: 0] += 1 }
            let ranked = counts.sorted { $0.value > $1.value }.prefix(limit)
            let ids = Set(ranked.map(\.key))
            guard !ids.isEmpty else { return [] }
            let profiles = try await SocialService.getProfiles(userIds: ids)
            let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            return ranked.compactMap { id, count in
                byId[id].map { VibeRankEntry(profile: $0, count: count) }
            }
        } catch {
            return []
        }
    }
}

/// Which leaderboard ranking to show.
enum VibeWindow: Hashable { case thisWeek, allTime }

/// One ranked leaderboard entry: a profile + how many vibes they received.
struct VibeRankEntry: Identifiable {
    let profile: Profile
    let count: Int
    var id: UUID { profile.id }
}

private enum VibesError: LocalizedError {
    case emptyResponse
    case unknownErrorCode(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Server returned no rows from give_vibe."
        case .unknownErrorCode(let code):
            return "Unknown give_vibe error: \(code)"
        }
    }
}

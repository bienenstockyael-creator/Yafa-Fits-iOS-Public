import SwiftUI

struct NotificationsPlaceholderSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NotificationItem] = []
    @State private var isLoading = true
    @State private var lastSeenDate: Date = .distantPast
    @State private var selectedUserId: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        Spacer()
                        AppIcon(glyph: .bell, size: 36, color: AppPalette.textFaint)
                        Text("No notifications yet")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                        Text("Likes, comments, vibes, and follows will show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.textFaint)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                notificationRow(item)
                                    .background(item.isNew ? AppPalette.groupedBackground : Color.clear)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await loadNotifications() }
            .onDisappear {
                guard let userId = store.userId else { return }
                NotificationReadState.markSeen(for: userId)
                store.unreadNotificationCount = 0
            }
            .fullScreenCover(item: $selectedUserId) { userId in
                UserProfileView(userId: userId, onDismiss: { selectedUserId = nil })
                    .environment(store)
            }
        }
    }

    private func notificationRow(_ item: NotificationItem) -> some View {
        Button {
            // System notifications (free-gen-earned) have no actor
            // to navigate to. Tap is a no-op for those.
            guard item.type != .freeGenEarned,
                  let id = UUID(uuidString: item.actorId) else { return }
            selectedUserId = id
        } label: {
            HStack(spacing: LayoutMetrics.small) {
                avatarOrSystemIcon(for: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message)
                        .font(.system(size: 13, weight: item.isNew ? .semibold : .regular))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(item.timeAgo)
                        .font(.system(size: 10))
                        .foregroundStyle(AppPalette.textFaint)
                }

                Spacer(minLength: 0)

                if item.isNew {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.vertical, LayoutMetrics.xSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Vibe-received rows show the actor's avatar with a small
    /// gradient flame badge (matches the morph + popup gradient)
    /// so the row reads as a vibe at a glance. Free-gen-earned
    /// rows have no actor — they render a system-icon circle
    /// (sparkles) since there's nobody to attribute the reward to.
    @ViewBuilder
    private func avatarOrSystemIcon(for item: NotificationItem) -> some View {
        switch item.type {
        case .freeGenEarned:
            ZStack {
                Circle()
                    .fill(AppPalette.cardFill)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().stroke(AppPalette.cardBorder, lineWidth: 1)
                    )
                    .shadow(color: AppPalette.uploadGlow.opacity(0.35), radius: 4, y: 1)
                AppIcon(
                    glyph: .sparkles,
                    size: 18,
                    color: AppPalette.uploadGlow,
                    filled: true
                )
            }
            .frame(width: 36, height: 36)
        case .vibe:
            AvatarView(
                url: item.actorAvatarUrl,
                initial: item.actorInitial,
                size: 36,
                shadowRadius: 2,
                shadowY: 1
            )
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    AppIcon(
                        glyph: .flame,
                        size: 10,
                        color: AppPalette.uploadGlow,
                        filled: true
                    )
                }
                .offset(x: 2, y: 2)
            }
        case .like, .comment, .follow:
            AvatarView(
                url: item.actorAvatarUrl,
                initial: item.actorInitial,
                size: 36,
                shadowRadius: 2,
                shadowY: 1
            )
        }
    }

    private func loadNotifications() async {
        guard let userId = store.userId else {
            isLoading = false
            return
        }
        lastSeenDate = NotificationReadState.lastSeenDate(for: userId)

        // Get user's outfit IDs
        let userOutfitIds: [String] = (try? await supabase
            .from("outfits")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value as [IdRow])?.map(\.id) ?? []

        var allItems: [NotificationItem] = []

        // Likes on user's outfits
        if !userOutfitIds.isEmpty {
            struct LikeRow: Decodable {
                let userId: String
                let outfitId: String
                let createdAt: String
                enum CodingKeys: String, CodingKey {
                    case userId = "user_id"
                    case outfitId = "outfit_id"
                    case createdAt = "created_at"
                }
            }
            let likes: [LikeRow] = (try? await supabase
                .from("likes")
                .select("user_id, outfit_id, created_at")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value) ?? []

            for like in likes {
                allItems.append(NotificationItem(
                    id: "like-\(like.userId)-\(like.outfitId)",
                    type: .like,
                    actorId: like.userId,
                    createdAt: like.createdAt,
                    detail: nil
                ))
            }
        }

        // Comments on user's outfits
        if !userOutfitIds.isEmpty {
            struct CommentRow: Decodable {
                let userId: String
                let outfitId: String
                let body: String
                let createdAt: String
                enum CodingKeys: String, CodingKey {
                    case userId = "user_id"
                    case outfitId = "outfit_id"
                    case body
                    case createdAt = "created_at"
                }
            }
            let comments: [CommentRow] = (try? await supabase
                .from("comments")
                .select("user_id, outfit_id, body, created_at")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value) ?? []

            for comment in comments {
                allItems.append(NotificationItem(
                    id: "comment-\(comment.userId)-\(comment.createdAt)",
                    type: .comment,
                    actorId: comment.userId,
                    createdAt: comment.createdAt,
                    detail: comment.body
                ))
            }
        }

        // Vibes received on the user's outfits. One notification per
        // vibe (same shape as likes). The 5-vibe → free-gen milestone
        // is derived separately below, after we have the full vibe
        // timeline.
        var vibesReceived: [VibeReceivedRow] = []
        if !userOutfitIds.isEmpty {
            vibesReceived = (try? await supabase
                .from("vibes")
                .select("giver_id, outfit_id, created_at")
                .in("outfit_id", values: userOutfitIds)
                .neq("giver_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value) ?? []

            for vibe in vibesReceived {
                allItems.append(NotificationItem(
                    id: "vibe-\(vibe.giverId)-\(vibe.outfitId)",
                    type: .vibe,
                    actorId: vibe.giverId,
                    createdAt: vibe.createdAt,
                    detail: nil
                ))
            }
        }

        // Free-gen-earned milestones. Each crossing of a 5-vibe
        // threshold (5th, 10th, 15th, ...) emits one notification
        // dated at the timestamp of that boundary vibe. Use
        // ascending chronological order so the 5th vibe is found
        // at index 4.
        //
        // `vibesReceived` is the most-recent-50 window — sufficient
        // here because the notification list itself is capped, and
        // the user's lifetime vibe count is shown elsewhere
        // (profile chip).
        let ascending = vibesReceived.sorted { $0.createdAt < $1.createdAt }
        for (index, vibe) in ascending.enumerated() {
            let ordinal = index + 1
            guard ordinal % 5 == 0 else { continue }
            let freeGensSoFar = ordinal / 5
            allItems.append(NotificationItem(
                id: "freegen-\(freeGensSoFar)",
                type: .freeGenEarned,
                actorId: "",
                createdAt: vibe.createdAt,
                detail: nil
            ))
        }

        // Follows
        struct FollowRow: Decodable {
            let followerId: String
            let createdAt: String
            enum CodingKeys: String, CodingKey {
                case followerId = "follower_id"
                case createdAt = "created_at"
            }
        }
        let follows: [FollowRow] = (try? await supabase
            .from("follows")
            .select("follower_id, created_at")
            .eq("following_id", value: userId.uuidString)
            .neq("follower_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value) ?? []

        for follow in follows {
            allItems.append(NotificationItem(
                id: "follow-\(follow.followerId)",
                type: .follow,
                actorId: follow.followerId,
                createdAt: follow.createdAt,
                detail: nil
            ))
        }

        // Fetch all actor profiles. Drop empty IDs since
        // free-gen-earned rows have no actor — including an
        // empty string in the `.in("id", values:)` filter would
        // be a wasted Supabase round-trip.
        let actorIds = Array(Set(allItems.map(\.actorId)).filter { !$0.isEmpty })
        var profileMap: [String: Profile] = [:]
        if !actorIds.isEmpty {
            let profiles: [Profile] = (try? await supabase
                .from("profiles")
                .select()
                .in("id", values: actorIds)
                .execute()
                .value) ?? []
            profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString.lowercased(), $0) })
        }

        // Enrich items with profile info and sort
        let enriched = allItems.map { item -> NotificationItem in
            var enriched = item
            // Free-gen-earned rows have no actor — keep the
            // placeholder values from the struct init and just
            // compute `isNew`.
            if item.type == .freeGenEarned {
                enriched.isNew = item.date > lastSeenDate
                return enriched
            }
            let profile = profileMap[item.actorId.lowercased()]
            // Instagram-style: handle, not display name.
            enriched.actorName = profile?.handle ?? "Someone"
            enriched.actorAvatarUrl = profile?.avatarUrl
            enriched.actorInitial = profile?.initial ?? "?"
            enriched.isNew = item.date > lastSeenDate
            return enriched
        }
        .sorted { $0.date > $1.date }

        await MainActor.run {
            items = enriched
            isLoading = false
        }
    }
}

private struct IdRow: Decodable { let id: String }

private struct VibeReceivedRow: Decodable {
    let giverId: String
    let outfitId: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case giverId = "giver_id"
        case outfitId = "outfit_id"
        case createdAt = "created_at"
    }
}

private enum NotificationType {
    case like, comment, follow, vibe, freeGenEarned
}

private struct NotificationItem: Identifiable {
    let id: String
    let type: NotificationType
    let actorId: String
    let createdAt: String
    let detail: String?
    var actorName: String = "Someone"
    var actorAvatarUrl: String?
    var actorInitial: String = "?"
    var isNew: Bool = false

    var date: Date {
        let cleaned = createdAt.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: cleaned) ?? .distantPast
    }

    var message: String {
        switch type {
        case .like:    return "\(actorName) liked your outfit"
        case .comment: return "\(actorName): \(detail?.prefix(60) ?? "commented")"
        case .follow:  return "\(actorName) started following you"
        case .vibe:    return "\(actorName) vibed your outfit"
        case .freeGenEarned:
            return "You earned a free 3D generation"
        }
    }

    var timeAgo: String {
        RelativeTime.label(from: date)
    }
}

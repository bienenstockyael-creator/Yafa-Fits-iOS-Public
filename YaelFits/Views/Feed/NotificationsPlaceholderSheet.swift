import SwiftUI

struct NotificationsPlaceholderSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NotificationItem] = []
    @State private var isLoading = true
    @State private var lastSeenDate: Date = UserDefaults.standard.object(forKey: "lastSeenNotificationsAt") as? Date ?? .distantPast

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
                        Text("Likes, comments, and follows will show up here.")
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
                    Button("Close") {
                        UserDefaults.standard.set(Date(), forKey: "lastSeenNotificationsAt")
                        dismiss()
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await loadNotifications() }
        }
    }

    private func notificationRow(_ item: NotificationItem) -> some View {
        HStack(spacing: LayoutMetrics.small) {
            AvatarView(
                url: item.actorAvatarUrl,
                initial: item.actorInitial,
                size: 36,
                shadowRadius: 2,
                shadowY: 1
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.message)
                    .font(.system(size: 13, weight: item.isNew ? .semibold : .regular))
                    .foregroundStyle(AppPalette.textPrimary)
                    .lineLimit(2)

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
    }

    private func loadNotifications() async {
        guard let userId = store.userId else {
            isLoading = false
            return
        }

        // Get user's outfit IDs
        let userOutfitIds: [String] = (try? await supabase
            .from("outfits")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value as [IdRow])?.map(\.id) ?? []

        guard !userOutfitIds.isEmpty || true else {
            isLoading = false
            return
        }

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

        // Fetch all actor profiles
        let actorIds = Array(Set(allItems.map(\.actorId)))
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
            let profile = profileMap[item.actorId.lowercased()]
            enriched.actorName = profile?.displayLabel ?? "Someone"
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

private enum NotificationType {
    case like, comment, follow
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt) ?? .distantPast
    }

    var message: String {
        switch type {
        case .like:    return "\(actorName) liked your outfit"
        case .comment: return "\(actorName): \(detail?.prefix(60) ?? "commented")"
        case .follow:  return "\(actorName) started following you"
        }
    }

    var timeAgo: String {
        RelativeTime.label(from: date)
    }
}

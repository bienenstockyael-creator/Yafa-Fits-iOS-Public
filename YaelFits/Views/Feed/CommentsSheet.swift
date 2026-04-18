import SwiftUI

struct CommentsSheet: View {
    let outfitId: String
    @Environment(OutfitStore.self) private var store
    @State private var comments: [Comment] = []
    @State private var profiles: [UUID: Profile] = [:]
    @State private var newCommentText = ""
    @State private var isLoading = true
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                commentsList
                Divider().opacity(0.16)
                composeBar
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .task { await loadComments() }
        }
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: LayoutMetrics.xSmall) {
                if isLoading {
                    ProgressView()
                        .padding(.top, LayoutMetrics.xLarge)
                } else if comments.isEmpty {
                    emptyState
                } else {
                    ForEach(comments) { comment in
                        commentRow(comment)
                    }
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.xSmall)
            .padding(.bottom, LayoutMetrics.medium)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .comment, size: 24, color: AppPalette.textFaint)
            Text("No comments yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
            Text("Be the first to comment")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
        }
        .padding(.top, LayoutMetrics.xLarge)
    }

    private func commentRow(_ comment: Comment) -> some View {
        let profile = profiles[comment.userId]
        let isOwn = comment.userId == store.userId

        return HStack(alignment: .top, spacing: LayoutMetrics.xSmall) {
            AvatarView(
                url: profile?.avatarUrl,
                initial: profile?.initial ?? "?",
                size: 32
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.displayLabel ?? "User")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.textStrong)

                    Text(RelativeTime.short(from: comment.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(AppPalette.textFaint)

                    Spacer()

                    if isOwn {
                        Button {
                            deleteComment(comment)
                        } label: {
                            AppIcon(glyph: .xmark, size: 10, color: AppPalette.textFaint)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(comment.body)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(LayoutMetrics.xSmall)
        .appCard(cornerRadius: 16, shadowRadius: 2, shadowY: 1)
    }

    private var composeBar: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            TextField("", text: $newCommentText, prompt: Text("Add a comment...").foregroundStyle(AppPalette.textFaint))
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .appCard(cornerRadius: 20, shadowRadius: 2, shadowY: 1)

            Button {
                sendComment()
            } label: {
                if isSending {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                        .frame(width: 40, height: 40)
                } else {
                    AppIcon(glyph: .chevronRight, size: 14, color: newCommentText.isEmpty ? AppPalette.textFaint : AppPalette.textPrimary)
                        .frame(width: 40, height: 40)
                        .appCircle(shadowRadius: 2, shadowY: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(newCommentText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.vertical, LayoutMetrics.xSmall)
        .background(AppPalette.pageBackground)
    }

    private func loadComments() async {
        do {
            let fetched = try await SocialService.getComments(outfitId: outfitId)
            let userIds = Set(fetched.map(\.userId))
            let fetchedProfiles = (try? await SocialService.getProfiles(userIds: userIds)) ?? []
            let profileMap = Dictionary(uniqueKeysWithValues: fetchedProfiles.map { ($0.id, $0) })

            await MainActor.run {
                comments = fetched
                profiles = profileMap
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func sendComment() {
        guard let userId = store.userId,
              !newCommentText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSending = true
        let text = newCommentText
        newCommentText = ""

        Task {
            do {
                let comment = try await SocialService.addComment(userId: userId, outfitId: outfitId, body: text)
                let profile = store.currentProfile ?? profiles[userId]
                await MainActor.run {
                    comments.append(comment)
                    if let profile { profiles[userId] = profile }
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    newCommentText = text
                    isSending = false
                }
            }
        }
    }

    private func deleteComment(_ comment: Comment) {
        guard let id = comment.id else { return }
        withAnimation {
            comments.removeAll { $0.id == id }
        }
        Task {
            try? await SocialService.deleteComment(commentId: id)
        }
    }

}

import SwiftUI

struct CommentsSheet: View {
    let outfitId: String
    @Environment(OutfitStore.self) private var store
    @State private var comments: [Comment] = []
    @State private var profiles: [UUID: Profile] = [:]
    @State private var newCommentText = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var selectedUserId: UUID?
    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: BlockCandidate?

    /// Comments from users this person has blocked are hidden.
    private var visibleComments: [Comment] {
        comments.filter { !store.blockedUserIds.contains($0.userId) }
    }

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
            .fullScreenCover(item: $selectedUserId) { userId in
                UserProfileView(userId: userId, onDismiss: { selectedUserId = nil })
                    .environment(store)
                    .presentationBackground(.clear)
            }
            .sheet(item: $reportTarget) { target in
                ReportSheet(target: target)
                    .environment(store)
                    .roundedSheetBackground()
            }
            .confirmationDialog(
                blockCandidate.map { "Block \($0.name)?" } ?? "Block user?",
                isPresented: Binding(
                    get: { blockCandidate != nil },
                    set: { if !$0 { blockCandidate = nil } }
                ),
                presenting: blockCandidate
            ) { candidate in
                Button("Block", role: .destructive) { store.blockUser(candidate.userId) }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text("You won't see \(candidate.name)'s comments anymore.")
            }
        }
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: LayoutMetrics.xSmall) {
                if isLoading {
                    ProgressView()
                        .padding(.top, LayoutMetrics.xLarge)
                } else if visibleComments.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleComments) { comment in
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
            Button {
                selectedUserId = comment.userId
            } label: {
                AvatarView(
                    url: profile?.avatarUrl,
                    initial: profile?.initial ?? "?",
                    size: 32
                )
            }
            .buttonStyle(SolidPressButtonStyle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        selectedUserId = comment.userId
                    } label: {
                        Text(profile?.handle ?? "User")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                    }
                    .buttonStyle(SolidPressButtonStyle())

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
                        .buttonStyle(SolidPressButtonStyle())
                    } else {
                        Menu {
                            Button {
                                reportTarget = ReportTarget(
                                    contentType: "comment",
                                    reportedUserId: comment.userId,
                                    reportedOutfitId: outfitId,
                                    reportedCommentId: comment.id,
                                    displayName: profile?.handle ?? "this user"
                                )
                            } label: { Label("Report comment", systemImage: "flag") }
                            Button(role: .destructive) {
                                blockCandidate = BlockCandidate(
                                    userId: comment.userId,
                                    name: profile?.handle ?? "this user"
                                )
                            } label: { Label("Block user", systemImage: "hand.raised") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppPalette.textFaint)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
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
            .buttonStyle(SolidPressButtonStyle())
            .disabled(newCommentText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.vertical, LayoutMetrics.xSmall)
        .background(AppPalette.groupedBackground)
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

// MARK: - Moderation (shared Report/Block UI)
//
// NOTE: these shared types live here (rather than their own file) only
// because the Xcode project uses explicit file lists, not synchronized
// groups — a new .swift file wouldn't be in the build target without a
// project-file edit. Move to a dedicated Moderation.swift via Xcode
// (which registers it automatically) when convenient.

/// Identifies the thing being reported. The matching reported_* id is
/// set according to `contentType` ("outfit" / "comment" / "user").
struct ReportTarget: Identifiable {
    let id = UUID()
    let contentType: String
    var reportedUserId: UUID? = nil
    var reportedOutfitId: String? = nil
    var reportedCommentId: Int64? = nil
    var displayName: String = ""
}

/// A user pending a block confirmation.
struct BlockCandidate: Identifiable {
    let id = UUID()
    let userId: UUID
    let name: String
}

/// Report-reason picker. Files a report via SocialService and shows a
/// confirmation; if a user is implicated, offers to block them too.
struct ReportSheet: View {
    let target: ReportTarget
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedReason: String?
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false

    private let reasons = [
        "Spam or scam",
        "Harassment or bullying",
        "Nudity or sexual content",
        "Hate speech or symbols",
        "Violence or threats",
        "Self-harm or suicide",
        "Something else",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if didSubmit { confirmation } else { form }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(didSubmit ? "" : "Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.small) {
                Text("Why are you reporting this?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textSecondary)
                    .padding(.top, LayoutMetrics.small)

                ForEach(reasons, id: \.self) { reason in
                    Button {
                        selectedReason = reason
                    } label: {
                        HStack {
                            Text(reason)
                                .font(.system(size: 15))
                                .foregroundStyle(AppPalette.textStrong)
                            Spacer()
                            if selectedReason == reason {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(AppPalette.textPrimary)
                            }
                        }
                        .padding(LayoutMetrics.small)
                        .appCard(cornerRadius: 14, shadowRadius: 2, shadowY: 1)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                }

                TextField("Add details (optional)", text: $details, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(2...4)
                    .padding(LayoutMetrics.small)
                    .appCard(cornerRadius: 14, shadowRadius: 2, shadowY: 1)
                    .padding(.top, LayoutMetrics.xSmall)

                Button {
                    submit()
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(AppPalette.pageBackground)
                        } else {
                            Text("Submit report").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(AppPalette.pageBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(AppPalette.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(selectedReason == nil || isSubmitting)
                .opacity(selectedReason == nil ? 0.5 : 1)
                .padding(.top, LayoutMetrics.xSmall)
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.large)
        }
    }

    private var confirmation: some View {
        VStack(spacing: LayoutMetrics.small) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppPalette.textPrimary)
            Text("Thanks for letting us know")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            Text("We review reports within 24 hours and act on content that violates our guidelines.")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutMetrics.large)

            if let blockedUserId = target.reportedUserId, blockedUserId != store.userId {
                Button {
                    store.blockUser(blockedUserId)
                    dismiss()
                } label: {
                    Text("Block \(target.displayName.isEmpty ? "this user" : target.displayName)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppPalette.textStrong)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .appCard(cornerRadius: 14, shadowRadius: 2, shadowY: 1)
                }
                .buttonStyle(SolidPressButtonStyle())
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.small)
            }

            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
                .padding(.top, LayoutMetrics.xSmall)
            Spacer()
        }
    }

    private func submit() {
        guard let me = store.userId, let reason = selectedReason else { return }
        isSubmitting = true
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            try? await SocialService.reportContent(
                reporterId: me,
                contentType: target.contentType,
                reportedUserId: target.reportedUserId,
                reportedOutfitId: target.reportedOutfitId,
                reportedCommentId: target.reportedCommentId,
                reason: reason,
                details: trimmedDetails.isEmpty ? nil : trimmedDetails
            )
            await MainActor.run {
                isSubmitting = false
                didSubmit = true
            }
        }
    }
}

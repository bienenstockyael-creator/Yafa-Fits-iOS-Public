import SwiftUI

/// Lists every outfit the current user has saved. Tap an outfit to surface
/// a public-feed-style FeedPostCard overlay — same pattern as the
/// profile-grid overlay in UserProfileSheet, so users get a consistent
/// "tap thumbnail → see card" interaction across the app.
///
/// Unlike UserProfileSheet (which is keyed on a single author), saved
/// outfits can belong to many different authors. We resolve author info
/// (handle, avatar, Pro flag) per outfit so the rendered card routes
/// correctly when the user taps the author header.
struct SavedOutfitsSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var outfits: [Outfit] = []
    @State private var authorIdByOutfit: [String: UUID] = [:]
    @State private var profilesByUserId: [UUID: Profile] = [:]
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]
    @State private var myLikedOutfitIds: Set<String> = []
    @State private var vibeCounts: [String: Int] = [:]
    @State private var vibedOutfitIds: Set<String> = []
    @State private var vibesRemainingThisWeek: Int = 3
    @State private var isLoading = true

    @State private var selectedOutfit: Outfit?
    @State private var overlayVisible = false

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .background(AppPalette.groupedBackground)

                if let outfit = selectedOutfit {
                    outfitDetailOverlay(outfit: outfit)
                        .opacity(overlayVisible ? 1 : 0)
                        .scaleEffect(overlayVisible ? 1 : 0.96)
                        .animation(.easeOut(duration: 0.15), value: overlayVisible)
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await loadSaved() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if outfits.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(outfits) { outfit in
                        RotatableOutfitImage(
                            outfit: outfit,
                            height: 160,
                            draggable: outfit.frameCount > 1,
                            eagerLoad: true,
                            onTap: { presentOverlay(for: outfit) }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.compactCornerRadius, style: .continuous))
                        .outfit3DBadge(active: outfit.frameCount > 1)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.large)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .bookmark, size: 28, color: AppPalette.textFaint)
            Text("Nothing saved yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
            Text("Tap the bookmark on any outfit to keep it here.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutMetrics.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func outfitDetailOverlay(outfit: Outfit) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismissOverlay() }

            FeedPostCard(
                post: makeFeedPost(for: outfit),
                likeCount: likeCounts[outfit.id] ?? 0,
                commentCount: commentCounts[outfit.id] ?? 0,
                isInitiallyLiked: myLikedOutfitIds.contains(outfit.id),
                onCommentCountChanged: { newCount in
                    commentCounts[outfit.id] = newCount
                },
                onClose: { dismissOverlay() },
                hideProChrome: true,
                vibeCountInitial: vibeCounts[outfit.id] ?? 0,
                isVibedByMeInitial: vibedOutfitIds.contains(outfit.id),
                vibesRemainingThisWeek: $vibesRemainingThisWeek
            )
            .padding(.horizontal, LayoutMetrics.xxSmall)
            .padding(.top, LayoutMetrics.medium)
        }
    }

    private func presentOverlay(for outfit: Outfit) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Pre-populate the store cache so FeedPostCard mounts with the
        // full Outfit available immediately and its internal scaleEffect
        // doesn't compete with the overlay's appearance animation.
        store.feedOutfitCache[outfit.id] = outfit
        selectedOutfit = outfit
        overlayVisible = false
        DispatchQueue.main.async {
            overlayVisible = true
        }
    }

    private func dismissOverlay() {
        overlayVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !overlayVisible {
                selectedOutfit = nil
            }
        }
    }

    private func makeFeedPost(for outfit: Outfit) -> FeedPost {
        let authorId = authorIdByOutfit[outfit.id]
        let profile = authorId.flatMap { profilesByUserId[$0] }
        return FeedPost(
            id: "saved-preview-\(outfit.id)",
            authorName: profile?.handle ?? profile?.displayLabel ?? "User",
            outfitId: outfit.id,
            caption: outfit.caption,
            height: nil,
            size: nil,
            profileImage: nil,
            avatarUrl: profile?.avatarUrl,
            authorId: authorId,
            isAuthorPro: profile?.isPro,
            createdAt: nil
        )
    }

    private func loadSaved() async {
        let ids = Array(store.savedIds)
        guard !ids.isEmpty else {
            await MainActor.run { isLoading = false }
            return
        }

        let resolved = await ContentSource.getPublicOutfitsByIds(ids)
        let resolvedOutfits = resolved.map(\.outfit)
        let authorMap = Dictionary(uniqueKeysWithValues: resolved.map { ($0.outfit.id, $0.authorId) })

        // Fetch all authors' profiles in one batch so the cards render
        // the correct handle/avatar/Pro flag.
        let authorIds = Set(resolved.map(\.authorId))
        let profiles = (try? await SocialService.getProfiles(userIds: authorIds)) ?? []
        let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        await MainActor.run {
            outfits = resolvedOutfits
            authorIdByOutfit = authorMap
            profilesByUserId = profileMap
            isLoading = false
        }

        // Pre-fetch like + comment + vibe counts so tapping a card
        // shows the correct numbers immediately, not a "0" flash.
        let outfitIds = resolvedOutfits.map(\.id)
        if !outfitIds.isEmpty {
            async let likesTask = try? SocialService.getLikeCounts(outfitIds: outfitIds)
            async let cmtsTask = try? SocialService.getCommentCounts(outfitIds: outfitIds)
            async let vibeCountsTask = VibesService.vibeCounts(outfitIds: outfitIds)
            async let vibesRemainingTask = VibesService.remainingThisWeek()
            let mine: Set<String>
            let vibedSet: Set<String>
            if let viewerId = store.userId {
                mine = (try? await SocialService.getLikedOutfitIds(userId: viewerId)) ?? []
                vibedSet = await VibesService.vibedOutfitIds(currentUserId: viewerId)
            } else {
                mine = []
                vibedSet = []
            }
            let likes = (await likesTask) ?? [:]
            let cmts = (await cmtsTask) ?? [:]
            let vibeCountsResult = await vibeCountsTask
            let vibesRemainingResult = await vibesRemainingTask
            await MainActor.run {
                likeCounts = likes
                commentCounts = cmts
                myLikedOutfitIds = mine
                vibeCounts = vibeCountsResult
                vibedOutfitIds = vibedSet
                vibesRemainingThisWeek = vibesRemainingResult
            }
        }
    }
}

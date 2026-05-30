import SwiftUI

/// Renders when `store.followingIds.isEmpty` — turns the Friends tab
/// into a discovery surface. Top half is `EmptyFollowingHeroView`
/// (avatar bubbles + button); bottom half is the community feed,
/// pulled from `ContentSource.getPublicFeed()`. Hero shrinks/fades as
/// the user scrolls the community feed up (BeReal-style).
///
/// Presentation surfaces (DiscoverView modal, UserProfileView cover)
/// are owned by the parent — this view only emits intents.
struct EmptyFollowingView: View {
    @Environment(OutfitStore.self) private var store

    let onFindFriendsTap: () -> Void
    let onProfileTap: (Profile) -> Void
    /// Forwarded to the hero; non-nil after the user has shared
    /// their contacts and we've matched them to existing Yafa
    /// users. Triggers the hero's avatar repopulation.
    var seedProfiles: [Profile]? = nil

    @State private var communityPosts: [FeedPost] = []
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]
    @State private var myLikedOutfitIds: Set<String> = []
    @State private var hasLoadedCommunity = false
    @State private var scrollOffset: CGFloat = 0

    // No global collapseProgress anymore — `EmptyFollowingHeroView`
    // computes per-element triggers internally from the raw
    // scrollOffset, so the bottom avatars fade as the community card
    // approaches them, then the button + top avatars follow.

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // UIKit-backed scroll tracker — the comment at the
                // top of ScrollOffsetObserver.swift explicitly notes
                // that GeometryReader+PreferenceKey "silently fails
                // to propagate from a top-level VStack depth in this
                // view's hierarchy", which is exactly what was
                // blocking the collapse animation here.
                ScrollOffsetObserver { offsetY in
                    scrollOffset = max(0, offsetY)
                }
                .frame(width: 0, height: 0)

                EmptyFollowingHeroView(
                    onFindFriendsTap: onFindFriendsTap,
                    onProfileTap: onProfileTap,
                    scrollOffset: scrollOffset,
                    seedProfiles: seedProfiles
                )
                .frame(height: 380)
                .padding(.top, LayoutMetrics.feedTopInset)
                // Counter-scroll offset pins the hero visually in
                // place. The hero still occupies its full layout
                // slot in the scroll content, so the community
                // section below scrolls up exactly as before — but
                // the hero's avatars and button stay anchored on
                // screen until their per-element fade triggers fire
                // as the community card "gets near" each one. As
                // the cards slide over the hero region, the elements
                // are already faded out, so visually the cards take
                // over the space cleanly.
                .offset(y: scrollOffset)

                communitySection
            }
        }
        // No explicit background here — the parent
        // `PublicFeedListView` already paints the grouped
        // background across the whole screen at zIndex 0.
        // Adding one here would extend behind the header and
        // hide the Yafa logo (which we want visible at top,
        // matching the friends-feed behavior).
        .task {
            await loadCommunityIfNeeded()
        }
    }

    // MARK: - Community section

    private var communitySection: some View {
        // Label sits low in the section (large top inset pushes
        // the header further from the hero) and tight against
        // the first card (xxxSmall gap below the label) — reads
        // as a quiet caption on top of the first card rather
        // than a heavy section divider.
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            // Bigger, capitalized title acts as a clear section
            // divider between the hero and the feed cards, with
            // generous breathing room above (push down from the
            // hero) and below (gap before the first card).
            Text("Community")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, LayoutMetrics.screenPadding + LayoutMetrics.xxSmall)
                .padding(.top, 48)

            LazyVStack(spacing: LayoutMetrics.medium) {
                ForEach(communityPosts) { post in
                    FeedPostCard(
                        post: post,
                        likeCount: likeCounts[post.outfitId] ?? 0,
                        commentCount: commentCounts[post.outfitId] ?? 0,
                        isInitiallyLiked: myLikedOutfitIds.contains(post.outfitId),
                        onCommentCountChanged: { newCount in
                            commentCounts[post.outfitId] = newCount
                        },
                        // Suppress Pro halo on Community cards — keeps
                        // every post in this section visually neutral
                        // (mockup shows no gradient glow even on Pro
                        // authors).
                        hideProChrome: true,
                        showFollowAction: true
                    )
                    .id(post.id)
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.screenPadding)
        }
    }

    // MARK: - Data

    private func loadCommunityIfNeeded() async {
        guard !hasLoadedCommunity else { return }
        hasLoadedCommunity = true

        let posts = await ContentSource.getPublicFeed()
        await MainActor.run { communityPosts = posts }
        await loadCounts(for: posts.map(\.outfitId))
    }

    private func loadCounts(for outfitIds: [String]) async {
        guard !outfitIds.isEmpty, let userId = store.userId else { return }

        async let likesTask = try? SocialService.getLikeCounts(outfitIds: outfitIds)
        async let commentsTask = try? SocialService.getCommentCounts(outfitIds: outfitIds)
        async let myLikesTask = try? SocialService.getLikedOutfitIds(userId: userId)

        let likes = await likesTask ?? [:]
        let comments = await commentsTask ?? [:]
        let myLikes = await myLikesTask ?? []

        await MainActor.run {
            likeCounts = likes
            commentCounts = comments
            myLikedOutfitIds = myLikes
        }
    }
}

private struct EmptyFollowingScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

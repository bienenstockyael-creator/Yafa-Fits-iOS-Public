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
    /// Shared scroll state for the hero. Holding the offset on an
    /// `@Observable` (rather than `@State` + prop drilling) means
    /// only the leaf hero subviews that actually read the offset
    /// re-evaluate on each scroll tick — this view body stays
    /// stable, so the closures it creates for the hero don't
    /// churn and the hero body itself doesn't re-evaluate either.
    @State private var heroScrollState = HeroScrollState()
    /// Vibe state for the community cards. Same structure as
    /// PublicFeedListView — the two surfaces don't share state
    /// since they're mutually exclusive at any moment, but
    /// every mount re-fetches `remainingThisWeek` from the
    /// backend so a vibe given in community then a switch to
    /// the friends feed shows the correct quota.
    @State private var vibeCounts: [String: Int] = [:]
    @State private var vibedOutfitIds: Set<String> = []
    @State private var vibesRemainingThisWeek: Int = 3

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
                    // Coalesce scroll updates: round to nearest 2pt
                    // and skip writes when the bucketed value hasn't
                    // changed (fade range is 30–60pt so 2pt steps
                    // are imperceptible). Writes target
                    // `heroScrollState.offset`; since this view's
                    // body doesn't read that property, the update
                    // never re-evaluates this body. Only `PinnedHero`
                    // (which reads it for the `.offset(y:)` pin) and
                    // the hero's leaf subviews re-evaluate.
                    let next = max(0, offsetY)
                    let bucketed = (next / 2).rounded() * 2
                    if bucketed != heroScrollState.offset {
                        heroScrollState.offset = bucketed
                    }
                }
                .frame(width: 0, height: 0)

                PinnedHero(
                    scrollState: heroScrollState,
                    onFindFriendsTap: onFindFriendsTap,
                    onProfileTap: onProfileTap,
                    seedProfiles: seedProfiles
                )

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
            // Track view-mount time so the community apply can
            // wait out the hero's entry-animation window.
            await loadCommunityIfNeeded(viewMountedAt: Date())
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
                        showFollowAction: true,
                        vibeCountInitial: vibeCounts[post.outfitId] ?? 0,
                        isVibedByMeInitial: vibedOutfitIds.contains(post.outfitId),
                        vibesRemainingThisWeek: $vibesRemainingThisWeek
                    )
                    .id(post.id)
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.screenPadding)
        }
    }

    // MARK: - Data

    private func loadCommunityIfNeeded(viewMountedAt mountTime: Date) async {
        guard !hasLoadedCommunity else { return }
        hasLoadedCommunity = true

        // Apply community posts as soon as the fetch returns, so
        // the cards' entry animation aligns with the hero's avatar
        // entry. (Earlier I held the apply until ~1.1s post-mount
        // to keep the LazyVStack from competing with the avatar
        // springs for main-thread time — but that made the cards
        // visibly lag the avatars, and the OTHER optimizations
        // we've layered in since (batched entry animations, image
        // pre-warm, killed disco-ball 3× ramp) are doing most of
        // the work keeping the springs smooth.)
        _ = mountTime  // retained on the signature for future use
        let posts = await ContentSource.getPublicFeed()
        await MainActor.run { communityPosts = posts }
        await loadCounts(for: posts.map(\.outfitId))
        await loadVibes(for: posts.map(\.outfitId))
    }

    private func loadVibes(for outfitIds: [String]) async {
        guard let userId = store.userId else { return }
        async let countsTask = VibesService.vibeCounts(outfitIds: outfitIds)
        async let vibedTask = VibesService.vibedOutfitIds(currentUserId: userId)
        async let remainingTask = VibesService.remainingThisWeek()

        let counts = await countsTask
        let vibed = await vibedTask
        let remaining = await remainingTask

        await MainActor.run {
            vibeCounts = counts
            vibedOutfitIds = vibed
            vibesRemainingThisWeek = remaining
        }
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

// MARK: - PinnedHero

/// Thin wrapper that hosts the hero, applies the counter-scroll
/// pin (`.offset(y:)`), and gates hit testing once the hero has
/// scrolled out of view. By isolating the `scrollState.offset`
/// reads here, neither the outer `EmptyFollowingView` body nor
/// the inner `EmptyFollowingHeroView` body observes the offset —
/// so on each scroll tick, only this small wrapper re-evaluates
/// (along with the hero's leaf subviews that need new fade
/// values). The hero body, ForEach iterations, and AvatarBubble
/// closure construction stay stable during scroll.
private struct PinnedHero: View {
    @Bindable var scrollState: HeroScrollState
    let onFindFriendsTap: () -> Void
    let onProfileTap: (Profile) -> Void
    let seedProfiles: [Profile]?

    var body: some View {
        EmptyFollowingHeroView(
            onFindFriendsTap: onFindFriendsTap,
            onProfileTap: onProfileTap,
            scrollState: scrollState,
            seedProfiles: seedProfiles
        )
        .frame(height: 380)
        .padding(.top, LayoutMetrics.feedTopInset)
        // Counter-scroll pin: the hero still occupies its full
        // layout slot in the scroll content, but visually stays
        // anchored on screen until per-element fade triggers
        // dismiss it. The community cards slide over the hero
        // region cleanly because the elements are already faded.
        .offset(y: scrollState.offset)
        // Stop intercepting taps once everything is off-screen.
        .allowsHitTesting(scrollState.offset < 400)
    }
}

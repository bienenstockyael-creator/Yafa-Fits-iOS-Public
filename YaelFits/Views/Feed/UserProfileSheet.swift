import SwiftUI

struct UserProfileSheet: View {
    let userId: UUID
    @Environment(OutfitStore.self) private var store
    @State private var profile: Profile?
    @State private var outfits: [Outfit] = []
    @State private var isLoading = true
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var followerIds: [UUID] = []
    @State private var followingIds: [UUID] = []
    @State private var showFollowers = false
    @State private var showFollowing = false
    @State private var selectedOutfit: Outfit?
    @State private var overlayVisible = false
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]
    @State private var myLikedOutfitIds: Set<String> = []
    /// Measured y position of the stats card's top edge, in the
    /// "profileSheet" coord space (= the body's outer ZStack, which
    /// starts at the safe area top). Used as the overlay's
    /// `.padding(.top, …)` so the overlay's top edge lands exactly on
    /// the stats card's top edge regardless of bio length / device.
    @State private var statsCardTopY: CGFloat = 175

    private var isFollowing: Bool {
        store.followingIds.contains(userId)
    }

    private var isOwnProfile: Bool {
        userId == store.userId
    }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(spacing: LayoutMetrics.large) {
                        if isLoading {
                            ProgressView()
                                .padding(.top, LayoutMetrics.xLarge)
                        } else {
                            headerSection
                            if !outfits.isEmpty {
                                outfitGrid
                            } else {
                                emptyOutfits
                            }
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.small)
                    .padding(.bottom, LayoutMetrics.large)
                }
                .scrollIndicators(.hidden)
                .background(AppPalette.groupedBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.light, for: .navigationBar)
                .task { await loadProfile() }
            }

            if let outfit = selectedOutfit {
                outfitDetailOverlay(outfit: outfit)
                    .opacity(overlayVisible ? 1 : 0)
                    .scaleEffect(overlayVisible ? 1 : 0.96)
                    .animation(.easeOut(duration: 0.15), value: overlayVisible)
            }
        }
        .coordinateSpace(name: "profileSheet")
        .onPreferenceChange(StatsCardTopPreferenceKey.self) { y in
            if y > 0 { statsCardTopY = y }
        }
    }

    /// Tap-to-dismiss backdrop + the card. Card uses the public-feed
    /// `.appCard()` chrome via `FeedPostCard` itself — same shadow,
    /// border, and translucent fill as every other card in the app.
    @ViewBuilder
    private func outfitDetailOverlay(outfit: Outfit) -> some View {
        ZStack(alignment: .top) {
            // Tap catcher fills the ZStack's bounds. Crucially we
            // do NOT call `.ignoresSafeArea()` here — that would
            // extend the ZStack's top above the safe area, while the
            // stats card's measured y is in body-local coords (which
            // start at the safe area top), creating a coord-space
            // mismatch that misaligned the overlay last time.
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
                hideProChrome: true
            )
            .padding(.horizontal, LayoutMetrics.xxSmall)
            .padding(.top, overlayTopOffset)
        }
    }

    /// Dynamic position — tracks the stats card's measured y in the
    /// "profileSheet" coord space, so the overlay's top edge sits
    /// exactly on the stats card's top edge regardless of bio length,
    /// dynamic type, or device size. Defaults to 175 until the
    /// preference fires (typically before the user can tap).
    private var overlayTopOffset: CGFloat { statsCardTopY }

    private func dismissOverlay() {
        // Flip visibility first — the .animation modifier on the
        // overlay drives the scale-down + fade-out. Once that
        // animation has had time to play, clear selectedOutfit so the
        // conditional view unmounts.
        overlayVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Only clear if user hasn't re-tapped in the meantime.
            if !overlayVisible {
                selectedOutfit = nil
            }
        }
    }

    private func makeFeedPost(for outfit: Outfit) -> FeedPost {
        FeedPost(
            id: "profile-preview-\(outfit.id)",
            authorName: profile?.handle ?? profile?.displayLabel ?? "User",
            outfitId: outfit.id,
            caption: outfit.caption,
            height: nil,
            size: nil,
            profileImage: nil,
            avatarUrl: profile?.avatarUrl,
            authorId: userId,
            // Pro flag is preserved so the PRO badge still shows in
            // the card header. The Pro *chrome* (frosty rim, holo,
            // blue shadow) is suppressed via FeedPostCard's
            // `hideProChrome` flag — see the call site.
            isAuthorPro: profile?.isPro,
            createdAt: nil
        )
    }

    private var headerSection: some View {
        VStack(spacing: LayoutMetrics.small) {
            AvatarView(
                url: profile?.avatarUrl,
                initial: profile?.initial ?? "?",
                size: 80,
                shadowRadius: 8,
                shadowY: 4
            )

            // Name
            Text(profile?.displayLabel ?? "User")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)

            if let username = profile?.username, !username.isEmpty {
                Text("@\(username)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
            }

            // Bio
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }

            // Stats
            HStack(spacing: 0) {
                statItem(count: outfits.count, label: "Outfits")
                Button { showFollowers = true } label: {
                    statItem(count: followerCount, label: "Followers")
                }.buttonStyle(.plain)
                Button { showFollowing = true } label: {
                    statItem(count: followingCount, label: "Following")
                }.buttonStyle(.plain)
            }
            .padding(.vertical, LayoutMetrics.xSmall)
            .appCard(cornerRadius: 16, shadowRadius: 4, shadowY: 2)
            // Emit the stats card's top y in the body's coord space
            // so the overlay can position itself to align with it.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: StatsCardTopPreferenceKey.self,
                        value: geo.frame(in: .named("profileSheet")).minY
                    )
                }
            )
            .sheet(isPresented: $showFollowers) {
                FollowListSheet(title: "Followers", userIds: followerIds)
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppPalette.groupedBackground)
            }
            .sheet(isPresented: $showFollowing) {
                FollowListSheet(title: "Following", userIds: followingIds)
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppPalette.groupedBackground)
            }

            // Follow button
            if !isOwnProfile {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.toggleFollow(userId)
                    }
                } label: {
                    Text(isFollowing ? "FOLLOWING" : "FOLLOW")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(isFollowing ? AppPalette.textMuted : AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .appCapsule(shadowRadius: 4, shadowY: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var outfitGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(outfits) { outfit in
                RotatableOutfitImage(
                    outfit: outfit,
                    height: 160,
                    draggable: outfit.frameCount > 1,
                    eagerLoad: true,
                    onTap: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        // Pre-populate the store cache so FeedPostCard
                        // mounts with `cardVisible = true` (otherwise
                        // its internal scaleEffect(0.96) competes with
                        // ours).
                        store.feedOutfitCache[outfit.id] = outfit
                        // Mount first (selectedOutfit non-nil) so the
                        // overlay view exists in the tree, then on the
                        // next runloop flip visibility — that way the
                        // .animation modifier on the conditional view
                        // catches the false → true transition cleanly.
                        selectedOutfit = outfit
                        overlayVisible = false
                        DispatchQueue.main.async {
                            overlayVisible = true
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.compactCornerRadius, style: .continuous))
                .outfit3DBadge(active: outfit.frameCount > 1)
            }
        }
    }

    private var emptyOutfits: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            Text("No public outfits yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
        }
        .padding(.top, LayoutMetrics.large)
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(AppPalette.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadProfile() async {
        do {
            async let profileTask = SocialService.getProfile(userId: userId)
            async let countsTask = SocialService.getFollowCounts(userId: userId)
            async let outfitsTask = ContentSource.getPublicOutfits(forUser: userId)
            async let followerIdsTask = try SocialService.getFollowerIds(userId: userId)
            async let followingIdsTask = try SocialService.getFollowingIds(userId: userId)

            let p = try await profileTask
            let counts = try await countsTask
            let userOutfits = await outfitsTask
            let frs = (try? await followerIdsTask) ?? []
            let fng = (try? await followingIdsTask) ?? []

            await MainActor.run {
                profile = p
                followerCount = counts.followerCount
                followingCount = counts.followingCount
                outfits = userOutfits
                followerIds = Array(frs)
                followingIds = Array(fng)
                isLoading = false
            }

            // Pre-fetch like + comment counts for all outfits so tapping
            // one opens the feed card with correct numbers immediately,
            // not "0 likes" briefly.
            let outfitIds = userOutfits.map(\.id)
            if !outfitIds.isEmpty {
                async let likesTask = try? SocialService.getLikeCounts(outfitIds: outfitIds)
                async let cmtsTask = try? SocialService.getCommentCounts(outfitIds: outfitIds)
                let mine: Set<String>
                if let viewerId = store.userId {
                    mine = (try? await SocialService.getLikedOutfitIds(userId: viewerId)) ?? []
                } else {
                    mine = []
                }
                let likes = (await likesTask) ?? [:]
                let cmts = (await cmtsTask) ?? [:]
                await MainActor.run {
                    likeCounts = likes
                    commentCounts = cmts
                    myLikedOutfitIds = mine
                }
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}



private struct StatsCardTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

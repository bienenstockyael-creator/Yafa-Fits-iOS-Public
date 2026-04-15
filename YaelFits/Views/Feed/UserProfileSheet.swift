import SwiftUI

struct UserProfileSheet: View {
    let userId: UUID
    @Environment(OutfitStore.self) private var store
    @State private var profile: Profile?
    @State private var outfits: [Outfit] = []
    @State private var isLoading = true
    @State private var followerCount = 0
    @State private var followingCount = 0

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
                statItem(count: followerCount, label: "Followers")
                statItem(count: followingCount, label: "Following")
            }
            .padding(.vertical, LayoutMetrics.xSmall)
            .appCard(cornerRadius: 16, shadowRadius: 4, shadowY: 2)

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
                    draggable: true,
                    eagerLoad: true
                )
                .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.compactCornerRadius, style: .continuous))
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

            let p = try await profileTask
            let counts = try await countsTask
            let userOutfits = await outfitsTask

            await MainActor.run {
                profile = p
                followerCount = counts.followerCount
                followingCount = counts.followingCount
                outfits = userOutfits
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

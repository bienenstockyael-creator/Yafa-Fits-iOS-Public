import SwiftUI

/// Sheet listing the users who vibed an outfit, or every user
/// who has ever vibed any of someone's outfits.
///
/// Two variants chosen by `source`:
///   - `.outfit(id)` — tap the fire-count badge on a feed card
///     to see who vibed that specific outfit (single sheet,
///     scoped to one outfit).
///   - `.user(id)`   — tap the "Vibes" stat on a profile to
///     see everyone who has ever vibed any of their outfits,
///     deduped, most-recent-vibe first.
///
/// Reuses `FollowListSheet`'s row layout (Instagram-style:
/// username primary, display name secondary, avatar lead) so
/// the visual language is consistent across all "list of
/// users" sheets in the app.
struct VibersListSheet: View {
    enum Source {
        case outfit(String)
        case user(UUID)
    }

    let source: Source

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [Profile] = []
    @State private var isLoading = true
    @State private var selectedUserId: IdentifiableUUID?

    private var title: String {
        switch source {
        case .outfit: return "Vibes"
        case .user:   return "Vibed by"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if profiles.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        Text("No vibes yet")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(profiles) { profile in
                                row(for: profile)
                            }
                        }
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await load() }
            .fullScreenCover(item: $selectedUserId) { wrapper in
                UserProfileView(userId: wrapper.id, onDismiss: { selectedUserId = nil })
                    .environment(store)
            }
        }
    }

    private func row(for profile: Profile) -> some View {
        Button {
            selectedUserId = IdentifiableUUID(id: profile.id)
        } label: {
            HStack(spacing: LayoutMetrics.small) {
                AvatarView(
                    url: profile.avatarUrl,
                    initial: profile.initial,
                    size: 40,
                    shadowRadius: 2,
                    shadowY: 1
                )
                VStack(alignment: .leading, spacing: 2) {
                    if let username = profile.username, !username.isEmpty {
                        Text(username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                        if let dn = profile.displayName, !dn.isEmpty {
                            Text(dn)
                                .font(.system(size: 11))
                                .foregroundStyle(AppPalette.textFaint)
                        }
                    } else {
                        Text(profile.displayLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, LayoutMetrics.xSmall)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func load() async {
        let loaded: [Profile]
        switch source {
        case .outfit(let id):
            loaded = (try? await VibesService.vibers(outfitId: id)) ?? []
        case .user(let userId):
            loaded = (try? await VibesService.vibersForUser(receiverId: userId)) ?? []
        }
        await MainActor.run {
            profiles = loaded
            isLoading = false
        }
    }
}

/// Local Identifiable wrapper so `.fullScreenCover(item:)` can
/// present off a UUID without needing UUID itself to conform
/// (which would conflict with other usages in the app).
private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

// MARK: - Vibes leaderboard

/// Full-height sheet ranking users by vibes RECEIVED — two swipeable pages
/// (This week / All time) kept in sync with a segmented header. Opened from the
/// Vibes stat on a profile.
struct VibesLeaderboardSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var window: VibeWindow = .thisWeek
    @State private var weekEntries: [VibeRankEntry] = []
    @State private var allTimeEntries: [VibeRankEntry] = []
    @State private var weekLoading = true
    @State private var allTimeLoading = true
    @State private var selectedUserId: IdentifiableUUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Small all-caps tab labels — the app's section-label style.
                HStack(spacing: LayoutMetrics.medium) {
                    tab("THIS WEEK", value: .thisWeek)
                    tab("ALL TIME", value: .allTime)
                    Spacer()
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.small)
                .padding(.bottom, LayoutMetrics.small)

                // Two swipeable pages, in sync with the tabs above.
                TabView(selection: $window) {
                    page(entries: weekEntries, loading: weekLoading)
                        .tag(VibeWindow.thisWeek)
                    page(entries: allTimeEntries, loading: allTimeLoading)
                        .tag(VibeWindow.allTime)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Vibe leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await loadAll() }
            .fullScreenCover(item: $selectedUserId) { wrapper in
                UserProfileView(userId: wrapper.id, onDismiss: { selectedUserId = nil })
                    .environment(store)
            }
        }
    }

    private func tab(_ title: String, value: VibeWindow) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { window = value }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(window == value ? AppPalette.textStrong : AppPalette.textFaint)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    @ViewBuilder
    private func page(entries: [VibeRankEntry], loading: Bool) -> some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: LayoutMetrics.xSmall) {
                GradientFlameIcon(size: 40, stroked: true)
                Text("No vibes yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
                Text("Once people start vibing fits, the ranking shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.xLarge)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: LayoutMetrics.small) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(rank: index + 1, entry: entry)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.vertical, LayoutMetrics.medium)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(rank: Int, entry: VibeRankEntry) -> some View {
        Button {
            selectedUserId = IdentifiableUUID(id: entry.profile.id)
        } label: {
            HStack(spacing: 0) {
                // The big rank number, with the bust laid on top of its right
                // edge (negative spacing = overlap; zIndex keeps the bust above).
                HStack(spacing: -26) {
                    Text("\(rank)")
                        .font(.system(size: 86, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.textStrong)
                    VibesLeaderboardBust(profile: entry.profile, avatarSize: 86)
                        .zIndex(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    GradientFlameIcon(size: 22, stroked: false)
                    Text("\(entry.count)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppPalette.textStrong)
                }
            }
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func loadAll() async {
        async let week = VibesService.leaderboard(window: .thisWeek)
        async let all = VibesService.leaderboard(window: .allTime)
        let loaded = await (week, all)
        await MainActor.run {
            weekEntries = loaded.0; weekLoading = false
            allTimeEntries = loaded.1; allTimeLoading = false
        }
    }
}

/// Bust rendered to match the profile-header bust EXACTLY, just scaled to
/// `avatarSize` — same proportions and the same -7° rotated highlighter handle
/// (ratios mirror ProfileHeaderMetrics' live bust at avatarSize 132). Uses the
/// bg-removed cut-out when the person has one; otherwise frames their photo.
private struct VibesLeaderboardBust: View {
    let profile: Profile
    var avatarSize: CGFloat = 86

    private var s: CGFloat { avatarSize / 132 }            // liveAvatarSize
    private var frameWidth: CGFloat { 180 * s }            // liveBustFrameWidth
    private var extraHeight: CGFloat { 32 * s }            // liveBustExtraHeight
    private var highlighterFont: CGFloat { 18 * s }        // liveHighlighterFontSize
    private var highlighterOffset: CGFloat { avatarSize * 0.38 } // bustHighlighterOffsetRatio

    var body: some View {
        let accent = ProfileHeaderAccentColor.color(for: profile.headerAccentColor)
        let handle = profile.username.map { "@\($0)" } ?? profile.handle
        ZStack {
            bustImage
            HighlighterUsername(
                text: handle,
                color: accent,
                fontSize: highlighterFont,
                rotation: -7
            )
            .offset(y: highlighterOffset)
            .allowsHitTesting(false)
        }
        .frame(width: frameWidth, height: avatarSize + extraHeight)
    }

    @ViewBuilder
    private var bustImage: some View {
        if let cutout = profile.avatarCutoutUrl, let url = URL(string: cutout) {
            // True transparent bust — fit so hair / shoulders aren't clipped.
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    framedPhoto
                }
            }
            .frame(width: frameWidth, height: avatarSize)
        } else {
            framedPhoto
        }
    }

    // No cut-out → frame the regular photo into a portrait bust crop.
    private var framedPhoto: some View {
        Group {
            if let avatar = profile.avatarUrl, let url = URL(string: avatar) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        initialFill
                    }
                }
            } else {
                initialFill
            }
        }
        .frame(width: avatarSize * 0.84, height: avatarSize)
        .clipShape(RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
        )
    }

    private var initialFill: some View {
        ZStack {
            AppPalette.cardBorder.opacity(0.35)
            Text(profile.initial)
                .font(.system(size: avatarSize * 0.32, weight: .semibold))
                .foregroundStyle(AppPalette.textMuted)
        }
    }
}

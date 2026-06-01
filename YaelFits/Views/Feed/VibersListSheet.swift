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
        .buttonStyle(.plain)
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

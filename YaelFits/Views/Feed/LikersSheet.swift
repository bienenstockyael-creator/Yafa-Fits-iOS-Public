import SwiftUI

struct LikersSheet: View {
    let outfitId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(OutfitStore.self) private var store
    @State private var profiles: [Profile] = []
    @State private var isLoading = true
    @State private var selectedUserId: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if profiles.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        Spacer()
                        AppIcon(glyph: .heart, size: 36, color: AppPalette.textFaint)
                        Text("No likes yet")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                        Spacer()
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(profiles) { profile in
                                row(profile)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Liked by")
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
            .fullScreenCover(item: $selectedUserId) { userId in
                UserProfileView(userId: userId, onDismiss: { selectedUserId = nil })
                    .environment(store)
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        Button {
            selectedUserId = profile.id
        } label: {
        HStack(spacing: LayoutMetrics.small) {
            AvatarView(
                url: profile.avatarUrl,
                initial: profile.initial,
                size: 36,
                shadowRadius: 2,
                shadowY: 1
            )
            VStack(alignment: .leading, spacing: 2) {
                // Instagram-style list row: username primary, display name
                // secondary. If no username is set, fall back to display
                // name on the primary line and hide the secondary.
                if let username = profile.username, !username.isEmpty {
                    Text(username)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                    if let dn = profile.displayName, !dn.isEmpty {
                        Text(dn)
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textFaint)
                    }
                } else {
                    Text(profile.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.vertical, LayoutMetrics.xSmall)
        .contentShape(Rectangle())
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func load() async {
        let result = (try? await SocialService.getLikersForOutfit(outfitId)) ?? []
        await MainActor.run {
            profiles = result
            isLoading = false
        }
    }
}

import SwiftUI

struct LikersSheet: View {
    let outfitId: String

    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [Profile] = []
    @State private var isLoading = true

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
        }
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: LayoutMetrics.small) {
            AvatarView(
                url: profile.avatarUrl,
                initial: profile.initial,
                size: 36,
                shadowRadius: 2,
                shadowY: 1
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                if let username = profile.username, !username.isEmpty {
                    Text("@\(username)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.vertical, LayoutMetrics.xSmall)
    }

    private func load() async {
        let result = (try? await SocialService.getLikersForOutfit(outfitId)) ?? []
        await MainActor.run {
            profiles = result
            isLoading = false
        }
    }
}

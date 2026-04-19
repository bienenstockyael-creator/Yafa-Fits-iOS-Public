import SwiftUI

struct FollowListSheet: View {
    let title: String
    let userIds: [UUID]
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [UUID: Profile] = [:]
    @State private var isLoading = true
    @State private var selectedUserId: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if userIds.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        Text("No \(title.lowercased()) yet")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(userIds, id: \.self) { userId in
                                userRow(userId)
                            }
                        }
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(.white)
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
            .task { await loadProfiles() }
            .sheet(item: $selectedUserId) { userId in
                UserProfileSheet(userId: userId)
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.white)
            }
        }
    }

    private func userRow(_ userId: UUID) -> some View {
        let profile = profiles[userId]
        return Button {
            selectedUserId = userId
        } label: {
            HStack(spacing: LayoutMetrics.small) {
                AvatarView(
                    url: profile?.avatarUrl,
                    initial: profile?.initial ?? "?",
                    size: 40,
                    shadowRadius: 2,
                    shadowY: 1
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.displayLabel ?? "User")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                    if let username = profile?.username {
                        Text("@\(username)")
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.vertical, LayoutMetrics.xSmall)
        }
        .buttonStyle(.plain)
    }

    private func loadProfiles() async {
        guard !userIds.isEmpty else {
            isLoading = false
            return
        }
        let fetched: [Profile] = (try? await supabase
            .from("profiles")
            .select()
            .in("id", values: userIds.map(\.uuidString))
            .execute()
            .value) ?? []
        await MainActor.run {
            profiles = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            isLoading = false
        }
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

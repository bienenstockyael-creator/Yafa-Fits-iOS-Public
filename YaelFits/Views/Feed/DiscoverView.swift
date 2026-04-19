import SwiftUI

struct DiscoverView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var suggestions: [Profile] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedProfile: Profile?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                resultsList
            }
            .background(.white)
            .navigationTitle("Find Your People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .sheet(item: $selectedProfile) { profile in
                UserProfileSheet(userId: profile.id)
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.white)
                    .presentationCornerRadius(20)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .search, size: 14, color: AppPalette.textFaint)

            TextField("", text: $query, prompt: Text("Search by username").foregroundStyle(AppPalette.textFaint))
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { performSearch() }
                .onChange(of: query) { _, newValue in
                    // Debounced search
                    searchTask?.cancel()
                    guard !newValue.isEmpty else {
                        results = []
                        hasSearched = false
                        return
                    }
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        performSearch()
                    }
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    hasSearched = false
                } label: {
                    AppIcon(glyph: .xmark, size: 12, color: AppPalette.textFaint)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.vertical, LayoutMetrics.xSmall)
    }

    private var displayedProfiles: [Profile] {
        let base = query.isEmpty ? suggestions : results
        // Deduplicate by id, exclude own profile
        var seen = Set<UUID>()
        return base.filter { seen.insert($0.id).inserted && $0.id != store.userId }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: LayoutMetrics.xSmall) {
                if isSearching {
                    ProgressView().padding(.top, LayoutMetrics.xLarge)
                } else if hasSearched && results.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        AppIcon(glyph: .search, size: 24, color: AppPalette.textFaint.opacity(0.5))
                        Text("No users found")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppPalette.textMuted)
                        Text("Try a different username")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    .padding(.top, LayoutMetrics.xLarge)
                } else {
                    if query.isEmpty && !suggestions.isEmpty {
                        Text("PEOPLE ON YAFA")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LayoutMetrics.screenPadding)
                            .padding(.top, LayoutMetrics.xSmall)
                    }
                    ForEach(displayedProfiles) { profile in
                        userRow(profile)
                    }
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.xxSmall)
            .padding(.bottom, LayoutMetrics.large)
        }
        .scrollIndicators(.hidden)
        .task {
            // Load all users as suggestions on appear
            guard suggestions.isEmpty else { return }
            if let all = try? await SocialService.searchProfiles(query: "") {
                await MainActor.run { suggestions = all }
            }
        }
    }

    private func userRow(_ profile: Profile) -> some View {
        let isFollowing = store.followingIds.contains(profile.id)
        let isOwnProfile = profile.id == store.userId

        return HStack(spacing: LayoutMetrics.xSmall) {
            // Tapping avatar or name opens their profile
            Button {
                if !isOwnProfile { selectedProfile = profile }
            } label: {
                HStack(spacing: LayoutMetrics.xSmall) {
                    AvatarView(url: profile.avatarUrl, initial: profile.initial, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                        if let username = profile.username, username != profile.displayName {
                            Text("@\(username)")
                                .font(.system(size: 11))
                                .foregroundStyle(AppPalette.textMuted)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Follow button (don't show for yourself)
            if !isOwnProfile {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.toggleFollow(profile.id)
                    }
                } label: {
                    Text(isFollowing ? "FOLLOWING" : "FOLLOW")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(isFollowing ? AppPalette.textMuted : AppPalette.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .appCapsule(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(LayoutMetrics.xSmall)
        .appCard(cornerRadius: 16, shadowRadius: 4, shadowY: 2)
    }

    private func performSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true

        Task {
            let found = (try? await SocialService.searchProfiles(query: query)) ?? []
            await MainActor.run {
                results = found
                isSearching = false
                hasSearched = true
            }
        }
    }
}

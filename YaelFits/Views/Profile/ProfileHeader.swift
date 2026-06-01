import PhotosUI
import SwiftUI

/// The header that sits above the archive grid when the profile and
/// archive are unified into a single screen. Scrolls naturally with
/// the grid (no sticky behavior). Hidden on the calendar view via the
/// `OutfitGridView` itself simply not rendering this.
///
/// Username and bio are read-only here — editing lives in the settings
/// sheet (`ProfileView`). The avatar IS tappable: same `PhotosPicker`
/// + crop flow as `ProfileView.avatarSection` so users can change it
/// without opening settings.
struct ProfileHeader: View {
    @Environment(OutfitStore.self) private var store
    @Environment(AuthManager.self) private var auth

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var pendingCropImage: IdentifiableImage?
    @State private var followerIds: [UUID] = []
    @State private var showFollowers = false
    @State private var vibesReceived: Int = 0

    private var displayName: String {
        let profile = store.currentProfile
        if let name = profile?.displayName, !name.isEmpty { return name }
        if let username = profile?.username, !username.isEmpty { return username }
        return "You"
    }

    private var bio: String? {
        guard let bio = store.currentProfile?.bio, !bio.isEmpty else { return nil }
        return bio
    }

    private var outfitCount: Int { store.sortedOutfits.count }

    var body: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            avatar
                .padding(.top, LayoutMetrics.small)

            Text(displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.top, LayoutMetrics.xxSmall)

            if let bio {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.large)
            }

            statsRow
                .padding(.top, LayoutMetrics.xxSmall)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, LayoutMetrics.medium)
        .task {
            guard let userId = store.userId else { return }
            async let frsTask = (try? await SocialService.getFollowerIds(userId: userId)) ?? []
            async let vibesTask = VibesService.receivedCount(userId: userId)
            let frs = await frsTask
            let vibes = await vibesTask
            await MainActor.run {
                followerIds = Array(frs)
                vibesReceived = vibes
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    pendingCropImage = IdentifiableImage(image: image)
                }
            }
        }
        .fullScreenCover(item: $pendingCropImage) { wrapper in
            AvatarCropView(image: wrapper.image) { croppedImage in
                pendingCropImage = nil
                selectedPhoto = nil
                avatarImage = croppedImage
                Task { await uploadAvatar(croppedImage) }
            } onCancel: {
                pendingCropImage = nil
                selectedPhoto = nil
            }
        }
        .sheet(isPresented: $showFollowers) {
            FollowListSheet(title: "Followers", userIds: followerIds)
                .environment(store)
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.groupedBackground)
        }
    }

    private var avatar: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            ZStack {
                avatarContent
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    .appCircle(shadowRadius: 10, shadowY: 4)

                if isUploadingAvatar {
                    Circle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 88, height: 88)
                    ProgressView()
                        .tint(.white)
                } else {
                    // Camera icon pinned to the bottom-right of the avatar
                    // ring — same affordance pattern as the settings
                    // ProfileView, just sized to match the larger 88pt
                    // avatar in the header.
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            AppIcon(glyph: .camera, size: 11, color: .white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(AppPalette.textPrimary))
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        }
                    }
                    .frame(width: 88, height: 88)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let urlString = store.currentProfile?.avatarUrl,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    initialFallback
                }
            }
        } else {
            initialFallback
        }
    }

    private var initialFallback: some View {
        let initial = String(displayName.prefix(1)).uppercased()
        return ZStack {
            // Match the gradient fallback from `AvatarView` so users
            // without a profile photo get a consistent look across
            // every surface they appear on.
            AvatarGradients.gradient(for: initial)
            Text(initial)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
        }
    }

    private var statsRow: some View {
        HStack(spacing: LayoutMetrics.small) {
            statSegment(count: outfitCount, label: outfitCount == 1 ? "outfit" : "outfits")

            Text("·")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textFaint)

            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                showFollowers = true
            } label: {
                statSegment(count: followerIds.count, label: followerIds.count == 1 ? "follower" : "followers")
            }
            .buttonStyle(.plain)

            if vibesReceived > 0 {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textFaint)

                statSegment(
                    count: vibesReceived,
                    label: vibesReceived == 1 ? "vibe" : "vibes"
                )
            }
        }
    }

    private func statSegment(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textMuted)
        }
    }

    private func uploadAvatar(_ image: UIImage) async {
        guard let userId = auth.userId else { return }
        await MainActor.run { isUploadingAvatar = true }
        do {
            let avatarURLString = try await AvatarService.uploadAvatar(image, userId: userId)
            await MainActor.run {
                store.currentProfile?.avatarUrl = avatarURLString
                if let profile = store.currentProfile {
                    LocalCache.saveProfile(profile, userId: userId)
                }
                isUploadingAvatar = false
            }
        } catch {
            await MainActor.run { isUploadingAvatar = false }
        }
    }
}

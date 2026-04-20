import PhotosUI
import SwiftUI

struct ProfileView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(AuthManager.self) private var auth

    @State private var username = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var showSignOutConfirmation = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var uploadError: String?
    @State private var pendingCropImage: IdentifiableImage?
    @State private var followerIds: [UUID] = []
    @State private var followingIds: [UUID] = []
    @State private var showFollowers = false
    @State private var showFollowing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: LayoutMetrics.uploadTopInset)

                VStack(spacing: LayoutMetrics.large) {
                    avatarSection
                    formSection
                    saveButton
                    statsSection
                    signOutSection
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.bottomOverlayInset)
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(AppPalette.pageBackground)
        .onAppear { loadProfile() }
        .alert("Sign out?", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
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
    }

    private var avatarSection: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack {
                    avatarContent
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .appCircle(shadowRadius: 8, shadowY: 4)

                    if isUploadingAvatar {
                        Circle()
                            .fill(Color.black.opacity(0.3))
                            .frame(width: 72, height: 72)
                        ProgressView()
                            .tint(.white)
                    } else {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                AppIcon(glyph: .camera, size: 10, color: .white)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(AppPalette.textPrimary))
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                            }
                        }
                        .frame(width: 72, height: 72)
                    }
                }
            }
            .buttonStyle(.plain)

            if let uploadError {
                Text(uploadError)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if let email = auth.userEmail {
                Text(email)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
            }
        }
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
        ZStack {
            Color.clear
            Text(avatarInitial)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
        }
    }

    private var formSection: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            fieldRow(label: "USERNAME", text: $displayName, placeholder: "Choose a username")
            bioRow
        }
    }

    private func fieldRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)

            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(AppPalette.textFaint))
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        }
    }

    private var bioRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BIO")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)

            TextField("", text: $bio, prompt: Text("Tell us about yourself").foregroundStyle(AppPalette.textFaint), axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .lineLimit(3...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        }
    }

    private var saveButton: some View {
        Button {
            saveProfile()
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                } else if showSaved {
                    HStack(spacing: 6) {
                        AppIcon(glyph: .check, size: 14, color: AppPalette.textPrimary)
                        Text("SAVED")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                } else {
                    Text("SAVE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private var statsSection: some View {
        VStack(spacing: LayoutMetrics.medium) {
            HStack(spacing: 0) {
                statItem(count: store.sortedOutfits.count, label: "Outfits")
                statItem(count: store.likedIds.count, label: "Liked")
                statItem(count: store.savedIds.count, label: "Saved")
            }

            HStack(spacing: 0) {
                Button { showFollowers = true } label: {
                    statItem(count: followerIds.count, label: "Followers")
                }.buttonStyle(.plain)
                Button { showFollowing = true } label: {
                    statItem(count: followingIds.count, label: "Following")
                }.buttonStyle(.plain)
            }
        }
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
        .task {
            guard let userId = store.userId else { return }
            let frs = (try? await SocialService.getFollowerIds(userId: userId)) ?? []
            let fng = (try? await SocialService.getFollowingIds(userId: userId)) ?? []
            await MainActor.run {
                followerIds = Array(frs)
                followingIds = Array(fng)
            }
        }
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(AppPalette.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var signOutSection: some View {
        Button {
            showSignOutConfirmation = true
        } label: {
            Text("SIGN OUT")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    private var avatarInitial: String {
        let name = displayName.isEmpty ? (username.isEmpty ? (auth.userEmail ?? "U") : username) : displayName
        return String(name.prefix(1)).uppercased()
    }

    private func loadProfile() {
        guard let profile = store.currentProfile else { return }
        username = profile.username ?? ""
        displayName = profile.displayName ?? ""
        bio = profile.bio ?? ""
        // Restore avatar from URL if we don't have a local image
        if avatarImage == nil, let urlString = profile.avatarUrl, let url = URL(string: urlString) {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        avatarImage = image
                    }
                }
            }
        }
    }

    private func uploadAvatar(_ image: UIImage) async {
        guard let userId = auth.userId else { return }

        await MainActor.run {
            isUploadingAvatar = true
            uploadError = nil
        }

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
            await MainActor.run {
                uploadError = error.localizedDescription
                isUploadingAvatar = false
            }
        }
    }

    private func saveProfile() {
        guard let userId = auth.userId else { return }
        isSaving = true
        showSaved = false

        Task {
            let profile = Profile(
                id: userId,
                username: displayName.isEmpty ? nil : displayName,
                displayName: displayName.isEmpty ? nil : displayName,
                avatarUrl: store.currentProfile?.avatarUrl,
                bio: bio.isEmpty ? nil : bio
            )
            try? await SocialService.updateProfile(profile)
            LocalCache.saveProfile(profile, userId: userId)
            await MainActor.run {
                store.currentProfile = profile
                isSaving = false
                showSaved = true
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                showSaved = false
            }
        }
    }

    private func signOut() {
        if let userId = auth.userId {
            LocalCache.clearAll(userId: userId)
        }
        Task {
            try? await auth.signOut()
        }
    }
}

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

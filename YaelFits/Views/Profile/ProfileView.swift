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
    /// Local input + state for the phone-management row. Phone
    /// has its own save flow (separate write to `phone_e164_hash`)
    /// because the main "Save" button doesn't touch hashes.
    @State private var phoneInput: String = ""
    @State private var isSavingPhone = false
    @State private var phoneError: String?
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
    @State private var showSavedSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: LayoutMetrics.uploadTopInset)

                VStack(spacing: LayoutMetrics.large) {
                    avatarSection
                    formSection
                    saveButton
                    phoneSection
                    statsSection
                    signOutSection
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.screenPadding)
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
            // Match the gradient fallback from `AvatarView` so users
            // without a profile photo get a consistent look across
            // every surface they appear on.
            AvatarGradients.gradient(for: avatarInitial)
            Text(avatarInitial)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
        }
    }

    private var formSection: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            // Two distinct fields, Instagram-style:
            //   NAME     → free text, shown on cards/headers
            //   USERNAME → sanitized handle, used for mentions/URLs/search
            // The previous version of this screen had a single field
            // labelled "USERNAME" that was actually bound to $displayName,
            // which left users with `display_name` populated but
            // `username` null — and a stuck onboarding sheet.
            fieldRow(label: "NAME", text: $displayName, placeholder: "Your name")
            fieldRow(label: "USERNAME", text: $username, placeholder: "Choose a username")
            bioRow
        }
        .onChange(of: username) { _, newValue in
            // Live-sanitize as the user types so the saved value matches
            // what they see (lowercase, alphanumeric + . + _).
            let sanitized = Profile.sanitizeUsername(newValue)
            if sanitized != newValue { username = sanitized }
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

    /// Phone-number management row. The profile only stores the
    /// SHA-256 hash, not the original number, so when a phone is
    /// already saved we can show "Added" + a Remove action but
    /// can't display the digits. Adding a new number from this
    /// screen overwrites the existing hash.
    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PHONE NUMBER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)

            if store.currentProfile?.phoneE164Hash != nil {
                phoneSavedRow
            } else {
                phoneEntryRow
            }

            if let phoneError {
                Text(phoneError)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.top, 2)
            }
        }
    }

    private var phoneSavedRow: some View {
        HStack(spacing: 12) {
            AppIcon(glyph: .check, size: 14, color: AppPalette.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Phone number saved")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppPalette.textStrong)
                Text("Friends with your number can find you on Yafa.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
            }
            Spacer(minLength: 8)
            Button {
                Task { await removePhone() }
            } label: {
                if isSavingPhone {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                        .controlSize(.small)
                } else {
                    Text("Remove")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .disabled(isSavingPhone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
    }

    private var phoneEntryRow: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $phoneInput,
                prompt: Text("Phone number").foregroundStyle(AppPalette.textFaint)
            )
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textStrong)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)

            Button {
                Task { await savePhone() }
            } label: {
                Group {
                    if isSavingPhone {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 64, height: 44)
                .background(
                    Capsule().fill(
                        canSavePhone
                            ? AppPalette.textStrong
                            : AppPalette.textStrong.opacity(0.35)
                    )
                )
            }
            .disabled(!canSavePhone)
        }
    }

    private var canSavePhone: Bool {
        !isSavingPhone && PhoneNumber.normalizeToE164(phoneInput) != nil
    }

    private func savePhone() async {
        guard let userId = store.userId,
              let hash = ContactsService.hashOwnPhoneNumber(phoneInput)
        else { return }

        isSavingPhone = true
        phoneError = nil
        do {
            try await SocialService.updatePhoneHash(userId: userId, hash: hash)
            await MainActor.run {
                store.currentProfile?.phoneE164Hash = hash
                phoneInput = ""
                isSavingPhone = false
            }
        } catch {
            await MainActor.run {
                phoneError = "Couldn't save. Try again."
                isSavingPhone = false
            }
        }
    }

    private func removePhone() async {
        guard let userId = store.userId else { return }
        isSavingPhone = true
        phoneError = nil
        do {
            try await SocialService.updatePhoneHash(userId: userId, hash: nil)
            await MainActor.run {
                store.currentProfile?.phoneE164Hash = nil
                isSavingPhone = false
            }
        } catch {
            await MainActor.run {
                phoneError = "Couldn't remove. Try again."
                isSavingPhone = false
            }
        }
    }

    private var hasProfileChanges: Bool {
        let profile = store.currentProfile
        let origDisplay = profile?.displayName ?? ""
        let origUsername = profile?.username ?? ""
        let origBio = profile?.bio ?? ""
        return displayName != origDisplay
            || username != origUsername
            || bio != origBio
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
                        .font(.system(size: hasProfileChanges ? 12 : 11, weight: hasProfileChanges ? .semibold : .medium))
                        .tracking(1.5)
                        .foregroundStyle(hasProfileChanges ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .appCapsule(shadowRadius: hasProfileChanges ? 6 : 0, shadowY: hasProfileChanges ? 3 : 0)
            .animation(.easeInOut(duration: 0.2), value: hasProfileChanges)
        }
        .buttonStyle(.plain)
        .disabled(isSaving || (!hasProfileChanges && !showSaved))
    }

    private var statsSection: some View {
        VStack(spacing: LayoutMetrics.medium) {
            HStack(spacing: 0) {
                statItem(count: store.sortedOutfits.count, label: "Outfits")
                statItem(count: store.likedIds.count, label: "Liked")
                Button { showSavedSheet = true } label: {
                    statItem(count: store.savedIds.count, label: "Saved")
                }
                .buttonStyle(.plain)
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
        .sheet(isPresented: $showSavedSheet) {
            SavedOutfitsSheet()
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
            // Use the LOCAL `username` state (not the cached store value)
            // so user edits to the username field actually persist.
            let sanitizedUsername = Profile.sanitizeUsername(username)
            let profile = Profile(
                id: userId,
                username: sanitizedUsername.isEmpty ? nil : sanitizedUsername,
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

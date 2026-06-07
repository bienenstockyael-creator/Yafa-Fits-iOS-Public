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
    /// Vibes + 3D credit balances surfaced under the stats row.
    /// Refreshed in `.task` alongside follower/following counts.
    @State private var vibesReceived: Int = 0
    @State private var vibesRemainingThisWeek: Int = 0
    @State private var freeCredits3D: Int = 0
    /// When the next free-credit refresh is due. Non-nil only
    /// after the user has consumed at least one free credit (the
    /// 30-day clock starts on first consumption). Combined with
    /// `freeCredits3D == 0`, we surface "credits refresh in X
    /// days" on the chip so the user has a concrete expectation
    /// instead of an opaque empty balance.
    @State private var creditsResetAt: Date?
    @State private var showVibersOnMe = false
    /// Host that drives the credit-chip explainer modals at root
    /// level (rendered globally in `YaelFitsApp`, so they sit
    /// above the Settings sheet and stay viewport-centered).
    @Environment(VibesEffectHost.self) private var vibesHost

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: LayoutMetrics.uploadTopInset)

                VStack(spacing: LayoutMetrics.large) {
                    avatarSection
                    formSection
                    phoneSection
                    saveButton
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
        // Credit-chip explainer modal — mounted INSIDE the sheet
        // (rather than at the app root) because SwiftUI sheets
        // present in a separate hosting context. A root-level
        // overlay would render BELOW the sheet, hidden. Mounting
        // it here puts it in the sheet's window so it appears
        // above the Settings content. Backdrop `.ignoresSafeArea()`
        // extends it past the sheet's grab-handle area.
        .overlay { InfoExplainerModal() }
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

            if store.currentProfile?.phoneIsSet == true {
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

    /// Phone-entry text field only — no inline "Save" button.
    /// The main Settings save button saves the phone too (see
    /// `saveProfile()`).
    private var phoneEntryRow: some View {
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
    }

    // `savePhone()` and `canSavePhone` removed — phone saving is
    // now part of the main `saveProfile()` flow, triggered by the
    // single Settings save button. The `removePhone()` helper
    // below is still used by the saved-row's Remove action.

    private func removePhone() async {
        guard let userId = store.userId else { return }
        isSavingPhone = true
        phoneError = nil
        do {
            try await SocialService.updatePhoneHash(userId: userId, hash: nil)
            await MainActor.run {
                store.currentProfile?.phoneE164Hash = nil
                store.currentProfile?.phoneIsSet = false
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
        // Phone counts as a change if there's text in the field
        // AND it parses to a valid E.164 number. Empty input or
        // garbage doesn't enable the save button.
        let hasPhoneToSave = !phoneInput.isEmpty
            && PhoneNumber.normalizeToE164(phoneInput) != nil
        return displayName != origDisplay
            || username != origUsername
            || bio != origBio
            || hasPhoneToSave
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
                if vibesReceived > 0 {
                    Button {
                        Analytics.log("profile_vibes_stat_tapped")
                        showVibersOnMe = true
                    } label: {
                        statItem(count: vibesReceived, label: "Vibes")
                    }.buttonStyle(.plain)
                }
            }

            // Credits — vibes left to give this week + free 3D
            // gens. Now tappable: each chip opens an explainer
            // modal describing what that credit system is.
            HStack(spacing: LayoutMetrics.small) {
                Button {
                    Analytics.log("profile_vibes_credit_chip_tapped")
                    vibesHost.showInfoModal(.vibes)
                } label: {
                    creditChip(
                        icon: .flame,
                        value: "\(vibesRemainingThisWeek)",
                        label: vibesRemainingThisWeek == 1
                            ? "vibe left"
                            : "vibes left this week"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    Analytics.log("profile_3d_credit_chip_tapped")
                    vibesHost.showInfoModal(.gen3D)
                } label: {
                    creditChip(
                        icon: .sparkles,
                        value: "\(freeCredits3D)",
                        label: gen3DChipLabel
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, LayoutMetrics.xSmall)
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
        .sheet(isPresented: $showVibersOnMe) {
            if let userId = store.userId {
                VibersListSheet(source: .user(userId))
                    .environment(store)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppPalette.groupedBackground)
            }
        }
        .task {
            guard let userId = store.userId else { return }
            async let frsTask: [UUID] = {
                let ids = (try? await SocialService.getFollowerIds(userId: userId)) ?? []
                return Array(ids)
            }()
            async let fngTask: [UUID] = {
                let ids = (try? await SocialService.getFollowingIds(userId: userId)) ?? []
                return Array(ids)
            }()
            async let receivedTask = VibesService.receivedCount(userId: userId)
            async let remainingTask = VibesService.remainingThisWeek()
            async let balanceTask: CreditService.Balance? = try? await CreditService.shared.balance(userId: userId)

            let frs = await frsTask
            let fng = await fngTask
            let received = await receivedTask
            let remaining = await remainingTask
            let balance = await balanceTask

            // Parse `gen_credits_reset_at` (Supabase returns an
            // ISO-8601 string). We try the two most common shapes
            // — with and without fractional seconds — and bail to
            // nil if neither matches, so a future server format
            // change degrades to "no countdown shown" rather than
            // a crash.
            let resetDate: Date? = balance?.gen_credits_reset_at.flatMap { raw in
                let withFraction = ISO8601DateFormatter()
                withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = withFraction.date(from: raw) { return d }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: raw)
            }

            await MainActor.run {
                followerIds = frs
                followingIds = fng
                vibesReceived = received
                vibesRemainingThisWeek = remaining
                freeCredits3D = balance?.gen_credits_free_balance ?? 0
                creditsResetAt = resetDate
            }
        }
    }

    /// Label for the 3D-credit chip. When the user still has
    /// credits, just shows "free 3D gen(s)". When they hit zero
    /// AND we know the reset date AND it's in the future, swap
    /// in a concrete countdown so the user has a finite wait
    /// expectation instead of an opaque "0" with no recovery
    /// hint. The free-credit window starts on first consumption
    /// (server sets `gen_credits_reset_at = now() + 30 days` on
    /// first debit), so this label only renders for users who've
    /// actually generated something and run out.
    private var gen3DChipLabel: String {
        if freeCredits3D > 0 {
            return freeCredits3D == 1 ? "free 3D gen" : "free 3D gens"
        }
        guard let reset = creditsResetAt, reset > Date() else {
            return "free 3D gens"
        }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: reset).day ?? 0
        if days <= 0 {
            // Less than a day away — refresh imminent; let them
            // tap "Generate" and the server-side
            // `refresh_free_credits_if_due` will fire.
            return "refresh soon"
        }
        if days == 1 {
            return "refresh in 1 day"
        }
        return "refresh in \(days) days"
    }

    private func creditChip(
        icon: AppIconGlyph,
        value: String,
        label: String
    ) -> some View {
        HStack(spacing: 6) {
            AppIcon(glyph: icon, size: 14, color: AppPalette.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
        }
        .padding(.horizontal, LayoutMetrics.small)
        .padding(.vertical, 6)
        .appCard(cornerRadius: 12, shadowRadius: 3, shadowY: 1)
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
        phoneError = nil

        Task {
            // 1. Save phone hash separately if there's a valid
            //    new phone in the input field. Phone is stored as
            //    a SHA-256 hash via a dedicated endpoint, not as a
            //    Profile field, so it needs its own write.
            if !phoneInput.isEmpty,
               let hash = ContactsService.hashOwnPhoneNumber(phoneInput) {
                do {
                    try await SocialService.updatePhoneHash(userId: userId, hash: hash)
                    await MainActor.run {
                        store.currentProfile?.phoneE164Hash = hash
                        store.currentProfile?.phoneIsSet = true
                        phoneInput = ""
                    }
                } catch {
                    await MainActor.run {
                        phoneError = "Couldn't save phone. Try again."
                    }
                }
            }

            // 2. Save profile fields. Use the LOCAL `username` state
            //    (not the cached store value) so user edits to the
            //    username field actually persist.
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
                // Preserve the phone hash that was just written
                // (or any pre-existing hash) — the Profile init
                // above doesn't carry it.
                var updated = profile
                updated.phoneE164Hash = store.currentProfile?.phoneE164Hash
                store.currentProfile = updated
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

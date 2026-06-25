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
    @State private var showVibesLeaderboard = false
    @State private var vibesReceived: Int = 0
    /// Drives presentation of the photo picker. Replaces the
    /// previous "PhotosPicker wraps the avatar" pattern so the
    /// avatar tap can conditionally open the customize sheet
    /// instead (for users who already have a photo).
    @State private var showPhotoPicker = false
    /// Customize sheet visibility. Set to true after a fresh
    /// photo upload completes (no-photo flow) OR when the user
    /// taps the avatar and a photo already exists. The sheet
    /// owns its own picker + cropper for the in-sheet
    /// "change photo" flow, so it doesn't need to be dismissed
    /// and re-presented around that flow.
    @State private var showCustomizeSheet = false
    /// True briefly while we fetch the current avatar URL into
    /// a local UIImage so the customize sheet can render it.
    /// Drives a small dim+spinner on the avatar so the user
    /// understands the tap was received.
    @State private var isLoadingAvatarForSheet = false
    /// The pre-crop, full-frame image the user picked. Held in
    /// memory only for the current session. Passed to the
    /// customize sheet so the `bust` style runs FAL on the
    /// ORIGINAL pixels (with full shoulders / chest) rather than
    /// on `avatarImage` — which is a circle-clipped PNG out of
    /// `AvatarCropView` and would force the cutout into a
    /// disc-shaped silhouette.
    @State private var originalImage: UIImage?

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

    /// The user's chosen header style, falling back to `.minimal`
    /// for legacy profiles that pre-date the customization
    /// feature. Read here so both the avatar block layout and
    /// the username/highlighter rendering stay in sync.
    private var headerStyle: ProfileHeaderStyle {
        ProfileHeaderStyle.parse(store.currentProfile?.headerStyle)
    }

    private var accentColor: Color {
        ProfileHeaderAccentColor.color(for: store.currentProfile?.headerAccentColor)
    }

    private var username: String? {
        store.currentProfile?.username
    }

    var body: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            avatarBlock
                .padding(.top, LayoutMetrics.small)
                // Clamp Dynamic Type for the header — the bust
                // highlighter scales internally via
                // `@ScaledMetric`, and at higher accessibility
                // sizes that scaling would push the blob past
                // the fixed bust frame. `.accessibility1` is
                // the sweet spot: a real ~150% bump for users
                // who need it, without breaking the layout.
                .dynamicTypeSize(.large ... .accessibility1)

            // Curved bakes the displayName into the pill;
            // bust bakes it into the highlighter. Either way
            // a second copy below would be a duplicate, so
            // the standalone label only renders for minimal.
            if headerStyle == .minimal {
                Text(displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                    .padding(.top, LayoutMetrics.xxSmall)
            }

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
            // Pre-load the avatar URL into the shared store ONCE
            // so subsequent tab returns render from the cached
            // UIImage instantly instead of dropping back through
            // AsyncImage's `.empty` phase.
            await preloadAvatarIntoStoreIfNeeded()
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fullScreenCover(item: $pendingCropImage) { wrapper in
            AvatarCropView(image: wrapper.image) { croppedImage, _ in
                pendingCropImage = nil
                selectedPhoto = nil
                avatarImage = croppedImage
                // Seed the store cache too so a subsequent tab
                // switch (after the upload completes) renders
                // the new photo instantly instead of re-fetching
                // the Storage URL we just wrote.
                store.currentAvatarImage = croppedImage
                // Keep the pre-crop original so the customize
                // sheet can feed it to FAL for the bust cutout.
                originalImage = wrapper.image
                Task {
                    await uploadAvatar(croppedImage)
                    // Initial-photo flow only: kick the user
                    // into the customize sheet right after the
                    // first upload so "tap edit photo →
                    // customize" reads as one continuous flow.
                    // The in-sheet change-photo path doesn't
                    // hit this — it has its own picker.
                    await MainActor.run {
                        showCustomizeSheet = true
                    }
                }
            } onCancel: {
                pendingCropImage = nil
                selectedPhoto = nil
            }
        }
        .sheet(isPresented: $showCustomizeSheet) {
            if let currentAvatar = avatarImage,
               let username = store.currentProfile?.username,
               !username.isEmpty {
                ProfileHeaderCustomizeSheet(
                    username: username,
                    displayName: displayName,
                    bio: bio,
                    avatarImage: currentAvatar,
                    originalImage: originalImage,
                    existingCutoutURL: store.currentProfile?.avatarCutoutUrl,
                    initialStyle: ProfileHeaderStyle.parse(store.currentProfile?.headerStyle),
                    initialAccentHex: store.currentProfile?.headerAccentColor,
                    onPhotoPicked: { cropped, original in
                        // The customize sheet stays open through
                        // the picker + crop flow. When the user
                        // confirms, the sheet hands us the new
                        // images; we upload + update local state
                        // so the sheet re-renders with the new
                        // avatar in place.
                        avatarImage = cropped
                        originalImage = original
                        Task {
                            await uploadAvatar(cropped)
                        }
                    },
                    onSave: { style, accentHex, cutoutImage in
                        // Cache the fresh cutout locally BEFORE
                        // dismissing the sheet so the bust
                        // renders instantly without a network
                        // round-trip to the Storage URL we're
                        // about to write. For minimal/curved
                        // saves the parameter is nil; we leave
                        // any previously-cached cutout in place
                        // so swapping back to bust later still
                        // hits the local copy.
                        if style == .bust, let cutoutImage {
                            store.currentAvatarCutoutImage = cutoutImage
                        }
                        Task {
                            await saveHeaderCustomization(
                                style: style,
                                accentHex: accentHex,
                                cutoutImage: cutoutImage
                            )
                            await MainActor.run { showCustomizeSheet = false }
                        }
                    },
                    onDismiss: { showCustomizeSheet = false }
                )
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
            }
        }
        .sheet(isPresented: $showFollowers) {
            FollowListSheet(title: "Followers", userIds: followerIds)
                .environment(store)
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
        .sheet(isPresented: $showVibesLeaderboard) {
            VibesLeaderboardSheet()
                .environment(store)
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
    }

    /// Wraps `avatar` with style-specific decoration:
    ///   * `.minimal` — just the avatar button.
    ///   * `.curved`  — adds the accent-colored CurvedUsernamePill
    ///     arcing along the bottom, non-tappable so the underlying
    ///     button still drives the edit-photo flow.
    ///   * `.bust`    — same avatar button; the bust treatment
    ///     (background-removed image) is rendered inside the
    ///     `avatarContent` switch below, the highlighter
    ///     username sits OUTSIDE this block (in the body
    ///     above).
    /// Always sized large enough to contain the bottom-arc pill
    /// so layout doesn't shift when the user swaps styles.
    @ViewBuilder
    private var avatarBlock: some View {
        switch headerStyle {
        case .minimal:
            avatar
        case .curved:
            // Pill keeps the empty-feed avatar-bubble styling
            // (white fill, cardBorder stroke). Accent color
            // only applies to the bust style.
            ZStack {
                avatar
                CurvedUsernamePill(
                    text: displayName,
                    avatarRadius: ProfileHeaderMetrics.liveAvatarSize / 2,
                    fontSize: ProfileHeaderMetrics.liveCurvedFontSize,
                    pillThickness: ProfileHeaderMetrics.liveCurvedPillThickness
                )
                .drawingGroup()
                .allowsHitTesting(false)
            }
            .frame(
                width: ProfileHeaderMetrics.liveAvatarSize + ProfileHeaderMetrics.liveCurvedFramePadding,
                height: ProfileHeaderMetrics.liveAvatarSize + ProfileHeaderMetrics.liveCurvedFramePadding
            )
        case .bust:
            // Highlighter sits centered on the bust (chest /
            // shoulder area), tilted with rounded corners and
            // auto-sized to its 2-line displayName — the Y2K
            // magazine paste-up reference, not a bottom label.
            ZStack {
                avatar
                HighlighterUsername(
                    text: displayName,
                    color: accentColor,
                    fontSize: ProfileHeaderMetrics.liveHighlighterFontSize,
                    rotation: ProfileHeaderMetrics.highlighterRotation
                )
                .offset(y: ProfileHeaderMetrics.liveAvatarSize * ProfileHeaderMetrics.bustHighlighterOffsetRatio)
                .allowsHitTesting(false)
            }
            .frame(
                width: ProfileHeaderMetrics.liveBustFrameWidth,
                height: ProfileHeaderMetrics.liveAvatarSize + ProfileHeaderMetrics.liveBustExtraHeight
            )
        }
    }

    /// Width of the avatar layer (image + camera overlay) for
    /// the current style. Bust uses a wider frame to give the
    /// cutout's hair / shoulders room; circular styles stay
    /// square. Both the image and the camera-icon overlay
    /// need the same width or the icon floats off-center
    /// from the image's right edge.
    private var avatarLayerWidth: CGFloat {
        headerStyle == .bust
            ? ProfileHeaderMetrics.liveBustFrameWidth
            : ProfileHeaderMetrics.liveAvatarSize
    }

    private var avatar: some View {
        Button(action: handleAvatarTap) {
            ZStack {
                avatarImageLayer

                if isUploadingAvatar || isLoadingAvatarForSheet {
                    Circle()
                        .fill(Color.black.opacity(0.3))
                        .frame(
                            width: ProfileHeaderMetrics.liveAvatarSize,
                            height: ProfileHeaderMetrics.liveAvatarSize
                        )
                    ProgressView()
                        .tint(.white)
                } else {
                    // Camera-icon edit affordance, pinned to the
                    // TOP-right of the avatar. Top instead of
                    // bottom because the `bust` style's
                    // highlighter blob sits across the chest and
                    // would otherwise cover the icon — keeping
                    // it top-right across all styles means the
                    // edit affordance lives in one consistent
                    // spot regardless of which layout the user
                    // has picked.
                    VStack {
                        HStack {
                            Spacer()
                            AppIcon(glyph: .camera, size: 11, color: .white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(AppPalette.textPrimary))
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        }
                        Spacer()
                    }
                    .frame(width: avatarLayerWidth, height: ProfileHeaderMetrics.liveAvatarSize)
                }
            }
        }
        .buttonStyle(SolidPressButtonStyle())
        .accessibilityLabel(avatarImage == nil ? "Add profile photo" : "Edit profile photo")
    }

    /// Tap on the avatar / camera icon. Branches on whether the
    /// user already has a profile picture:
    ///
    /// * NO photo yet → straight to the system photo picker.
    ///   After the user picks + crops + the upload completes, we
    ///   route to the customize sheet so they can choose their
    ///   header style (per the V1 spec: customize is only
    ///   reachable once a photo exists).
    ///
    /// * HAS photo → present the customize sheet directly with
    ///   the existing avatar pre-loaded. The sheet has its own
    ///   "Change photo" button if the user wants to swap the
    ///   image without leaving the flow.
    private func handleAvatarTap() {
        let hasLocalImage = avatarImage != nil
        let hasRemoteURL = !(store.currentProfile?.avatarUrl?.isEmpty ?? true)
        if hasLocalImage {
            showCustomizeSheet = true
            return
        }
        if hasRemoteURL {
            Task { await loadAvatarThenPresentSheet() }
            return
        }
        showPhotoPicker = true
    }

    /// Downloads the avatar from its remote URL into a local
    /// UIImage and then presents the customize sheet. Shows a
    /// spinner overlay on the avatar while the download is in
    /// flight so the user understands their tap was received.
    /// Falls back to the photo picker if the download fails
    /// (rare, but better than silently doing nothing).
    private func loadAvatarThenPresentSheet() async {
        guard let urlString = store.currentProfile?.avatarUrl,
              let url = URL(string: urlString) else {
            await MainActor.run { showPhotoPicker = true }
            return
        }
        await MainActor.run { isLoadingAvatarForSheet = true }
        if let data = try? await URLSession.shared.data(from: url).0,
           let image = UIImage(data: data) {
            await MainActor.run {
                avatarImage = image
                isLoadingAvatarForSheet = false
                showCustomizeSheet = true
            }
        } else {
            await MainActor.run {
                isLoadingAvatarForSheet = false
                showPhotoPicker = true
            }
        }
    }

    /// Bust style strips the circular crop + shadow and renders
    /// the cutout PNG (transparent background). Minimal +
    /// Curved both want the legacy circular treatment with the
    /// `.appCircle` shadow ring.
    @ViewBuilder
    private var avatarImageLayer: some View {
        if headerStyle == .bust {
            // Wider-than-tall frame so the bust cutout has
            // horizontal room for hair / shoulders.
            // `.aspectRatio(.fit)` on the AsyncImage scales the
            // cutout to whichever dimension binds first, with no
            // clipping in either direction.
            bustAvatarContent
                .frame(
                    width: ProfileHeaderMetrics.liveBustFrameWidth,
                    height: ProfileHeaderMetrics.liveAvatarSize
                )
        } else {
            avatarContent
                .frame(
                    width: ProfileHeaderMetrics.liveAvatarSize,
                    height: ProfileHeaderMetrics.liveAvatarSize
                )
                .clipShape(Circle())
                .appCircle(shadowRadius: 10, shadowY: 4)
        }
    }

    /// Renders the bg-removed cutout PNG when one is on file.
    /// Falls back to the regular `avatarContent` (clipped to a
    /// circle so it still looks intentional, just without the
    /// "magazine paste-up" feel) while the cutout is still
    /// being generated server-side. This shouldn't happen in
    /// practice because the customize sheet blocks Save until
    /// the cutout is ready, but the fallback ensures the
    /// profile is never blank.
    @ViewBuilder
    private var bustAvatarContent: some View {
        // Priority: local in-memory cutout (set when the user
        // just saved one from the customize sheet, or once we've
        // fetched the URL into RAM) → remote URL → fall back to
        // the circle-clipped avatar. The local copy is what
        // kills the post-save flash where the user would see
        // the circle for a beat while AsyncImage re-downloads
        // the PNG we literally just uploaded.
        if let localCutoutImage = store.currentAvatarCutoutImage {
            Image(uiImage: localCutoutImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let urlString = store.currentProfile?.avatarCutoutUrl,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    // Genuine load error — fall back to the
                    // circle-clipped avatar so the header is
                    // never empty.
                    avatarContent.clipShape(Circle())
                default:
                    // `.empty` (loading). DON'T show the circle
                    // fallback here: we know a cutout exists on
                    // the profile so the right answer is "the
                    // bust shape" — flashing the circular avatar
                    // mid-load makes it look like the bust style
                    // briefly reverted on every tab return. A
                    // transparent placeholder for the few ms
                    // before the URLCache hit completes reads
                    // as "loading" rather than "wrong silhouette".
                    Color.clear
                }
            }
        } else {
            avatarContent
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private var avatarContent: some View {
        // Priority: locally-picked image (just from the photo
        // picker) → store-cached image (loaded once and reused
        // across tab switches) → AsyncImage fallback for the
        // very first load → gradient-initial fallback. The
        // store cache is what kills the "pp takes longer to
        // appear than the rest of the page" feel on tab return.
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let cached = store.currentAvatarImage {
            Image(uiImage: cached)
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
            .buttonStyle(SolidPressButtonStyle())

            if vibesReceived > 0 {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textFaint)

                // Vibes stat gets the gradient flame icon so the
                // static count visually matches the in-flight
                // particle burst on the VibeButton. Tap → leaderboard.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showVibesLeaderboard = true
                } label: {
                    HStack(spacing: 4) {
                        GradientFlameIcon(size: 24, stroked: true)
                        Text("\(vibesReceived)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                        Text(vibesReceived == 1 ? "vibe" : "vibes")
                            .font(.system(size: 14))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                }
                .buttonStyle(SolidPressButtonStyle())
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

    /// Commits the chosen header style / accent color / cutout
    /// to the profile. If the user selected `bust` and the
    /// customize sheet produced a fresh cutout UIImage, upload
    /// it to Storage first and record the resulting URL.
    /// Optimistically updates the local profile so the header
    /// re-renders in the new style as soon as the sheet
    /// dismisses, even before the server write returns.
    private func saveHeaderCustomization(
        style: ProfileHeaderStyle,
        accentHex: String?,
        cutoutImage: UIImage?
    ) async {
        guard let userId = auth.userId else { return }
        var cutoutURL: String? = store.currentProfile?.avatarCutoutUrl
        if style == .bust, let cutoutImage {
            // Only upload if the cutout is genuinely fresh —
            // re-saving the same bust style shouldn't burn
            // bandwidth uploading the same PNG. We treat a
            // freshly-generated `cutoutImage` from the sheet as
            // the source of truth and overwrite the URL each
            // time bust is saved with a new image.
            if let uploaded = try? await AvatarService.uploadAvatarCutout(cutoutImage, userId: userId) {
                cutoutURL = uploaded
            }
        }
        // Sending a value for every column even when nil is
        // intentional — clears stale accent color when the user
        // switches back to minimal.
        let finalCutoutURL: String? = style == .bust ? cutoutURL : (store.currentProfile?.avatarCutoutUrl)
        try? await SocialService.updateHeaderCustomization(
            userId: userId,
            style: style,
            accentColorHex: accentHex,
            cutoutURL: finalCutoutURL
        )
        await MainActor.run {
            store.currentProfile?.headerStyle = style.rawValue
            store.currentProfile?.headerAccentColor = accentHex
            store.currentProfile?.avatarCutoutUrl = finalCutoutURL
            if let profile = store.currentProfile {
                LocalCache.saveProfile(profile, userId: userId)
            }
        }
    }

    /// Loads the user's avatar AND bust cutout URLs into the
    /// shared `OutfitStore` on first appearance. Both fetches
    /// run in parallel and are individually no-op if the cache
    /// is already populated, so this is safe to re-call. Network
    /// failures are silent: the existing `AsyncImage` fallback
    /// still renders correctly, the user just loses the
    /// cross-tab-instant optimization for that asset this
    /// session.
    private func preloadAvatarIntoStoreIfNeeded() async {
        async let avatarTask: Void = preload(
            url: store.currentProfile?.avatarUrl,
            ifCacheNilAt: \OutfitStore.currentAvatarImage
        )
        async let cutoutTask: Void = preload(
            url: store.currentProfile?.avatarCutoutUrl,
            ifCacheNilAt: \OutfitStore.currentAvatarCutoutImage
        )
        _ = await (avatarTask, cutoutTask)
    }

    /// Generic single-image preloader. Reads the current cache
    /// value via the keypath; bails if it's already set OR the
    /// URL is missing/malformed; otherwise fetches the bytes and
    /// writes the decoded UIImage back through the keypath on
    /// the main actor.
    private func preload(
        url urlString: String?,
        ifCacheNilAt keyPath: ReferenceWritableKeyPath<OutfitStore, UIImage?>
    ) async {
        guard store[keyPath: keyPath] == nil,
              let urlString,
              let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)
        else { return }

        await MainActor.run { store[keyPath: keyPath] = image }
    }

    private func uploadAvatar(_ image: UIImage) async {
        guard let userId = auth.userId else { return }
        await MainActor.run { isUploadingAvatar = true }
        do {
            let avatarURLString = try await AvatarService.uploadAvatar(image, userId: userId)
            // A new avatar invalidates any previously-stored
            // bust cutout — that PNG was derived from the OLD
            // photo and would composite incorrectly on the new
            // one. Clear it server-side so any concurrent
            // viewers fetch the (correct) fallback until the
            // user lands on bust again and the customize sheet
            // re-runs FAL.
            try? await SocialService.updateHeaderCustomization(
                userId: userId,
                style: ProfileHeaderStyle.parse(store.currentProfile?.headerStyle),
                accentColorHex: store.currentProfile?.headerAccentColor,
                cutoutURL: nil
            )
            await MainActor.run {
                store.currentProfile?.avatarUrl = avatarURLString
                store.currentProfile?.avatarCutoutUrl = nil
                // Drop the in-memory cutout too — same reason
                // we cleared the server URL: it was generated
                // from the prior photo and would composite the
                // wrong silhouette over the new pixels.
                store.currentAvatarCutoutImage = nil
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

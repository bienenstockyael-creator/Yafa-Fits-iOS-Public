import PhotosUI
import SwiftUI
import UIKit

/// Sheet that opens when the user taps the profile-photo edit
/// icon on their own profile (and either already has a photo set
/// or just picked one via the system photo picker). Lets them
/// swipe through three preset header layouts and pick an accent
/// color for the two stylized ones.
///
/// Visual language deliberately mirrors `ShareCardComposer` so
/// "customize a thing" sheets across the app feel like one
/// family: monospaced caps title in the header, tiny dot row
/// for the carousel index, ringed color dots for variant
/// selection, monospaced caps capsule for the action button.
/// Keep those touch-points in sync if either sheet is restyled.
///
/// State model:
///   * `selectedStyle` — which of the three previews is current.
///     Drives the carousel page, dot indicator, and color picker
///     visibility.
///   * `selectedColorHex` — hex from
///     `ProfileHeaderAccentColor.palette`. Only meaningful for
///     `.curved` and `.bust`.
///   * `cutoutImage` — locally-stored UIImage of the
///     background-removed avatar. Lazily populated when the
///     user first lands on `.bust` (or sheet open if a cached
///     URL already exists on the profile).
///   * `isProcessingCutout` — true while FAL bg-removal is
///     in flight. Disables Save so the user can't commit a
///     half-baked state.
struct ProfileHeaderCustomizeSheet: View {
    let username: String
    let displayName: String
    let bio: String?
    let avatarImage: UIImage

    /// Pre-crop, non-circle-clipped image the user just picked
    /// in this session. Used as the FAL input for the bust cutout
    /// so the silhouette includes the full shoulders / chest
    /// rather than being clamped to the circular avatar disc.
    /// Nil for users opening the sheet without first picking a
    /// new photo (e.g. they had an avatar from before this
    /// feature) — in that case we fall back to `avatarImage`,
    /// which gives the disc-shaped cutout but still produces a
    /// usable bust.
    let originalImage: UIImage?

    /// Pre-existing cutout URL if the user has used the bust
    /// style before. When non-nil, the sheet fetches it and
    /// pre-fills `cutoutImage` so swiping to bust is instant.
    let existingCutoutURL: String?

    let initialStyle: ProfileHeaderStyle
    let initialAccentHex: String?

    /// Called when the user picks AND crops a new photo from
    /// within this sheet. Parent uploads the cropped image as
    /// the new avatar and updates whatever state drives the
    /// `avatarImage` / `originalImage` props this sheet
    /// receives. The sheet stays presented through the whole
    /// flow — picker + cropper are stacked on TOP of the sheet
    /// rather than dismissing it.
    let onPhotoPicked: (_ cropped: UIImage, _ original: UIImage, _ square: UIImage) -> Void

    /// Called when the user taps Save. Provides the committed
    /// values. Parent handles uploading the cutout PNG (if any)
    /// + updating the profile row.
    let onSave: (
        _ style: ProfileHeaderStyle,
        _ accentHex: String?,
        _ cutoutImage: UIImage?
    ) -> Void

    let onDismiss: () -> Void

    @State private var selectedStyle: ProfileHeaderStyle
    @State private var selectedColorHex: String
    @State private var cutoutImage: UIImage?
    @State private var isProcessingCutout = false
    /// Square crop from the most recent in-session photo pick (the
    /// user's framing from the crop sheet, un-clipped). Used as the
    /// bust cutout source so the cutout keeps that scale + centering
    /// even when the user picks on the minimal style and only later
    /// swipes to bust — at which point `freshSource` is gone but the
    /// stored crop still carries the framing. Its presence also means
    /// "a fresh photo was picked," so we skip the stale cached cutout
    /// URL (which points at the previous photo).
    @State private var pendingSquareCrop: UIImage?
    /// True only when `cutoutImage` came from a fresh FAL run in
    /// THIS sheet session. False when we hydrated it from the
    /// already-stored `existingCutoutURL`. Drives the save path:
    /// if false, the existing Storage URL is reused as-is so
    /// flipping bust → minimal → bust doesn't burn another
    /// upload (or another FAL credit, which is already gated
    /// upstream by the same cached-URL check).
    @State private var cutoutWasFreshlyGenerated = false
    /// Photo-picker stack — owned by THIS sheet so the picker
    /// presents on top of it (as a modal layer) without
    /// dismissing the sheet underneath. Same triple as the
    /// parent uses for the initial photo pick, just lifted
    /// inside the sheet's scope.
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingCropImage: IdentifiableImage?

    init(
        username: String,
        displayName: String,
        bio: String?,
        avatarImage: UIImage,
        originalImage: UIImage?,
        existingCutoutURL: String?,
        initialStyle: ProfileHeaderStyle,
        initialAccentHex: String?,
        onPhotoPicked: @escaping (UIImage, UIImage, UIImage) -> Void,
        onSave: @escaping (ProfileHeaderStyle, String?, UIImage?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.avatarImage = avatarImage
        self.originalImage = originalImage
        self.existingCutoutURL = existingCutoutURL
        self.initialStyle = initialStyle
        self.initialAccentHex = initialAccentHex
        self.onPhotoPicked = onPhotoPicked
        self.onSave = onSave
        self.onDismiss = onDismiss
        _selectedStyle = State(initialValue: initialStyle)
        _selectedColorHex = State(
            initialValue: initialAccentHex ?? ProfileHeaderAccentColor.defaultHex
        )
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)

                // Spacer above the title so the profile preview
                // sits vertically centered in the available
                // screen real-estate, not pinned to the header.
                Spacer(minLength: LayoutMetrics.medium)

                styleNameTitle
                    .padding(.bottom, 6)

                carousel
                    .frame(height: 360)

                pageDots
                    .padding(.top, 14)

                // Accent color only affects the bust
                // highlighter — curved keeps the neutral
                // empty-feed pill look, minimal has nothing
                // colored at all. So the picker is reserved-
                // height but only visible/tappable when the
                // bust style is current.
                colorDots
                    .padding(.top, 14)
                    .opacity(selectedStyle == .bust ? 1 : 0)
                    .allowsHitTesting(selectedStyle == .bust)

                Spacer(minLength: LayoutMetrics.large)

                saveButton
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
            }
        }
        // Clamp Dynamic Type — the highlighter blob scales its
        // font via `@ScaledMetric` inside HighlighterUsername,
        // and at extreme accessibility sizes that scaling would
        // grow the blob past the bust frame width. Capping at
        // `.accessibility1` gives users with Larger Text a real
        // size bump (~150%) without breaking the fixed layout.
        .dynamicTypeSize(.large ... .accessibility1)
        .task {
            if selectedStyle == .bust {
                await ensureCutoutAvailable()
            }
        }
        .onChange(of: selectedStyle) { _, newValue in
            if newValue == .bust {
                Task { await ensureCutoutAvailable() }
            }
        }
        // Picker + cropper presented on top of THIS sheet so it
        // stays mounted across the swap. Attaching the modifiers
        // here (instead of on the parent ProfileHeader) is what
        // keeps the sheet from being dismissed when the picker
        // appears — modal stacking, not modal replacement.
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
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
            AvatarCropView(image: wrapper.image) { cropped, square in
                pendingCropImage = nil
                selectedPhoto = nil
                // A NEW photo invalidates any cutout we'd
                // already hydrated in this session — the next
                // bust render must re-fetch / re-process from
                // the new pixels rather than display the stale
                // one.
                cutoutImage = nil
                cutoutWasFreshlyGenerated = false
                // Remember the square crop so the bust cutout keeps
                // the user's framing even if they picked here on a
                // non-bust style and swipe to bust later.
                pendingSquareCrop = square
                onPhotoPicked(cropped, wrapper.image, square)
                // If the user is already on bust, kick off
                // FAL bg-removal immediately so the new photo
                // gets cut out without requiring a swipe-away-
                // and-back. We feed the SQUARE crop (the user's
                // framing, un-clipped) rather than the full
                // original, so the bust keeps the centering +
                // zoom the user just chose in the crop sheet.
                if selectedStyle == .bust {
                    Task { await ensureCutoutAvailable(freshSource: square) }
                }
            } onCancel: {
                pendingCropImage = nil
                selectedPhoto = nil
            }
        }
    }

    // MARK: - Header

    /// Close button (left) + monospaced caps title (center) +
    /// camera button to change the photo (right). Symmetric 36pt
    /// circle buttons on both sides so the title stays
    /// optically centered — same pattern as
    /// `ShareCardComposer.header`.
    private var header: some View {
        HStack {
            Button(action: onDismiss) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(SolidPressButtonStyle())
            .accessibilityLabel("Close")

            Spacer()

            Text("CHOOSE YOUR HEADER STYLE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            Button {
                showPhotoPicker = true
            } label: {
                AppIcon(glyph: .camera, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(SolidPressButtonStyle())
            .accessibilityLabel("Change photo")
        }
    }

    // MARK: - Style name (floats above the carousel)

    /// Mirrors `ShareCardComposer.templateTitle` — caps
    /// monospaced label that hard-cuts on style change so it
    /// doesn't interpolate across swipes.
    private var styleNameTitle: some View {
        Text(selectedStyle.displayName.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textMuted)
            .frame(height: 22)
            .transaction { $0.animation = nil }
    }

    // MARK: - Carousel

    /// Horizontally-paged carousel of the three style previews.
    /// `TabView`'s default `.page` index dots are hidden — we
    /// render a custom dot row below to match
    /// `ShareCardComposer`'s minimal aesthetic. The profile
    /// preview content inside each page is wrapped in a Spacer
    /// sandwich so the avatar block reads as vertically
    /// centered within the carousel frame.
    private var carousel: some View {
        TabView(selection: $selectedStyle) {
            ForEach(ProfileHeaderStyle.allCases, id: \.self) { style in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ProfileHeaderStylePreview(
                        style: style,
                        accentColor: ProfileHeaderAccentColor.color(for: selectedColorHex),
                        username: username,
                        displayName: displayName,
                        bio: bio,
                        avatarImage: avatarImage,
                        cutoutImage: cutoutImage,
                        isProcessingCutout: isProcessingCutout && style == .bust,
                        onTapAvatar: { showPhotoPicker = true }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .tag(style)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Capsule-style page indicator: the selected style is a
    /// wide pill, others are tiny dots. Distinctly different
    /// from `ShareCardComposer`'s uniform tiny dots —
    /// customize-header is a 3-style choice (not a long
    /// scrubbable list), so a clear "you are here" pill makes
    /// the current position obvious without a magnification
    /// lens.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(ProfileHeaderStyle.allCases, id: \.self) { style in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        selectedStyle = style
                    }
                } label: {
                    Capsule(style: .continuous)
                        .fill(style == selectedStyle ? AppPalette.textPrimary : AppPalette.textFaint)
                        .frame(
                            width: style == selectedStyle ? 18 : 6,
                            height: 6
                        )
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SolidPressButtonStyle())
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: selectedStyle)
    }

    // MARK: - Color dots

    /// Accent color picker — mirrors
    /// `ShareCardComposer.templateColorPicker`. 14pt color
    /// circles with a hairline black border for definition and
    /// a `textSecondary` ring (via padded `strokeBorder`) on the
    /// active color.
    private var colorDots: some View {
        HStack(spacing: 14) {
            ForEach(ProfileHeaderAccentColor.palette, id: \.self) { hex in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedColorHex = hex
                } label: {
                    Circle()
                        .fill(ProfileHeaderAccentColor.color(for: hex))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    AppPalette.textSecondary,
                                    lineWidth: hex == selectedColorHex ? 1.5 : 0
                                )
                                .padding(-3.5)
                        )
                }
                .buttonStyle(SolidPressButtonStyle())
                .accessibilityLabel(ProfileHeaderAccentColor.accessibilityName(for: hex))
                .accessibilityAddTraits(hex == selectedColorHex ? .isSelected : [])
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Highlighter color")
    }

    // MARK: - Save

    /// Save action styled to match the canonical SAVE button used
    /// elsewhere in the app (e.g. `ProfileView.saveButton`):
    /// 44pt-tall `appCapsule` with a soft drop shadow, 12pt
    /// semibold caps label tracked at 1.5, `textPrimary`
    /// foreground. Keeps "save" affordances visually identical
    /// across the app so users learn one pattern. Disabled while
    /// the bust cutout is still being processed so the user
    /// can't ship a half-rendered state.
    private var saveButton: some View {
        Button(action: handleSave) {
            Group {
                if isProcessingCutout && selectedStyle == .bust {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                } else {
                    Text("SAVE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isProcessingCutout && selectedStyle == .bust)
    }

    private func handleSave() {
        let savedColor: String? = selectedStyle == .minimal ? nil : selectedColorHex
        // Only pass the UIImage upstream if FAL produced it in
        // THIS session. If it was hydrated from the stored URL
        // (user toggled bust → minimal → bust on the same
        // photo) we pass nil so the parent reuses the existing
        // Storage URL instead of re-uploading the same PNG.
        let savedCutout: UIImage? = (selectedStyle == .bust && cutoutWasFreshlyGenerated)
            ? cutoutImage
            : nil
        onSave(selectedStyle, savedColor, savedCutout)
    }

    // MARK: - Cutout lifecycle

    /// Pulls down the bust cutout if a server copy already
    /// exists, otherwise runs FAL background removal on the
    /// current avatar and stores the result locally. Idempotent
    /// — second call when `cutoutImage` is already set is a
    /// no-op, so swiping back and forth between styles doesn't
    /// re-fetch / re-process.
    ///
    /// `freshSource` is set when the user JUST changed photos
    /// inside the sheet — we can't read it from `originalImage`
    /// because the parent's state update hasn't propagated to
    /// this view yet. Passing it explicitly also tells us to
    /// SKIP the cached-URL fetch (that URL points to the cutout
    /// of the OLD photo and would composite incorrectly).
    private func ensureCutoutAvailable(freshSource: UIImage? = nil) async {
        if cutoutImage != nil { return }

        // The framing-preserving source for a fresh in-session pick:
        // the just-passed square (bust-time pick) or the stored crop
        // (picked on another style, swiped to bust now). Either way it
        // supersedes the cached URL, which is the OLD photo's cutout.
        let freshCrop = freshSource ?? pendingSquareCrop

        // 1. Try the cached URL on the profile first (cheap).
        //    Skipped when a fresh photo was just picked — the
        //    stored URL points to the prior photo's cutout.
        if freshCrop == nil,
           let urlString = existingCutoutURL,
           let url = URL(string: urlString) {
            await MainActor.run { isProcessingCutout = true }
            if let data = try? await URLSession.shared.data(from: url).0,
               let image = UIImage(data: data) {
                await MainActor.run {
                    cutoutImage = image
                    isProcessingCutout = false
                }
                return
            }
            await MainActor.run { isProcessingCutout = false }
        }

        // 2. No cached cutout — run FAL background removal.
        // Prefer the fresh photo (just picked, parent state
        // hasn't propagated yet), then the pre-crop
        // `originalImage`, falling back to the circle-clipped
        // avatar only if we have nothing else. On failure we
        // leave `cutoutImage` nil and the preview hides the
        // spinner — acceptable per the V1 spec.
        await MainActor.run { isProcessingCutout = true }
        // Prefer the user's framed square crop (this session's pick),
        // then the pre-crop original, then the circle avatar. Using
        // the square crop is what preserves the scale + centering when
        // the photo was added on a non-bust style and revealed here.
        let sourceImage = freshCrop ?? originalImage ?? avatarImage
        guard let jpegData = sourceImage.jpegData(compressionQuality: 0.92) else {
            await MainActor.run { isProcessingCutout = false }
            return
        }
        do {
            let resultData = try await FalBackgroundRemovalService.shared
                .removeBackground(from: jpegData) { _ in }
            await MainActor.run {
                cutoutImage = UIImage(data: resultData)
                cutoutWasFreshlyGenerated = true
                isProcessingCutout = false
            }
        } catch {
            await MainActor.run { isProcessingCutout = false }
        }
    }
}

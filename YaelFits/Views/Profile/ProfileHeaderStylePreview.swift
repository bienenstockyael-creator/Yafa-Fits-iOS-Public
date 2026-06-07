import SwiftUI

/// Renders a single profile-header style for the customize
/// carousel. The same `style` value also gets applied to the
/// actual `ProfileHeader` when the user saves — keep the two
/// rendering paths in sync.
///
/// Inputs:
///   * `style` — which of the three layouts to render.
///   * `accentColor` — used by `curved` (pill fill) and `bust`
///     (highlighter rect). Ignored for `minimal`.
///   * `username`, `displayName`, `bio` — the user's profile
///     data, shown in each preview so the user sees their
///     actual content rendered in each style.
///   * `avatarImage` — UIImage to display. Required for any
///     style (the customize sheet is only reachable once a
///     photo exists).
///   * `cutoutImage` — UIImage with background removed.
///     Only used by `bust`. When nil and `style == .bust`,
///     the card falls back to `avatarImage` with a small
///     "processing" indicator so the user knows the cutout
///     is being generated.
///   * `isProcessingCutout` — true while FAL bg-removal runs
///     for the bust style. Drives the small spinner overlay.
struct ProfileHeaderStylePreview: View {
    let style: ProfileHeaderStyle
    let accentColor: Color
    let username: String
    let displayName: String
    let bio: String?
    let avatarImage: UIImage
    let cutoutImage: UIImage?
    let isProcessingCutout: Bool
    /// Called when the user taps the preview avatar — the parent
    /// re-opens the photo picker so they can swap the underlying
    /// image. Same affordance as the camera button in the sheet
    /// header; tapping the image itself is the more discoverable
    /// gesture for users used to other apps' profile editors.
    var onTapAvatar: (() -> Void)? = nil

    /// Avatar diameter inside the preview card. Pulled from
    /// `ProfileHeaderMetrics` so the carousel scale stays in
    /// sync with the live header sizing (currently 1.36x the
    /// live header so each preview reads as a hero, not a
    /// thumbnail).
    private var avatarDiameter: CGFloat { ProfileHeaderMetrics.previewAvatarDiameter }

    var body: some View {
        VStack(spacing: LayoutMetrics.small) {
            Button {
                onTapAvatar?()
            } label: {
                avatarBlock
            }
            .buttonStyle(.plain)
            .disabled(onTapAvatar == nil)
            .accessibilityLabel("\(style.displayName) header preview")
            .accessibilityHint(onTapAvatar == nil ? "" : "Double-tap to change photo")

            // Curved bakes the displayName into the pill,
            // bust into the highlighter — only minimal renders
            // it as a standalone label so we don't show the
            // same text twice on the preview card.
            if style == .minimal {
                Text(displayName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                    .padding(.top, LayoutMetrics.xxSmall)
            }

            if let bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 19))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, LayoutMetrics.medium)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LayoutMetrics.large)
    }

    @ViewBuilder
    private var avatarBlock: some View {
        switch style {
        case .minimal:
            minimalAvatar
        case .curved:
            curvedAvatar
        case .bust:
            bustAvatar
        }
    }

    /// Style 1 (current): circular cropped avatar, username
    /// below, no decoration.
    private var minimalAvatar: some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            Image(uiImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .clipShape(Circle())
                .appCircle(shadowRadius: 10, shadowY: 4)
        }
    }

    /// Style 2: circular avatar wrapped by a curved display-name
    /// pill arcing along the bottom edge. The pill fill uses the
    /// chosen accent color so the customization choice is visible
    /// immediately. Per spec, the curved pill shows the user's
    /// display NAME (not @handle) — the magazine-tag aesthetic
    /// reads cleaner with proper-noun text.
    private var curvedAvatar: some View {
        ZStack {
            Image(uiImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .clipShape(Circle())
                .appCircle(shadowRadius: 10, shadowY: 4)

            // Pill styling matches the empty-feed avatar-bubble
            // version: white fill with the subtle `cardBorder`
            // stroke. The accent color is only used by the bust
            // style — the curved pill stays neutral so the user's
            // photo remains the focal point of this layout.
            CurvedUsernamePill(
                text: displayName,
                avatarRadius: avatarDiameter / 2,
                fontSize: ProfileHeaderMetrics.previewCurvedFontSize,
                pillThickness: ProfileHeaderMetrics.previewCurvedPillThickness
            )
            .drawingGroup()
        }
        .frame(
            width: avatarDiameter + ProfileHeaderMetrics.previewCurvedFramePadding,
            height: avatarDiameter + ProfileHeaderMetrics.previewCurvedFramePadding
        )
    }

    /// Style 3: background-removed avatar (a bust), no circular
    /// crop, no shadow. Display name sits in a highlighter
    /// rectangle that OVERLAPS the chest/shoulder area of the
    /// bust — the rectangle is tilted, softened-cornered, and
    /// auto-sizes around its (up to two-line) text. Mirrors the
    /// Y2K magazine paste-up reference where headlines sit
    /// across the figure's mid-body, not at the very bottom.
    /// While the cutout is still being generated, the fallback
    /// is the original avatar with a spinner so the user knows
    /// the bust treatment is processing.
    private var bustAvatar: some View {
        ZStack {
            if let cutoutImage {
                Image(uiImage: cutoutImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: ProfileHeaderMetrics.previewBustWidth, height: avatarDiameter)
            } else {
                Image(uiImage: avatarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .clipShape(Circle())
                    .overlay {
                        if isProcessingCutout {
                            // Dark scrim over the photo so the
                            // sparkles glow against a true
                            // dark backdrop instead of a
                            // washed-out faded photo. The
                            // photo stays as a faint ghost
                            // underneath so the user still
                            // sees their face during the few
                            // seconds FAL is running.
                            Color.black
                                .opacity(0.30)
                                .clipShape(Circle())

                            // Lottie sparkle field — same one
                            // the generation flow uses for
                            // "magic happening here." Brightness
                            // lift + soft white outer shadow
                            // makes each star read as a glowing
                            // neon mark against the dark scrim
                            // (the field itself uses a tinted
                            // aqua-grey internally, which
                            // alone reads dim on a dark bg).
                            GenerationStarField(
                                starSize: 220,
                                interactive: false
                            )
                            .brightness(0.45)
                            .saturation(1.4)
                            .shadow(color: .white.opacity(0.9), radius: 10)
                            .shadow(color: .cyan.opacity(0.7), radius: 16)
                            .allowsHitTesting(false)
                        }
                    }
            }

            HighlighterUsername(
                text: displayName,
                color: accentColor,
                fontSize: ProfileHeaderMetrics.previewHighlighterFontSize,
                rotation: ProfileHeaderMetrics.highlighterRotation
            )
            // Push the highlighter ~38% of the frame down so it
            // lands across the chest/torso area. Combined with
            // the extra frame height below, the result reads as
            // "headline pasted across the lower body" — the
            // magazine reference.
            .offset(y: avatarDiameter * ProfileHeaderMetrics.bustHighlighterOffsetRatio)
        }
        // Wider-than-tall frame so the cutout has horizontal
        // breathing room for hair / shoulders (matches the
        // live header's bust frame ratio). Extra vertical
        // room below catches the highlighter overhang and
        // leaves space for the bio underneath.
        .frame(
            width: ProfileHeaderMetrics.previewBustWidth,
            height: avatarDiameter + ProfileHeaderMetrics.previewBustExtraHeight
        )
    }
}

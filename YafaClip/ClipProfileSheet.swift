import SwiftUI
import ImageIO

/// The creator's profile inside the clip — the same recipe as the
/// app's `UserProfileView` (avatar, name, bio, "X outfits · Y
/// followers", FOLLOW, 3-column grid), fed by ClipDataService and
/// capped at the 12 most recent public fits. Grid thumbnails are
/// each fit's first spin frame, static; tapping one loads that fit
/// into the main card, so the whole clip becomes browsable. FOLLOW
/// hands off to the install overlay (a clip has no account).
struct ClipProfileSheet: View {
    let userId: String
    let seedUsername: String
    let seedAvatarURL: URL?
    var onRequireApp: () -> Void
    var onSelectFit: (String) -> Void

    @State private var profile: ClipProfile?
    @State private var isLoading = true

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.xSmall) {
                header
                if let profile, !profile.fits.isEmpty {
                    sectionHeader
                    grid(profile.fits)
                } else if !isLoading {
                    Text("No public outfits yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.textMuted)
                        .padding(.top, LayoutMetrics.large)
                } else {
                    ProgressView()
                        .tint(AppPalette.textMuted)
                        .padding(.top, LayoutMetrics.xLarge)
                }
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.top, LayoutMetrics.large)
            .padding(.bottom, LayoutMetrics.xLarge)
        }
        .scrollIndicators(.hidden)
        .presentationBackground(AppPalette.groupedBackground)
        .task {
            profile = await ClipDataService.loadProfile(userId: userId)
            isLoading = false
        }
    }

    // MARK: - Header (UserProfileView's minimal-style recipe)

    private var header: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            AvatarView(
                url: (profile?.avatarURL ?? seedAvatarURL)?.absoluteString,
                initial: String((profile?.displayName ?? seedUsername).prefix(1)).uppercased(),
                size: 88,
                shadowRadius: 10,
                shadowY: 4
            )

            Text(profile?.displayName ?? seedUsername)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.top, LayoutMetrics.xxSmall)

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.large)
            }

            if let profile {
                statsRow(profile).padding(.top, LayoutMetrics.xxSmall)
            }

            followButton.padding(.top, LayoutMetrics.xSmall)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    private func statsRow(_ profile: ClipProfile) -> some View {
        HStack(spacing: LayoutMetrics.small) {
            statSegment(
                count: profile.outfitCount,
                label: profile.outfitCount == 1 ? "outfit" : "outfits"
            )
            Text("·")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textFaint)
            statSegment(
                count: profile.followerCount,
                label: profile.followerCount == 1 ? "follower" : "followers"
            )
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

    private var followButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onRequireApp()
        } label: {
            Text("FOLLOW")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: 200)
                .frame(height: 36)
                .appCapsule(shadowRadius: 4, shadowY: 2)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var sectionHeader: some View {
        HStack {
            Text("outfits")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.leading, LayoutMetrics.xxSmall)
            Spacer()
        }
        .padding(.top, LayoutMetrics.xSmall)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    private func grid(_ fits: [ClipProfileFit]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 42) {
            ForEach(fits) { fit in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSelectFit(fit.id)
                } label: {
                    ClipThumbImage(url: fit.thumbURL)
                        .frame(height: 132)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SolidPressButtonStyle())
            }
        }
    }
}

/// Static first-frame thumbnail with a small shared cache — decodes
/// at grid size (not full frame size) via ImageIO, same technique as
/// FrameSpinner's LRU.
private struct ClipThumbImage: View {
    let url: URL?
    @State private var image: UIImage?

    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = Self.downsample(data) else { return }
            Self.cache.setObject(decoded, forKey: url as NSURL)
            withAnimation(.easeIn(duration: 0.18)) { image = decoded }
        }
    }

    private static func downsample(_ data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

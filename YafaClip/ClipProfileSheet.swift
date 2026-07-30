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

    // Re-injected into the full-screen carousel below — presented
    // contexts don't inherit it automatically.
    @Environment(VibesEffectHost.self) private var vibesHost

    @State private var profile: ClipProfile?
    @State private var isLoading = true
    @State private var showCarousel = false
    @State private var carouselIndex = 0

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
        // Grid tap → full-screen carousel over the creator's fits,
        // the app's profile flow: swipe between fits, back arrow
        // returns to the grid.
        .fullScreenCover(isPresented: $showCarousel) {
            if let profile {
                ClipCarouselView(
                    fits: profile.fits,
                    index: $carouselIndex,
                    onClose: { showCarousel = false },
                    onRequireApp: {
                        showCarousel = false
                        onRequireApp()
                    }
                )
                .environment(vibesHost)
            }
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
            ForEach(Array(fits.enumerated()), id: \.element.id) { index, fit in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    carouselIndex = index
                    showCarousel = true
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

// MARK: - Carousel (the app's profile-grid → carousel flow)

/// Full-screen, horizontally paged carousel over the creator's public
/// fits. Each page lazily loads the full ClipFit and renders the same
/// feed card as the clip's main screen — spin, like, vibe, comments,
/// shop all live. Drag on the outfit scrubs the spin; swiping
/// elsewhere on the page changes fits, mirroring the app's carousel
/// gesture split.
private struct ClipCarouselView: View {
    let fits: [ClipProfileFit]
    @Binding var index: Int
    var onClose: () -> Void
    var onRequireApp: () -> Void

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(fits.enumerated()), id: \.element.id) { i, fit in
                    // Paged TabView is NOT lazy — all pages mount at
                    // once. Only the selected page gets the live card
                    // (spinner + data fetch); the rest show the static
                    // first frame. Without this, 12 spinners prefetch
                    // whole frame sequences concurrently and the clip
                    // gets jetsammed.
                    ClipCarouselPage(
                        outfitId: fit.id,
                        thumbURL: fit.thumbURL,
                        isActive: i == index,
                        onRequireApp: onRequireApp,
                        onClose: onClose
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)

            // Back arrow — same affordance as UserProfileView's
            // full-screen presentation.
            VStack {
                HStack {
                    Button(action: onClose) {
                        AppIcon(glyph: .chevronLeft, size: 14, color: AppPalette.iconPrimary)
                            .frame(width: 40, height: 40)
                            .appCircle(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    Spacer()
                }
                .padding(.horizontal, LayoutMetrics.medium)
                Spacer()
            }

            // The vibe burst renders in THIS hosting context too —
            // the root layers sit beneath the full-screen cover.
            VibesWaveOverlay()
            VibesMorphLayer()
            VibesParticleLayer()
            VibesBannerLayer()
        }
    }
}

private struct ClipCarouselPage: View {
    let outfitId: String
    let thumbURL: URL?
    let isActive: Bool
    var onRequireApp: () -> Void
    var onClose: () -> Void

    @State private var fit: ClipFit?
    @State private var failed = false

    var body: some View {
        Group {
            if let fit, isActive {
                ScrollView {
                    ClipFeedCard(
                        fit: fit,
                        onRequireApp: onRequireApp,
                        // Header tap here just returns to the profile
                        // we came from.
                        onOpenProfile: onClose
                    )
                    .padding(.horizontal, LayoutMetrics.small)
                    .padding(.top, 64) // clear the back arrow
                    .padding(.bottom, LayoutMetrics.xLarge)
                }
                .scrollIndicators(.hidden)
            } else if failed {
                Text("THIS FIT ISN’T AVAILABLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.textFaint)
            } else {
                // Inactive (or still-loading) page: the static first
                // frame, so mid-swipe the neighbor shows the outfit
                // without paying for a live spinner.
                ClipThumbImage(url: thumbURL)
                    .frame(height: 292)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: isActive) {
            guard isActive, fit == nil else { return }
            if let loaded = await ClipDataService.loadFit(slugOrId: outfitId) {
                fit = loaded
            } else {
                failed = true
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

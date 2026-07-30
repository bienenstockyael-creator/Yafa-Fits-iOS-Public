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

// MARK: - Carousel (CarouselView's viewer recipe, clip-native)

/// The app's carousel, viewer mode: pageBackground backdrop + 10%
/// dim, weather pill + date · location chrome up top, the outfit
/// slide big in the middle with faded/scaled neighbors, chevron nav
/// arrows, a Like / Comment / Save / Cart circle row pinned at the
/// bottom, and the cart toggling the detail card (product cells with
/// BUY pills) that shrinks the slide upward. Scrub spins; a long
/// one-direction drag flips the page (the app's ScrubSwipe rule).
/// Tap the backdrop to close the card, then to dismiss.
private struct ClipCarouselView: View {
    let fits: [ClipProfileFit]
    @Binding var index: Int
    var onClose: () -> Void
    var onRequireApp: () -> Void

    @State private var loadedFits: [String: ClipFit] = [:]
    @State private var cardVisible = false
    @State private var likedIds: Set<String> = []
    @State private var savedIds: Set<String> = []
    @State private var showComments = false
    @Environment(\.openURL) private var openURL

    // CarouselView's metrics, verbatim.
    private static let slideTopInset: CGFloat = LayoutMetrics.touchTarget + LayoutMetrics.xxSmall
    private static let cardInset: CGFloat = 12
    private static let actionRowReserve: CGFloat = 40 + 88 - 18
    private static let slideHeightFactor: CGFloat = 0.58 * 1.2
    private static let minSlideHeight: CGFloat = 320
    private static let cardExpandSlideShrink: CGFloat = 0.34
    private static let slideExpandTranslation: CGFloat = -20
    private let gap: CGFloat = LayoutMetrics.xSmall
    private let pageCurve = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)
    private let cardSpring = Animation.spring(response: 0.4, dampingFraction: 0.78)

    private var currentFit: ClipFit? {
        guard fits.indices.contains(index) else { return nil }
        return loadedFits[fits[index].id]
    }
    private var cardProgress: CGFloat { cardVisible ? 1 : 0 }

    var body: some View {
        ZStack {
            // Backdrop: tap closes the card first, then dismisses —
            // CarouselView's two-stage tap-outside semantics.
            AppPalette.pageBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if cardVisible {
                        withAnimation(cardSpring) { cardVisible = false }
                    } else {
                        onClose()
                    }
                }

            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { geo in
                let slideWidth = geo.size.width - Self.cardInset * 2
                let usable = geo.size.height - Self.slideTopInset - Self.actionRowReserve
                let slideHeight = max(Self.minSlideHeight, usable * Self.slideHeightFactor)
                let step = slideWidth + gap

                ZStack(alignment: .bottom) {
                    VStack(spacing: LayoutMetrics.small) {
                        // Weather slot always reserved so the chrome
                        // never shifts when a fit has no weather.
                        ZStack {
                            if let weather = currentFit?.weather, !weather.condition.isEmpty {
                                WeatherPill(weather: weather, useFahrenheit: false)
                            }
                        }
                        .frame(height: 36)
                        .offset(y: 3 * (1.0 - cardProgress))

                        dateLocationLabel

                        slideStrip(slideWidth: slideWidth, slideHeight: slideHeight, step: step, center: geo.size.width / 2)
                            .frame(height: slideHeight)
                            .scaleEffect(1.0 - (cardProgress * Self.cardExpandSlideShrink), anchor: .top)
                            .overlay {
                                navButtons
                                    .padding(.horizontal, Self.cardInset)
                            }

                        Spacer(minLength: 0)
                    }
                    .offset(y: Self.slideExpandTranslation * cardProgress)
                    .animation(cardSpring, value: cardVisible)
                    .padding(.top, Self.slideTopInset)

                    // Bottom action row, pinned 40pt up — the viewer
                    // ordering: Like → Comment → Save → Cart.
                    if let fit = currentFit {
                        VStack(spacing: LayoutMetrics.xSmall) {
                            actionRow(fit)
                            // CarouselView keeps an invisible Delete
                            // placeholder on viewer surfaces so the
                            // circles sit at the owner-mode height.
                            Text("Delete")
                                .font(.system(size: 13))
                                .padding(.vertical, 6)
                                .opacity(0)
                        }
                        .padding(.bottom, 40)
                        .opacity(cardVisible ? 0 : 1)
                        .allowsHitTesting(!cardVisible)
                        .animation(cardSpring, value: cardVisible)
                    }

                    // Detail card — viewer mode: the product cells
                    // with BUY pills.
                    if cardVisible, let fit = currentFit {
                        detailCard(fit)
                            .padding(.horizontal, Self.cardInset)
                            .padding(.bottom, 30)
                            .transition(
                                .scale(scale: 0.92, anchor: .bottom)
                                    .combined(with: .move(edge: .bottom))
                                    .combined(with: .opacity)
                            )
                    }
                }
            }

            // Vibe layers live in this hosting context so bursts
            // render above the cover.
            VibesWaveOverlay()
            VibesMorphLayer()
            VibesParticleLayer()
            VibesBannerLayer()
        }
        .animation(cardSpring, value: cardVisible)
        .task(id: index) {
            guard fits.indices.contains(index) else { return }
            let id = fits[index].id
            guard loadedFits[id] == nil else { return }
            if let fit = await ClipDataService.loadFit(slugOrId: id) {
                loadedFits[id] = fit
            }
        }
        .sheet(isPresented: $showComments) {
            if let fit = currentFit {
                ClipCommentsSheet(comments: fit.comments, onRequireApp: {
                    showComments = false
                    onRequireApp()
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: chrome

    private var dateLocationLabel: some View {
        HStack(spacing: 8) {
            Text(currentFit?.numericDateLabel ?? "")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textFaint)
            if let location = currentFit?.location, !location.isEmpty {
                Text("·")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.textFaint)
                Text(location.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: slides

    private func slideStrip(slideWidth: CGFloat, slideHeight: CGFloat, step: CGFloat, center: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(fits.enumerated()), id: \.element.id) { i, fit in
                let distance = abs(i - index)
                Group {
                    // Only the current slide is a live spinner; ±2
                    // neighbors show static first frames; the rest
                    // are layout placeholders (memory + network).
                    if i == index, let loaded = loadedFits[fit.id] {
                        FrameSpinner(fit: loaded, onScrubRelease: handleScrubRelease)
                    } else if distance <= 2 {
                        ClipThumbImage(url: fit.thumbURL)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: slideWidth, height: slideHeight)
                .scaleEffect(max(0.82, 1.0 - Double(distance) * 0.16))
                .opacity(max(0.38, 1.0 - Double(distance) * 0.34))
            }
        }
        .offset(x: center - slideWidth / 2 - CGFloat(index) * step)
        .animation(pageCurve, value: index)
    }

    /// CarouselView.ScrubSwipe, verbatim: a drag well past a third of
    /// the slide that ran mostly one direction flips the page; a
    /// back-and-forth scrub never does.
    private func handleScrubRelease(_ net: CGFloat, _ monotonicity: CGFloat) {
        let width = UIScreen.main.bounds.width - Self.cardInset * 2
        let threshold = max(130, width * 0.35)
        guard abs(net) > threshold, monotonicity >= 0.80 else { return }
        let direction = net < 0 ? 1 : -1
        let proposed = index + direction
        guard fits.indices.contains(proposed) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(pageCurve) { index = proposed }
    }

    private var navButtons: some View {
        HStack {
            navButton(icon: .chevronLeft, disabled: index <= 0) { index -= 1 }
            Spacer()
            navButton(icon: .chevronRight, disabled: index >= fits.count - 1) { index += 1 }
        }
    }

    private func navButton(icon: AppIconGlyph, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(pageCurve) { action() }
        } label: {
            AppIcon(glyph: icon, size: 16, color: AppPalette.iconPrimary)
                .frame(width: LayoutMetrics.touchTarget, height: LayoutMetrics.touchTarget)
                .appCircle(shadowRadius: 10, shadowY: 5)
                .padding(20)
                .contentShape(Rectangle())
        }
        .buttonStyle(SolidPressButtonStyle())
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }

    // MARK: action row

    private func actionRow(_ fit: ClipFit) -> some View {
        HStack(spacing: LayoutMetrics.medium) {
            circleButton(glyph: .heart, filled: likedIds.contains(fit.outfitId)) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    toggle(&likedIds, fit.outfitId)
                }
            }
            circleButton(glyph: .comment) {
                if fit.comments.isEmpty {
                    onRequireApp()
                } else {
                    showComments = true
                }
            }
            circleButton(glyph: .bookmark, filled: savedIds.contains(fit.outfitId)) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggle(&savedIds, fit.outfitId)
                }
            }
            if !fit.products.isEmpty {
                circleButton(glyph: .cart) {
                    withAnimation(cardSpring) { cardVisible.toggle() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func circleButton(glyph: AppIconGlyph, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            AppIcon(glyph: glyph, size: 16, color: AppPalette.iconPrimary, filled: filled)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    // MARK: detail card

    private func detailCard(_ fit: ClipFit) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(fit.products) { product in
                        productCell(product)
                    }
                }
            }
        }
        .padding(LayoutMetrics.small)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 50 || value.predictedEndTranslation.height > 200 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(cardSpring) { cardVisible = false }
                    }
                }
        )
    }

    /// CarouselDetailCard.productCell, viewer mode: 100pt thumbnail,
    /// two-line name slot, BUY capsule.
    private func productCell(_ product: ClipProduct) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.28))
                    AsyncImage(url: product.imageURL) { image in
                        image.resizable().scaledToFit().padding(5)
                    } placeholder: {
                        Color.clear
                    }
                }
                .frame(width: 100, height: 100)

                Text(product.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 100, height: 32, alignment: .top)
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openShop(product)
            } label: {
                Text("BUY")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
        }
    }

    /// ProductShopLink's cascade with clip data: shop link → Lens in
    /// the in-app sheet (name search as its own fallback) → name
    /// search directly.
    private func openShop(_ product: ClipProduct) {
        let nameSearch = product.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            .flatMap { $0.isEmpty ? nil : URL(string: "https://www.google.com/search?udm=28&q=\($0)") }
        if let shop = product.shopURL {
            openURL(shop)
        } else if let image = product.imageURL,
                  let encoded = image.absoluteString
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let lens = URL(string: "https://lens.google.com/uploadbyurl?url=\(encoded)") {
            ShopBrowser.present(primary: lens, fallback: nameSearch)
        } else if let nameSearch {
            openURL(nameSearch)
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

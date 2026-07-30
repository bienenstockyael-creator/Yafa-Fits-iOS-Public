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
    @State private var carouselIndex = 0

    // Hero-transition state — the app's grid→carousel choreography:
    // the tapped cell flies to the slide position while the backdrop
    // fades in, then chrome + live slide reveal; reversed on close.
    @State private var carouselMounted = false
    @State private var backdropOpacity: Double = 0
    @State private var chromeVisible = false
    @State private var liveSlideVisible = false
    @State private var heroVisible = false
    @State private var heroFrame: CGRect = .zero
    @State private var heroThumbURL: URL?
    @State private var heroGridIndex: Int?
    @State private var gridFrames: [Int: CGRect] = [:]
    @State private var slideFrame: CGRect = .null

    private static let spaceName = "clipProfileSpace"
    private static let heroFlight = Animation.timingCurve(0.22, 0.84, 0.18, 1, duration: 0.26)

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
    ]

    var body: some View {
        ZStack {
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

            // Carousel mounts as an in-tree overlay (NOT a cover) so
            // the hero can fly between the grid and the slide — the
            // app's exact presentation model.
            if carouselMounted, let profile {
                ClipCarouselView(
                    fits: profile.fits,
                    index: $carouselIndex,
                    backdropOpacity: backdropOpacity,
                    chromeVisible: chromeVisible,
                    liveSlideVisible: liveSlideVisible,
                    spaceName: Self.spaceName,
                    onSlideFrame: { slideFrame = $0 },
                    onClose: { closeCarousel() },
                    onRequireApp: {
                        closeCarousel()
                        onRequireApp()
                    }
                )
                .environment(vibesHost)
            }

            // The flying thumbnail.
            if heroVisible {
                ClipThumbImage(url: heroThumbURL)
                    .frame(width: heroFrame.width, height: heroFrame.height)
                    .position(x: heroFrame.midX, y: heroFrame.midY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.spaceName)
        .onPreferenceChange(ClipGridFramesKey.self) { gridFrames = $0 }
        .presentationBackground(AppPalette.groupedBackground)
        .task {
            profile = await ClipDataService.loadProfile(userId: userId)
            isLoading = false
            #if DEBUG
            // Headless UI verification hook: auto-open the carousel so
            // simulator screenshots can check the chrome layout.
            if ProcessInfo.processInfo.environment["CLIP_AUTO_CAROUSEL"] == "1",
               let first = profile?.fits.first {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                openCarousel(at: 0, thumbURL: first.thumbURL)
            }
            #endif
        }
    }

    // MARK: - Hero choreography (CarouselHeroChoreography's timings)

    private func openCarousel(at index: Int, thumbURL: URL?) {
        carouselIndex = index
        heroThumbURL = thumbURL
        heroGridIndex = index
        heroFrame = gridFrames[index] ?? .zero
        heroVisible = gridFrames[index] != nil
        backdropOpacity = 0
        chromeVisible = false
        liveSlideVisible = false
        slideFrame = .null
        carouselMounted = true

        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) { backdropOpacity = 1 }

            // Wait for the slide to report a stable target frame —
            // flying toward a mid-layout transient makes the landing
            // snap (the app polls the same way).
            var stable: CGRect?
            var last: CGRect?
            for _ in 0..<30 {
                let frame = slideFrame
                if !frame.isNull, frame.width > 0 {
                    if let l = last, abs(l.minX - frame.minX) < 0.5, abs(l.minY - frame.minY) < 0.5 {
                        stable = frame
                        break
                    }
                    last = frame
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            let target = stable ?? last ?? heroFrame

            guard heroVisible else {
                // No source cell (shouldn't happen) — just reveal.
                withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = true }
                withAnimation(.easeInOut(duration: 0.12)) { liveSlideVisible = true }
                heroGridIndex = nil
                return
            }

            withAnimation(Self.heroFlight) { heroFrame = target }
            try? await Task.sleep(nanoseconds: 270_000_000)
            withAnimation(.easeInOut(duration: 0.28)) { chromeVisible = true }
            withAnimation(.easeInOut(duration: 0.12)) { liveSlideVisible = true }
            try? await Task.sleep(nanoseconds: 130_000_000)
            heroVisible = false
            heroGridIndex = nil
        }
    }

    private func closeCarousel() {
        guard carouselMounted else { return }
        Task { @MainActor in
            guard let profile, profile.fits.indices.contains(carouselIndex) else {
                carouselMounted = false
                return
            }
            let fit = profile.fits[carouselIndex]
            heroThumbURL = fit.thumbURL
            heroGridIndex = carouselIndex
            if !slideFrame.isNull, slideFrame.width > 0 {
                heroFrame = slideFrame
            }
            heroVisible = true
            withAnimation(.easeInOut(duration: 0.1)) {
                liveSlideVisible = false
                chromeVisible = false
            }

            if let home = gridFrames[carouselIndex] {
                withAnimation(Self.heroFlight) { heroFrame = home }
            }
            withAnimation(.easeOut(duration: 0.22).delay(0.06)) { backdropOpacity = 0 }
            try? await Task.sleep(nanoseconds: 290_000_000)
            carouselMounted = false
            heroVisible = false
            heroGridIndex = nil
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
                    openCarousel(at: index, thumbURL: fit.thumbURL)
                } label: {
                    ClipThumbImage(url: fit.thumbURL)
                        .frame(height: 132)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SolidPressButtonStyle())
                // Source cell hides while the hero flies from/to it —
                // otherwise the outfit shows twice mid-flight.
                .opacity(heroVisible && heroGridIndex == index ? 0.001 : 1)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ClipGridFramesKey.self,
                            value: [index: geo.frame(in: .named(Self.spaceName))]
                        )
                    }
                }
            }
        }
    }
}

/// Grid-cell frames in the profile's coordinate space, for the hero.
private struct ClipGridFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
    // Hero-choreography inputs, driven by ClipProfileSheet: the
    // backdrop fades in first, the hero lands, then chrome and the
    // live slide reveal.
    let backdropOpacity: Double
    let chromeVisible: Bool
    let liveSlideVisible: Bool
    let spaceName: String
    var onSlideFrame: (CGRect) -> Void
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
                .opacity(backdropOpacity)
                .contentShape(Rectangle())
                .allowsHitTesting(backdropOpacity > 0.08)
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
                .opacity(backdropOpacity)

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
                        .opacity(chromeVisible ? 1 : 0)

                        dateLocationLabel
                            .opacity(chromeVisible ? 1 : 0)

                        slideStrip(slideWidth: slideWidth, slideHeight: slideHeight, step: step, center: geo.size.width / 2)
                            .frame(height: slideHeight)
                            // Pin the overlay container to the
                            // VIEWPORT width — the strip itself is as
                            // wide as every slide laid out side by
                            // side, which shoved the nav arrows
                            // several screens off to the right.
                            // Leading alignment keeps the strip's
                            // origin at x=0 so the paging offset math
                            // holds.
                            .frame(width: geo.size.width, alignment: .leading)
                            .scaleEffect(1.0 - (cardProgress * Self.cardExpandSlideShrink), anchor: .top)
                            .overlay {
                                navButtons
                                    .padding(.horizontal, Self.cardInset)
                                    .opacity(chromeVisible ? 1 : 0)
                                    .allowsHitTesting(chromeVisible)
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
                        .opacity(cardVisible || !chromeVisible ? 0 : 1)
                        .allowsHitTesting(!cardVisible && chromeVisible)
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
                let falloff = max(0.38, 1.0 - Double(distance) * 0.34)
                // CarouselView's reveal gating: the current slide
                // stays hidden until the hero lands (the flying thumb
                // IS the visual); neighbors wait for the chrome fade.
                let slideOpacity: Double = i == index
                    ? (liveSlideVisible ? falloff : 0)
                    : (chromeVisible ? falloff : 0)
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
                .opacity(slideOpacity)
                .background {
                    // Report the current slide's frame so the hero
                    // knows where to land / launch from.
                    if i == index {
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { onSlideFrame(geo.frame(in: .named(spaceName))) }
                                .onChange(of: geo.frame(in: .named(spaceName))) { _, frame in
                                    onSlideFrame(frame)
                                }
                        }
                    }
                }
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

import SwiftUI

/// "Add me on Yafa" share flow. Presented from the profile-home
/// share button. Mirrors the ShareCardComposer sheet pattern:
/// a card preview front-and-center, a swipeable carousel to pick
/// which outfit rides on the card, and a share CTA that hands off
/// to the system share sheet.
///
/// The card itself reuses the Mono share-card design language —
/// cardGray background, Inter Medium Italic labels 8% from the
/// edges — with profile-specific copy: "add me on Yafa!" on top,
/// the @username on the bottom, and the chosen outfit spinning in
/// the middle (drag to rotate, auto-rotates when idle).
///
/// What gets shared: the web profile card URL
/// (yafafits.com/u/{username}?o={outfitId}). The recipient sees
/// the same card rendered on the web — outfit included — plus the
/// waitlist CTA. The `o` param tells the web page which outfit to
/// feature so sender choice survives the trip.
struct ProfileShareSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex = 0
    @State private var cardVisible = false
    /// URL being handed to the system share sheet. Set at tap
    /// time (not view-build time) so the selected outfit is
    /// guaranteed to be the one captured in the link.
    @State private var activeShareURL: URL? = nil
    /// Live horizontal drag offset while the user is swiping
    /// through outfits. Same continuous-strip mechanic as the
    /// ShareCardComposer template carousel.
    @State private var carouselDragOffset: CGFloat = 0
    /// Fractional dot position while the user is scrubbing the
    /// dot picker. nil at rest.
    @State private var dotScrubPosition: CGFloat? = nil
    /// On-demand bust cutout for the empty-state card when the user
    /// has a photo but no existing cutout (e.g. minimal/curved header
    /// style). Generated once via FAL bg-removal, then uploaded so the
    /// web/OG card and the next launch reuse it.
    @State private var bustCutout: UIImage? = nil
    @State private var isGeneratingBust = false
    /// Once-ever flag for the publish explainer pop-up — shown the
    /// first time the card has nothing published to feature, or the
    /// user reaches the end of their carousel.
    // Key bumped to .v2 to re-surface the publish hint after the
    // copy/icon refresh — resets the one-time "seen" state so the
    // explainer pops once more for everyone who'd already dismissed it.
    @AppStorage("yafa.shareCardPublishHintSeen.v2") private var publishHintSeen = false
    @State private var showPublishModal = false

    private let cardGray = Color(white: 0.918)

    /// Card width is height-constrained inside the 560pt carousel
    /// area (560 - 100 shadow budget = 460 → ×342/480). Computed
    /// from UIScreen (like the composer does) so the carousel and
    /// the dot picker agree on the same step without plumbing
    /// geometry between them.
    private var cardWidthEstimate: CGFloat {
        min(UIScreen.main.bounds.width - 48, 460 * (342.0 / 480.0))
    }

    /// Distance between neighboring outfits in the strip. Smaller
    /// than the card width so the previous/next outfits peek in
    /// from the card's edges.
    private var carouselStep: CGFloat { cardWidthEstimate * 0.62 }

    /// Small, curated outfit selection: up to 3 favorites (most
    /// recent first) then latest outfits to fill, deduped, max 6.
    /// Curation beats completeness here — the full archive lives
    /// in the grid; this is a "pick your look" moment.
    ///
    /// Restricted to PUBLIC outfits: the web profile card can only
    /// feature outfits that are `is_public` in Supabase, and it
    /// silently falls back to the latest public one for anything it
    /// can't resolve. Offering private/unsynced (e.g. bundled) outfits
    /// here would let the user "pick" a look that the recipient never
    /// sees — every such pick collapses to the same fallback outfit.
    /// True when the user has synced-but-unpublished fits
    /// (`isPublic == false`) — i.e. fits that *could* be featured if
    /// published. Drives the empty-state hint. (`nil` = bundled/local,
    /// which can't be featured at all, so it doesn't count.)
    private var hasUnpublishedFits: Bool {
        store.sortedOutfits.contains { $0.isPublic == false }
    }

    /// Presents the publish explainer pop-up once (ever). Marks it
    /// seen on present so it never re-pops.
    private func presentPublishHint(afterDelay delay: Double = 0) {
        guard !publishHintSeen else { return }
        publishHintSeen = true
        let show = {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                showPublishModal = true
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: show)
        } else {
            show()
        }
    }

    private func dismissPublishHint() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            showPublishModal = false
        }
    }

    private var shareableOutfits: [Outfit] {
        let sorted = store.sortedOutfits.filter { $0.isPublic == true }
        let favorites = sorted.filter { store.likedIds.contains($0.id) }.prefix(3)
        let latest = sorted.prefix(4)
        var seen = Set<String>()
        var result: [Outfit] = []
        for outfit in Array(favorites) + Array(latest) {
            guard seen.insert(outfit.id).inserted else { continue }
            result.append(outfit)
            if result.count >= 6 { break }
        }
        return result
    }

    private var selectedOutfit: Outfit? {
        let outfits = shareableOutfits
        guard outfits.indices.contains(selectedIndex) else { return outfits.first }
        return outfits[selectedIndex]
    }

    // MARK: - Empty-state hero (no shareable outfit)

    /// Whether the user has a profile photo, so the empty-state card
    /// heroes their bust (and styles the handle as a highlighter)
    /// rather than showing the silhouette + plain label.
    private var hasProfilePhoto: Bool {
        store.currentAvatarCutoutImage != nil
        || store.currentAvatarImage != nil
        || !((store.currentProfile?.avatarUrl ?? "").isEmpty)
    }

    /// Accent color for the bust handle highlighter — the user's
    /// chosen header accent, or the default if they haven't set one.
    private var bustAccentColor: Color {
        ProfileHeaderAccentColor.color(
            for: store.currentProfile?.headerAccentColor ?? ProfileHeaderAccentColor.defaultHex
        )
    }

    /// Centerpiece when the user has no shareable outfit. Prefers the
    /// background-removed bust, then the circle avatar (in-memory,
    /// else fetched from the profile URL), and finally the logo
    /// silhouette placeholder when there's no profile photo at all.
    @ViewBuilder
    private func emptyStateHero(height: CGFloat) -> some View {
        if let cutout = store.currentAvatarCutoutImage ?? bustCutout {
            Image(uiImage: cutout)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .transition(.opacity)
        } else if let cutoutURL = remoteURL(store.currentProfile?.avatarCutoutUrl) {
            // Remote bust cut-out beats the circle avatar — the share card
            // always heroes the bust whenever a photo exists, regardless of the
            // user's header style. (Previously the in-memory circle avatar was
            // checked first, so a cut-out that only existed as a saved URL got
            // skipped — the rounded-avatar regression.)
            AsyncImage(url: cutoutURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit).frame(height: height)
                } else if let avatar = store.currentAvatarImage {
                    // Cut-out still downloading → show the circle avatar meanwhile.
                    Image(uiImage: avatar).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: height, height: height).clipShape(Circle())
                } else {
                    silhouette(height: height)
                }
            }
        } else if let avatar = store.currentAvatarImage {
            Image(uiImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: height, height: height)
                .clipShape(Circle())
        } else if let avatarURL = remoteURL(store.currentProfile?.avatarUrl) {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: height, height: height).clipShape(Circle())
                } else {
                    silhouette(height: height)
                }
            }
        } else {
            silhouette(height: height)
        }
    }

    @ViewBuilder
    private func silhouette(height: CGFloat) -> some View {
        if let image = Self.silhouetteImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        }
    }

    /// Generates a bust cutout for the empty-state card on demand when
    /// the user has a photo but no cutout yet (e.g. minimal/curved
    /// header style). Background-removes the avatar via FAL, swaps it
    /// in, and uploads + persists `avatar_cutout_url` so the web/OG
    /// card and the next launch reuse it (without changing the user's
    /// header style). No-op if a cutout already exists, there's no
    /// photo, or there are shareable outfits to feature instead — so
    /// it runs at most once per avatar.
    private func ensureBustCutout() async {
        guard shareableOutfits.isEmpty,
              store.currentAvatarCutoutImage == nil,
              bustCutout == nil,
              !isGeneratingBust,
              (store.currentProfile?.avatarCutoutUrl ?? "").isEmpty,
              let userId = store.userId
        else { return }

        // Source: the in-memory avatar, else download it from the URL.
        var source = store.currentAvatarImage
        if source == nil,
           let urlString = store.currentProfile?.avatarUrl,
           !urlString.isEmpty,
           let url = URL(string: urlString),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            source = UIImage(data: data)
        }
        guard let avatar = source,
              let jpeg = avatar.jpegData(compressionQuality: 0.92)
        else { return }

        await MainActor.run { isGeneratingBust = true }
        defer { Task { await MainActor.run { isGeneratingBust = false } } }

        do {
            let resultData = try await FalBackgroundRemovalService.shared
                .removeBackground(from: jpeg) { _ in }
            guard let cutout = UIImage(data: resultData) else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { bustCutout = cutout }
            }
            // Persist for the web/OG card + next launch. Targeted
            // write — leaves the user's header style untouched.
            if let cutoutURL = try? await AvatarService.uploadAvatarCutout(cutout, userId: userId) {
                try? await SocialService.updateAvatarCutoutUrl(userId: userId, url: cutoutURL)
                await MainActor.run { store.currentProfile?.avatarCutoutUrl = cutoutURL }
            }
        } catch {
            // Silent — falls back to the circle avatar.
        }
    }

    private func remoteURL(_ string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return URL(string: string)
    }

    /// The single-figure logo silhouette (`placeholder-1.webp`),
    /// loaded once from the bundle. Same asset family the
    /// outfit-generation placeholders use.
    private static let silhouetteImage: UIImage? = {
        guard let url = Bundle.main.url(forResource: "placeholder-1", withExtension: "webp"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }()

    /// The Yafa brand mark (`logo.png`, the figure lineup), loaded once. Sits in
    /// the bottom-right corner of every share card.
    private static let logoImage: UIImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }()

    /// Tilt-reactive "shine": light-gray base + a bright highlight that slides
    /// across the content's shape as the phone moves (driven by the same
    /// `HoloMotionTracker` as the holo card), like light catching frosted paper.
    private struct TiltShine: ViewModifier {
        var base: Color = Color(white: 0.66)

        func body(content: Content) -> some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let roll = HoloMotionTracker.shared.roll
                let pitch = HoloMotionTracker.shared.pitch
                let cx = min(max(0.5 + roll * 0.45, 0.0), 1.0)
                let cy = min(max(0.5 - pitch * 0.45, 0.0), 1.0)
                content
                    .foregroundStyle(base)
                    .overlay {
                        // Soft elliptical glow that drifts in 2D with tilt — reads
                        // like light pooling on the surface, not a hard band.
                        EllipticalGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0.0),
                                .init(color: .white.opacity(0.16), location: 0.5),
                                .init(color: .white.opacity(0.0), location: 1.0),
                            ],
                            center: UnitPoint(x: cx, y: cy),
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.9
                        )
                        .blendMode(.plusLighter)
                        .mask(content)
                    }
            }
        }
    }

    /// Text/stack with a very thin white outline behind the tilt-shine fill.
    private struct ShinyStroked<Content: View>: View {
        var strokeWidth: CGFloat = 0.8
        @ViewBuilder var content: () -> Content

        var body: some View {
            ZStack {
                // Thin white outline — 8 offset white copies behind the fill.
                ForEach(0..<8, id: \.self) { i in
                    let a = Double(i) / 8.0 * 2.0 * Double.pi
                    content()
                        .foregroundStyle(.white)
                        .offset(x: strokeWidth * CGFloat(cos(a)),
                                y: strokeWidth * CGFloat(sin(a)))
                }
                content().modifier(TiltShine())
            }
        }
    }

    private var shareURL: URL? {
        guard let username = store.currentProfile?.username, !username.isEmpty
        else { return nil }
        var components = URLComponents(string: "https://yafafits.com/u/\(username)")
        if let outfitId = selectedOutfit?.id {
            components?.queryItems = [URLQueryItem(name: "o", value: outfitId)]
        }
        return components?.url
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)

                Spacer(minLength: LayoutMetrics.medium)

                cardCarousel
                    .offset(y: cardVisible ? 0 : 72)
                    .opacity(cardVisible ? 1 : 0)
                    .scaleEffect(cardVisible ? 1 : 0.88)
                    .rotation3DEffect(
                        .degrees(cardVisible ? 0 : 18),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.4
                    )

                pageDots
                    .padding(.top, 14)
                    .opacity(cardVisible ? 1 : 0)

                Spacer(minLength: LayoutMetrics.large)

                shareButton
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardVisible ? 0 : 16)
            }

            // Publish explainer pop-up — app-standard modal style.
            publishHintModal
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.05)) {
                cardVisible = true
            }
            // Empty-state explainer: if there's nothing published to
            // feature (but the user has fits), pop the hint once.
            if shareableOutfits.isEmpty && hasUnpublishedFits {
                presentPublishHint(afterDelay: 0.45)
            }
        }
        .task {
            // Auto-generate the bust for the empty-state card if the
            // user has a photo but no cutout yet (runs at most once).
            await ensureBustCutout()
        }
        .onChange(of: selectedIndex) { _, newIndex in
            // First time the user swipes to the end of their carousel,
            // pop the publish hint once (ever). Only meaningful with
            // more than one fit.
            guard shareableOutfits.count > 1,
                  newIndex >= shareableOutfits.count - 1
            else { return }
            presentPublishHint()
        }
    }

    // MARK: - Publish explainer pop-up

    /// App-standard centered modal (mirrors `InfoExplainerModal`):
    /// dim backdrop + `appCard` with icon, title, message, GOT IT.
    @ViewBuilder
    private var publishHintModal: some View {
        if showPublishModal {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissPublishHint() }
                    .transition(.opacity)

                VStack(spacing: LayoutMetrics.medium) {
                    AppIcon(glyph: .globe, size: 22, color: AppPalette.textStrong)
                        .padding(.top, LayoutMetrics.small)

                    VStack(spacing: LayoutMetrics.small) {
                        Text("Feature your fits")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)

                        Text("You can only feature the fits you've already published to the feed.")
                            .font(.system(size: 15))
                            .foregroundStyle(AppPalette.textMuted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: { dismissPublishHint() }) {
                        Text("GOT IT")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .appCapsule(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .padding(.top, LayoutMetrics.xSmall)
                }
                .padding(.horizontal, LayoutMetrics.large)
                .padding(.vertical, LayoutMetrics.large)
                .appCard(cornerRadius: 24, shadowRadius: 28, shadowY: 12)
                .padding(.horizontal, LayoutMetrics.medium)
                .transition(
                    .scale(scale: 0.92, anchor: .center).combined(with: .opacity)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }

    // MARK: - Header (matches app modal pattern)

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(SolidPressButtonStyle())
            .accessibilityLabel("Close")

            Spacer()

            Text("SHARE PROFILE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Fixed card + outfit strip carousel

    /// The card frame (gray background + labels) stays FIXED;
    /// the outfits live in a continuous horizontal strip ABOVE
    /// the card — unclipped, so the previous/next outfits peek in
    /// from the card's edges and the drag reads as a carousel.
    /// Same continuous-offset mechanic as the ShareCardComposer's
    /// template carousel (drag moves the strip live; release
    /// snaps to the nearest index on translation/velocity
    /// thresholds).
    private var cardCarousel: some View {
        let outfits = shareableOutfits
        let step = carouselStep

        return GeometryReader { geo in
            // Budget vertical room for the drop shadow's blur
            // falloff (radius 16, y 10 → ~30pt visible extent,
            // 50pt budgeted each side for clean fade-out).
            let heightBudget = geo.size.height - 100
            let cardWidth = min(geo.size.width - 48, heightBudget * (342.0 / 480.0))
            let cardHeight = cardWidth * (480.0 / 342.0)
            let scale = cardWidth / 345.0
            // 7.5% of card width (was the Mono date's 10.4%) — the
            // profile labels are longer than a month name, so the
            // type is dialed back to let the outfit lead. Matches
            // the web ProfileShareCard's `min(7.5cqw, 30px)`.
            let labelFont = Font.custom("Inter28pt-MediumItalic", size: 26 * scale)
            let stripBaseOffset =
                geo.size.width / 2 - CGFloat(selectedIndex) * step

            // Distance of outfit i from the visible center, in
            // fractional index units. Updates live during a drag
            // so the neighbor scale/fade interpolates smoothly.
            let relativePos: (Int) -> CGFloat = { i in
                CGFloat(i) - CGFloat(selectedIndex) + carouselDragOffset / step
            }

            ZStack {
                // Fixed card. With no shareable outfit, the card
                // itself carries the pro-card holo shimmer — on every
                // share card (outfit or empty state), so the card
                // always reads as a designed, holographic piece.
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .fill(cardGray)
                    .frame(width: cardWidth, height: cardHeight)
                    .holoOverlay(active: true, cornerRadius: 24 * scale)
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
                    // Yafa brand mark, bottom-left of every card.
                    .overlay(alignment: .bottomLeading) {
                        if let logo = Self.logoImage {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(width: cardWidth * 0.22)
                                .padding(.leading, 16 * scale)
                                .padding(.bottom, 14 * scale)
                                .allowsHitTesting(false)
                        }
                    }

                // "add me on" — small, Adieu Black, top-left.
                ShinyStroked(strokeWidth: 0.8 * scale) {
                    Text("add me on")
                        .font(.custom("GTFAdieuTRIAL-BlackSlanted", size: 30 * scale))
                }
                .frame(width: cardWidth, alignment: .leading)
                .padding(.leading, 18 * scale)
                .offset(y: -cardHeight * 0.42)
                .allowsHitTesting(false)

                // Big vertical "yafa" wordmark down the RIGHT edge (Adieu Black) —
                // like PUMA on a vintage trading card.
                ShinyStroked(strokeWidth: 1.0 * scale) {
                    VStack(spacing: -cardHeight * 0.04) {
                        ForEach(Array("yafa".enumerated()), id: \.offset) { _, ch in
                            Text(String(ch))
                                .font(.custom("GTFAdieuTRIAL-BlackSlanted", size: cardHeight * 0.22))
                        }
                    }
                }
                .padding(.trailing, 12 * scale)
                .frame(width: cardWidth, height: cardHeight, alignment: .trailing)
                .allowsHitTesting(false)

                // Bottom @handle label — for the outfit and silhouette
                // cards. The photo-bust card instead overlaps the
                // handle on the photo's bottom edge (below), so it's
                // skipped here in that case.
                if !(outfits.isEmpty && hasProfilePhoto) {
                    Text("@\(store.currentProfile?.username ?? "")")
                        .font(labelFont)
                        .tracking(-1.13 * scale)
                        .foregroundStyle(.black)
                        .offset(y: cardHeight * 0.42)
                        .allowsHitTesting(false)
                }

                if outfits.isEmpty {
                    if hasProfilePhoto {
                        // Photo bust — sized down so it reads as a
                        // portrait, with the @handle in the bust
                        // style's highlighter blob anchored so its
                        // first line overlaps the photo's bottom edge
                        // (matching the profile bust treatment).
                        emptyStateHero(height: cardHeight * 0.41)
                            .overlay(alignment: .bottom) {
                                HighlighterUsername(
                                    text: "@\(store.currentProfile?.username ?? "")",
                                    color: bustAccentColor,
                                    fontSize: 22 * scale,
                                    rotation: ProfileHeaderMetrics.highlighterRotation
                                )
                                .alignmentGuide(VerticalAlignment.bottom) { dims in
                                    dims[VerticalAlignment.top]
                                }
                                .offset(y: -22 * scale * 0.5)
                            }
                            .allowsHitTesting(false)
                    } else {
                        // No photo — logo silhouette placeholder.
                        emptyStateHero(height: cardHeight * 0.64)
                            .allowsHitTesting(false)
                    }
                } else {
                    // Outfit strip — floats over the card, unclipped.
                    // Neighbors shrink + fade by distance from center.
                    ZStack {
                        ForEach(Array(outfits.enumerated()), id: \.element.id) { i, outfit in
                            let pos = relativePos(i)
                            let proximity = max(0, 1 - abs(pos))
                            RotatableOutfitImage(
                                outfit: outfit,
                                height: cardHeight * 0.64,
                                draggable: false,
                                eagerLoad: true,
                                // Only the centered outfit spins — neighbors
                                // hold still until they're swiped into the
                                // card. (RotatableOutfitImage reacts to this
                                // flag changing, so promotion on page-change
                                // starts the spin.)
                                autoRotate: i == selectedIndex
                            )
                            .scaleEffect(0.72 + 0.28 * proximity)
                            .offset(x: pos * step)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: cardHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Nothing to swipe with 0 or 1 outfit (the
                        // empty-state hero is fixed, not a carousel).
                        guard outfits.count > 1 else { return }
                        carouselDragOffset = value.translation.width
                    }
                    .onEnded { value in
                        guard outfits.count > 1 else { return }
                        let translation = value.translation.width
                        let velocity = value.predictedEndTranslation.width
                        var newIndex = selectedIndex
                        if translation < -50 || velocity < -200 {
                            newIndex = min(selectedIndex + 1, outfits.count - 1)
                        } else if translation > 50 || velocity > 200 {
                            newIndex = max(selectedIndex - 1, 0)
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            selectedIndex = newIndex
                            carouselDragOffset = 0
                        }
                    }
            )
        }
        .frame(height: 560)
    }

    // MARK: - Dot picker (matches ShareCardComposer.templatePicker)

    /// Fractional "lens" position for the dot magnification. A dot
    /// scrub wins; otherwise tracks the selected index plus any
    /// in-progress strip drag so the lens slides with the swipe.
    private var pickerActivePosition: CGFloat {
        if let scrub = dotScrubPosition { return scrub }
        return CGFloat(selectedIndex) + (-carouselDragOffset / carouselStep)
    }

    private var pageDots: some View {
        let outfits = shareableOutfits
        // Small / flat at rest; bigger dots, wider spacing, and the
        // magnifying lens only while interacting (scrubbing the
        // dots or dragging the strip).
        let isActive = dotScrubPosition != nil || abs(carouselDragOffset) > 0.5
        let dotSize: CGFloat = isActive ? 6 : 4
        let dotSpacing: CGFloat = isActive ? 18 : 11
        let maxScale: CGFloat = isActive ? 2.4 : 1.0
        let spread: CGFloat = 2.0
        let active = pickerActivePosition
        let activeIntClamped = Int(round(
            max(0, min(CGFloat(outfits.count - 1), active))
        ))

        return GeometryReader { geo in
            let totalWidth = CGFloat(max(0, outfits.count - 1)) * dotSpacing
            let leadingX = (geo.size.width - totalWidth) / 2

            ZStack {
                ForEach(outfits.indices, id: \.self) { i in
                    let centerX = leadingX + CGFloat(i) * dotSpacing
                    let d = abs(active - CGFloat(i))
                    let proximity = max(0, 1 - d / spread)
                    let scale = 1 + (maxScale - 1) * proximity * proximity
                    let isSelected = i == activeIntClamped

                    Circle()
                        .fill(isSelected ? AppPalette.textSecondary : AppPalette.textFaint)
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(scale)
                        .position(x: centerX, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard outfits.count > 1 else { return }
                        let relativeX = value.location.x - leadingX
                        let frac = relativeX / dotSpacing
                        let clamped = max(0, min(CGFloat(outfits.count - 1), frac))
                        dotScrubPosition = clamped

                        let snapped = Int(round(clamped))
                        if snapped != selectedIndex {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                selectedIndex = snapped
                            }
                        }
                    }
                    .onEnded { _ in
                        // Let the lens settle back onto the selected
                        // outfit — the spring is what produces the
                        // "magnetism" feel.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            dotScrubPosition = nil
                        }
                    }
            )
        }
        .frame(height: 36)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: isActive)
    }

    // MARK: - Share CTA

    /// Plain Button + manual UIActivityViewController instead of
    /// ShareLink: the action closure reads `shareURL` at TAP time
    /// (guaranteeing the currently-selected outfit is in the link)
    /// and gives us a reliable hook for the analytics event —
    /// `.simultaneousGesture` never fires on ShareLink taps.
    private var shareButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            guard let url = shareURL else { return }
            Analytics.log("profile_share_tapped", properties: [
                "outfit_id": .string(selectedOutfit?.id ?? "none"),
                "url": .string(url.absoluteString)
            ])
            activeShareURL = url
        } label: {
            Text("SHARE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(shareURL == nil)
        .sheet(isPresented: Binding(
            get: { activeShareURL != nil },
            set: { if !$0 { activeShareURL = nil } }
        )) {
            if let url = activeShareURL {
                ShareActivityView(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

/// Thin UIActivityViewController wrapper for SwiftUI.
private struct ShareActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

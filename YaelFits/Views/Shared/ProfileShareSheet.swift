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
    /// Baked chrome normal map, loaded on appear and released when the sheet is
    /// dismissed (this @State deallocates with the view) — rather than a
    /// process-lifetime static cache, so it holds zero memory while closed.
    @State private var chromeNormalMap: UIImage?
    /// URL being handed to the system share sheet. Set at tap
    /// time (not view-build time) so the selected outfit is
    /// guaranteed to be the one captured in the link.
    @State private var activeShareURL: URL? = nil
    /// Live horizontal drag offset while the user is swiping
    /// through outfits. Same continuous-strip mechanic as the
    /// ShareCardComposer template carousel.
    @State private var carouselDragOffset: CGFloat = 0
    // MARK: Invite flip
    /// Tap the card to flip it: the back reveals the user's one-time
    /// invite code (minted lazily by `current_invite_code()`, within
    /// the quota Yael granted). Users with no quota never see any of
    /// this — the card simply doesn't flip.
    @State private var isFlipped = false
    @State private var flipAngle: Double = 0
    @State private var invite: SocialService.InviteCodeInfo?
    @State private var claimedInvites: [SocialService.ClaimedInvite] = []
    /// Invite text being handed to the system share sheet (the
    /// flipped card's SHARE shares the code, not the profile link).
    @State private var activeInviteShareText: String? = nil
    /// Brief "copied!" confirmation after tapping the code.
    @State private var showCopiedCode = false
    /// What the current drag is steering — decided ONCE at drag
    /// start by where the finger landed (the outfit's vertical band
    /// = carousel; the card's free space above/below it = flip) and
    /// held for the whole gesture.
    private enum CardDragMode { case carousel, flip }
    @State private var cardDragMode: CardDragMode? = nil
    /// flipAngle at the moment the flip drag began.
    @State private var flipDragBase: Double = 0
    /// Vertical finger-follow tilt (degrees, x-axis) while dragging
    /// the card — the web card's pointer-tilt, translated to touch.
    @State private var cardTiltX: Double = 0
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
            CachedRemoteImage(url: cutoutURL, maxPixelSize: 1000, contentMode: .fit) {
                // Cut-out still downloading → show the circle avatar meanwhile.
                if let avatar = store.currentAvatarImage {
                    Image(uiImage: avatar).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: height, height: height).clipShape(Circle())
                } else {
                    silhouette(height: height)
                }
            }
            .frame(height: height)
        } else if let avatar = store.currentAvatarImage {
            Image(uiImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: height, height: height)
                .clipShape(Circle())
        } else if let avatarURL = remoteURL(store.currentProfile?.avatarUrl) {
            CachedRemoteImage(url: avatarURL, maxPixelSize: 480, contentMode: .fill) {
                silhouette(height: height)
            }
            .frame(width: height, height: height)
            .clipShape(Circle())
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

    /// Loads the baked NORMAL MAP of the "add me on yafa" wordmark (rgb =
    /// surface normal, a = coverage). The Chrome.metal shader reflects a live
    /// chrome environment off it; the image itself is just geometry. Called off
    /// the main thread on appear so the ~1.3MB decode never hitches sheet open.
    private static func loadChromeNormalMap() -> UIImage? {
        guard let url = Bundle.main.url(forResource: "share-chrome-normal", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }

    /// Live chrome wordmark: the baked normal map driven through Chrome.metal,
    /// which reflects a procedural chrome environment (sky / sharp horizon /
    /// ground + moving hot spot) and SHIFTS that reflection with device tilt
    /// (same `HoloMotionTracker` as the holo card). That live, tilt-driven
    /// reflection is what makes it read as real chrome rather than a flat
    /// sticker — a static baked image cannot.
    private struct ChromeWordmark: View {
        let image: UIImage
        @State private var start = Date()
        /// Attitude (radians) captured on the first CoreMotion sample
        /// after the card opens. The shader gets the DELTA from this
        /// baseline, so the reflection starts dead-centered on the
        /// letters at whatever angle the phone is actually held —
        /// absolute tilt used to pre-shift it by the hold angle, which
        /// forced a timid sweep gain to keep the chrome from washing
        /// into the sky at rest.
        @State private var baseline: (roll: Double, pitch: Double)?

        /// Hand-tilt range (radians) mapped to ±1 AROUND THE BASELINE.
        /// Tighter than the tracker's absolute 0.7 — calibration means
        /// a small deliberate wrist turn should traverse the whole
        /// environment.
        private static let sweepRange: Double = 0.45

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = Float(tl.date.timeIntervalSince(start))
                let tracker = HoloMotionTracker.shared
                let base = baseline ?? (tracker.rollRadians, tracker.pitchRadians)
                let roll = Float(max(-1, min(1, (tracker.rollRadians - base.roll) / Self.sweepRange)))
                let pitch = Float(max(-1, min(1, (tracker.pitchRadians - base.pitch) / Self.sweepRange)))
                Image(uiImage: image)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorEffect(
                        ShaderLibrary.chromeReflect(
                            .float(roll),
                            .float(pitch),
                            .float(t)
                        )
                    )
            }
            // Drive CoreMotion while the card is visible (ref-counted singleton).
            .onAppear {
                HoloMotionTracker.shared.start()
                // Tracker already warm (a holo card is driving it):
                // hasSample never flips, so calibrate right here.
                if HoloMotionTracker.shared.hasSample, baseline == nil {
                    baseline = (HoloMotionTracker.shared.rollRadians,
                                HoloMotionTracker.shared.pitchRadians)
                }
            }
            .onDisappear { HoloMotionTracker.shared.stop() }
            .onChange(of: HoloMotionTracker.shared.hasSample) { _, has in
                // Calibrate once, on the first real sensor reading of
                // this presentation.
                guard has, baseline == nil else { return }
                baseline = (HoloMotionTracker.shared.rollRadians,
                            HoloMotionTracker.shared.pitchRadians)
            }
        }
    }

    /// Username chip for the card's top-right corner. Matches `WeatherPill`'s
    /// visible look (cardFill + cardBorder) and type, with a soft glow.
    private struct UsernamePill: View {
        let username: String
        let scale: CGFloat
        let normalMap: UIImage?
        let cardWidth: CGFloat
        let cardHeight: CGFloat

        var body: some View {
            // Type as before — WeatherPill weight/colour (semibold, secondary).
            Text("@\(username)")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(AppPalette.textSecondary)
                .padding(.horizontal, 11 * scale)
                .padding(.vertical, 7 * scale)
                // Real glass: blurred copy of the card art aligned to
                // this pill's top-trailing position (see CardGlassBackdrop
                // for why a sampling material can't work here).
                .background {
                    CardGlassBackdrop(
                        normalMap: normalMap,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        cornerRadius: 24 * scale,
                        center: { size in
                            CGPoint(
                                x: cardWidth - 14 * scale - size.width / 2,
                                y: 14 * scale + size.height / 2
                            )
                        }
                    )
                }
                .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                // Light-blue glow under the pill — gentle bloom.
                .shadow(
                    color: Color(red: 0.58, green: 0.81, blue: 1.0).opacity(0.55),
                    radius: 9 * scale,
                    y: 2 * scale
                )
                .shadow(
                    color: Color(red: 0.58, green: 0.81, blue: 1.0).opacity(0.35),
                    radius: 16 * scale,
                    y: 3 * scale
                )
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
        // Decode the chrome normal map off the main thread, then fade the
        // wordmark in. Held only for the life of this sheet (the @State frees
        // it on dismiss), so it costs zero memory while the sheet is closed.
        .task {
            guard chromeNormalMap == nil else { return }
            let img = await Task.detached(priority: .userInitiated) {
                Self.loadChromeNormalMap()
            }.value
            withAnimation(.easeOut(duration: 0.25)) { chromeNormalMap = img }
        }
        .task {
            // Auto-generate the bust for the empty-state card if the
            // user has a photo but no cutout yet (runs at most once).
            await ensureBustCutout()
        }
        .task {
            // Invite state for the card back. Mint-on-demand is safe
            // here: the RPC only mints for quota-holders, one active
            // code at a time.
            guard invite == nil else { return }
            do {
                invite = try await SocialService.currentInviteCode()
                #if DEBUG
                print("[Invite] state=\(invite?.state ?? "nil-row") code=\(invite?.code ?? "-") used=\(invite?.used ?? -1) quota=\(invite?.quota ?? -1)")
                #endif
            } catch {
                #if DEBUG
                print("[Invite] fetch failed: \(error)")
                #endif
            }
            if let invite, invite.quota > 0 {
                claimedInvites = (try? await SocialService.myClaimedInvites()) ?? []
            }
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

    // MARK: - Invite back face

    /// Per-frame face gate for the 3D flip. Animatable, so the
    /// visibility STEPS at 90° mid-animation (where the card is
    /// edge-on and the swap is invisible) instead of crossfading
    /// over the whole flip like a plain conditional opacity would.
    private struct FlipFace: ViewModifier, Animatable {
        var angle: Double
        let isBack: Bool
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }
        func body(content: Content) -> some View {
            // Distance from the nearest FRONT orientation (0/±360),
            // so either drag direction — and full wrap-arounds —
            // read correctly.
            content.opacity((Self.frontDistance(angle) >= 90) == isBack ? 1 : 0)
        }
        static func frontDistance(_ angle: Double) -> Double {
            var n = angle.truncatingRemainder(dividingBy: 360)
            if n > 180 { n -= 360 }
            if n < -180 { n += 360 }
            return abs(n)
        }
    }

    /// Proportional fade for the pills that float OVER the card —
    /// they dissolve as the flip starts rather than popping at the
    /// midpoint, since they don't rotate with the card.
    private struct FlipFade: ViewModifier, Animatable {
        var angle: Double
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }
        func body(content: Content) -> some View {
            content.opacity(Self.holdThenFade(angle))
        }
        /// Full opacity through the peek range (≤25°), then a fast
        /// fade — so finger play never dims anything, and the fade
        /// only plays once a flip has actually committed.
        static func holdThenFade(_ angle: Double) -> Double {
            let d = FlipFace.frontDistance(angle)
            return 1 - min(1, max(0, (d - 25) / 55))
        }
    }

    /// The outfit's tether to the card: while fading out it also
    /// slides and turns a touch WITH the flip (sin-shaped, so it
    /// always lands back at neutral), which reads as the outfit
    /// being carried by the card rather than independently vanishing.
    private struct FlipFollow: ViewModifier, Animatable {
        var angle: Double
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }
        func body(content: Content) -> some View {
            let s = sin(angle * .pi / 180)
            content
                .opacity(FlipFade.holdThenFade(angle))
                .offset(x: CGFloat(s) * 26)
                .rotation3DEffect(.degrees(s * 14), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        }
    }

    /// REAL glass for the pills, without backdrop sampling (the 3D
    /// flip flattens the card offscreen, so materials render solid
    /// white there): the pill's background is a BLURRED COPY of the
    /// card's own art — cardGray + the chrome wordmark texture —
    /// offset so the exact region under the pill shows through. True
    /// see-through optics, immune to the rotation. The copy uses the
    /// static normal-map image (not the live shader), which is what
    /// the art looks like at rest; under 10pt of blur the difference
    /// is imperceptible.
    private struct CardGlassBackdrop: View {
        let normalMap: UIImage?
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let cornerRadius: CGFloat
        /// The pill's center in CARD coordinates, given the pill's size.
        let center: (CGSize) -> CGPoint

        var body: some View {
            GeometryReader { g in
                let c = center(g.size)
                ZStack {
                    Color(white: 0.918)
                    if let normalMap {
                        Image(uiImage: normalMap)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: cardHeight * 0.9)
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .blur(radius: 10)
                // The holo shimmer is most of what actually sits under
                // the corner pills (the wordmark art lives center-left),
                // so the copy must carry it or the glass has nothing
                // visible to show. Applied over the blur: the shimmer
                // is already diffuse, and keeping it out of the blur
                // input means the blurred layer stays static and cheap.
                .holoOverlay(active: true, cornerRadius: cornerRadius, edgeBleed: 2)
                .position(
                    x: g.size.width / 2 + (cardWidth / 2 - c.x),
                    y: g.size.height / 2 + (cardHeight / 2 - c.y)
                )
            }
            .clipShape(Capsule())
            // Light frost + edge light over the blurred art — thin
            // enough that the art visibly reads through.
            .overlay(Capsule().fill(Color.white.opacity(0.18)))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.white, Color.white.opacity(0.2)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
        }
    }

    /// Remaining-invites capsule, bottom-right of the card front.
    /// Same glass treatment as the username pill.
    private struct InviteChip: View {
        let remaining: Int
        let scale: CGFloat
        let normalMap: UIImage?
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        var body: some View {
            Text(remaining > 0 ? "\(remaining) INVITE\(remaining == 1 ? "" : "S")" : "INVITES")
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textSecondary)
                .padding(.horizontal, 11 * scale)
                .padding(.vertical, 7 * scale)
                // Real glass: blurred card art aligned to this pill's
                // bottom-trailing position (see CardGlassBackdrop).
                .background {
                    CardGlassBackdrop(
                        normalMap: normalMap,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        cornerRadius: 24 * scale,
                        center: { size in
                            CGPoint(
                                x: cardWidth - 14 * scale - size.width / 2,
                                y: cardHeight - 14 * scale - size.height / 2
                            )
                        }
                    )
                }
                .overlay(
                    Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                )
                .shadow(
                    color: Color(red: 0.58, green: 0.81, blue: 1.0).opacity(0.55),
                    radius: 9 * scale,
                    y: 2 * scale
                )
                .shadow(
                    color: Color(red: 0.58, green: 0.81, blue: 1.0).opacity(0.35),
                    radius: 16 * scale,
                    y: 3 * scale
                )
        }
    }

    /// The card's physical thickness: side layers rotated with the
    /// same angles as the face but displaced in z (anchorZ), so the
    /// edge genuinely swings around in perspective as the card turns.
    /// At rest the 1.5pt y-offset keeps a hairline lip.
    /// Device-tilt response for the whole card object — the same
    /// baseline-calibrated HoloMotionTracker the chrome and holo
    /// shaders use, mapped to a gentle ±4° lean, so the physical
    /// card follows the phone the way its inks already do.
    private struct GyroTilt: ViewModifier {
        @State private var baseline: (roll: Double, pitch: Double)?
        private static let sweepRange: Double = 0.6

        func body(content: Content) -> some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let tracker = HoloMotionTracker.shared
                let base = baseline ?? (tracker.rollRadians, tracker.pitchRadians)
                let roll = max(-1, min(1, (tracker.rollRadians - base.roll) / Self.sweepRange))
                let pitch = max(-1, min(1, (tracker.pitchRadians - base.pitch) / Self.sweepRange))
                content
                    .rotation3DEffect(.degrees(roll * 4), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                    .rotation3DEffect(.degrees(pitch * 4), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
            }
            .onAppear { HoloMotionTracker.shared.start() }
            .onDisappear { HoloMotionTracker.shared.stop() }
            .task {
                // Calibrate to the user's INITIAL hold angle — the lean
                // is a delta from however they're actually holding the
                // phone, never from flat. Polling (vs onChange) makes
                // the calibration independent of observation timing:
                // it lands on the first real sample no matter when the
                // tracker warmed up.
                while baseline == nil, !Task.isCancelled {
                    if HoloMotionTracker.shared.hasSample {
                        baseline = (HoloMotionTracker.shared.rollRadians,
                                    HoloMotionTracker.shared.pitchRadians)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }

    /// What an extruded card actually shows when it turns: a side
    /// strip along the RECEDING edge that widens with the turn
    /// (w = thickness·|sin θ|) and foreshortens with the face. Drawn
    /// inside the card's own rotation, so card + edge move as one
    /// object with one clean silhouette — the stacked-slice attempts
    /// ballooned the outline and dragged the drop shadow with it.
    /// Animatable: the width must track the LIVE angle every frame.
    private struct CardEdge: View, Animatable {
        var angle: Double
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let scale: CGFloat
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }
        var body: some View {
            let sine = sin(angle * .pi / 180)
            let w = abs(sine) * 3.5
            // The side is the card's OWN rounded-rect shape, offset
            // sideways by the edge width: the visible crescent then
            // wraps the rounded corners exactly (a straight capsule
            // strip left the corners paper-thin). Gradient darkens
            // toward the outer rim of the crescent.
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.78), Color(white: 0.66)],
                        startPoint: sine > 0 ? .trailing : .leading,
                        endPoint: sine > 0 ? .leading : .trailing
                    )
                )
                // No resting lip — the side exists only while the card
                // is actually turning; at rest the edge shape hides
                // perfectly behind the face.
                .offset(x: (sine > 0 ? -1 : 1) * w)
        }
    }

    @ViewBuilder
    private func inviteBackFace(cardWidth: CGFloat, cardHeight: CGFloat, scale: CGFloat) -> some View {
        // App-consistent type on the light card: header-style tracked
        // caps in textSecondary (the sheet header's voice), the code in
        // the card family's SemiBold in textPrimary, captions in the
        // card label's MediumItalic in textMuted.
        VStack(spacing: 0) {
            Spacer()

            Text(invite?.state == "exhausted" ? "ALL INVITES USED" : "INVITE A FRIEND")
                .font(.system(size: 12 * scale, weight: .semibold))
                .tracking(3)
                .foregroundStyle(AppPalette.textSecondary)

            if let code = invite?.code {
                Text(code)
                    .font(.custom("Inter28pt-SemiBold", size: 38 * scale))
                    .tracking(3 * scale)
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(.top, 16 * scale)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIPasteboard.general.string = code
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeOut(duration: 0.15)) { showCopiedCode = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { showCopiedCode = false }
                        }
                    }
                Text(showCopiedCode ? "copied!" : "one-time code · tap to copy")
                    .font(.custom("Inter28pt-MediumItalic", size: 13 * scale))
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.top, 10 * scale)
            }

            if let invite {
                Text("\(invite.used) OF \(invite.quota) USED")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.top, 26 * scale)
            }

            if !claimedInvites.isEmpty {
                VStack(spacing: 5 * scale) {
                    ForEach(claimedInvites.prefix(3)) { claim in
                        Text("@\(claim.claimedByUsername ?? "someone") joined")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                }
                .padding(.top, 12 * scale)
            }

            Spacer()
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(alignment: .bottomLeading) {
            MadeOnYafaMark(width: cardWidth * 0.20, color: .white)
                .padding(.leading, 16 * scale)
                .padding(.bottom, 14 * scale)
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
                // Card fill + chrome wordmark + holo shimmer flattened into
                // ONE unit and clipped by a SINGLE rounded-rect mask. The
                // fill and the shimmer used to be two separately
                // anti-aliased rounded rects stacked on each other — their
                // edges can never match pixel-perfectly, which left a
                // hairline light arc at every corner. The shimmer now
                // bleeds 2pt past the edge and the one clip cuts everything
                // together; the shadow is applied AFTER the clip so it
                // still renders outside the card.
                ZStack {
                    Rectangle()
                        .fill(cardGray)

                    // FRONT face decor. Face swaps must step at exactly
                    // 90° on every animation FRAME (the card is edge-on
                    // there, so the trade is invisible) — a plain
                    // conditional opacity would crossfade over the whole
                    // flip instead; FlipFace is Animatable and re-evaluates
                    // per frame.
                    Group {
                        // Yafa brand mark, bottom-LEFT — the shared MADE ON
                        // YAFA mark reused from the export/share cards.
                        Rectangle()
                            .fill(.clear)
                            .overlay(alignment: .bottomLeading) {
                                MadeOnYafaMark(width: cardWidth * 0.20, color: .white)
                                    .padding(.leading, 16 * scale)
                                    .padding(.bottom, 14 * scale)
                            }

                        // Live chrome "add me on yafa" wordmark, behind the
                        // outfit (replaces the old plain top label). Reflects
                        // with device tilt. Loaded async on appear (see .task)
                        // and freed on dismiss.
                        if let chrome = chromeNormalMap {
                            ChromeWordmark(image: chrome)
                                .frame(height: cardHeight * 0.9)
                                .transition(.opacity)
                        }
                    }
                    .modifier(FlipFace(angle: flipAngle, isBack: false))

                    // BACK face — the invite reveal. Pre-mirrored so it
                    // reads correctly once the container rotation passes 90°.
                    inviteBackFace(cardWidth: cardWidth, cardHeight: cardHeight, scale: scale)
                        .modifier(FlipFace(angle: flipAngle, isBack: true))
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))

                    // Holographic shimmer ABOVE the chrome wordmark — a
                    // clear card-sized layer carrying the holo shader, so
                    // the iridescence rides over the chrome text (not just
                    // the bare card). Rides both faces.
                    Color.clear
                        .holoOverlay(active: true, cornerRadius: 24 * scale, edgeBleed: 2)
                }
                .frame(width: cardWidth, height: cardHeight)
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                // Hairline white rim — reads on both faces (it sits
                // above whichever one is showing), like a card's
                // printed edge highlight.
                .overlay(
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.75)
                )
                // Pills sit as overlays PAST the clip (their glow
                // survives) but INSIDE the rotation, so they are
                // physically attached to the card through the flip.
                // FlipFace hides them edge-on with the rest of the
                // front face. Photo-bust cards carry the handle in
                // their highlighter blob instead, so no pill there.
                .overlay(alignment: .topTrailing) {
                    if !(outfits.isEmpty && hasProfilePhoto) {
                        UsernamePill(
                            username: store.currentProfile?.username ?? "",
                            scale: scale,
                            normalMap: chromeNormalMap,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight
                        )
                        .padding(.trailing, 14 * scale)
                        .padding(.top, 14 * scale)
                        .modifier(FlipFace(angle: flipAngle, isBack: false))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let invite, invite.quota > 0 {
                        InviteChip(
                            remaining: max(0, invite.quota - invite.used),
                            scale: scale,
                            normalMap: chromeNormalMap,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight
                        )
                        .padding(.trailing, 14 * scale)
                        .padding(.bottom, 14 * scale)
                        .modifier(FlipFace(angle: flipAngle, isBack: false))
                    }
                }
                // Edge strip BEFORE the rotations: it must rotate with
                // the card so card + side read as one solid object.
                .background(CardEdge(angle: flipAngle, cardWidth: cardWidth, cardHeight: cardHeight, scale: scale))
                // Finger-follow tilt (x) under the flip (y) — the card
                // leans toward the finger like the web card's pointer
                // tilt, then springs flat on release.
                .rotation3DEffect(.degrees(cardTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
                .modifier(GyroTilt())
                .allowsHitTesting(false)

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
                            .modifier(FlipFollow(angle: flipAngle))
                    } else {
                        // No photo — logo silhouette placeholder.
                        emptyStateHero(height: cardHeight * 0.64)
                            .allowsHitTesting(false)
                            .modifier(FlipFollow(angle: flipAngle))
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
                    .modifier(FlipFollow(angle: flipAngle))
                }

            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Route the drag once, by START position: the
                        // outfit's vertical band swipes the carousel;
                        // the card's free space above/below it flips.
                        // While the back is up, everything flips back.
                        if cardDragMode == nil {
                            let canFlip = (invite?.quota ?? 0) > 0
                            let cardTop = (geo.size.height - cardHeight) / 2
                            let bandTop = cardTop + cardHeight * 0.18
                            let bandBottom = cardTop + cardHeight * 0.82
                            let inOutfitBand = (bandTop...bandBottom).contains(value.startLocation.y)
                            if isFlipped {
                                cardDragMode = canFlip ? .flip : .carousel
                            } else {
                                cardDragMode = (inOutfitBand || !canFlip) ? .carousel : .flip
                            }
                            // Canonicalize into (-180, 180] so the drag
                            // range below is always base ± 180 — this is
                            // what lets BOTH directions flip from either
                            // face (previously the flipped side had a
                            // dead direction against the clamp).
                            var canonical = flipAngle.truncatingRemainder(dividingBy: 360)
                            if canonical > 180 { canonical -= 360 }
                            if canonical <= -180 { canonical += 360 }
                            flipAngle = canonical
                            flipDragBase = canonical
                        }
                        switch cardDragMode {
                        case .carousel:
                            // Nothing to swipe with 0 or 1 outfit (the
                            // empty-state hero is fixed, not a carousel) —
                            // and nothing while the invite back is up.
                            guard outfits.count > 1, !isFlipped else { return }
                            carouselDragOffset = value.translation.width
                        case .flip:
                            // Subtle peek only, like the web card's
                            // pointer tilt — the card leans with the
                            // finger (≤18°) but never turns with it.
                            // The flip itself only COMMITS on release,
                            // when the drag showed real intent.
                            let peek = Double(value.translation.width / cardWidth) * 60
                            flipAngle = flipDragBase + min(18, max(-18, peek))
                            cardTiltX = min(9, max(-9, Double(-value.translation.height / cardHeight) * 14))
                        case nil:
                            break
                        }
                    }
                    .onEnded { value in
                        let mode = cardDragMode
                        cardDragMode = nil
                        switch mode {
                        case .carousel:
                            guard outfits.count > 1, !isFlipped else { return }
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
                        case .flip:
                            // Intent gate: a real swipe (travel and/or
                            // flick) commits a full spring-flip; anything
                            // less relaxes back — so casual finger play
                            // just tilts the card and never half-turns it.
                            let travel = Double(value.translation.width / cardWidth)
                            let flick = Double((value.predictedEndTranslation.width - value.translation.width) / cardWidth)
                            let intent = travel + flick * 0.5
                            if abs(intent) > 0.40 {
                                let direction: Double = intent >= 0 ? 1 : -1
                                let target = flipDragBase + direction * 180
                                isFlipped = FlipFace.frontDistance(target) >= 90
                                if isFlipped { showCopiedCode = false }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
                                    flipAngle = target
                                    cardTiltX = 0
                                }
                            } else {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                    flipAngle = flipDragBase
                                    cardTiltX = 0
                                }
                            }
                        case nil:
                            break
                        }
                    }
            )
            .onTapGesture { toggleFlip() }
        }
        .frame(height: 560)
    }

    /// Flip between the profile front and the invite back. No-op for
    /// users without invite quota — their card is just a card.
    private func toggleFlip() {
        guard let invite, invite.quota > 0 else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Canonicalize first (drag settles can leave ±180/wraps) so
        // the tap animates one clean half-turn from wherever we are.
        var canonical = flipAngle.truncatingRemainder(dividingBy: 360)
        if canonical > 180 { canonical -= 360 }
        if canonical <= -180 { canonical += 360 }
        flipAngle = canonical
        isFlipped.toggle()
        showCopiedCode = false
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
            flipAngle = isFlipped ? 180 : 0
        }
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
            if isFlipped {
                // Invite mode: share the one-time code, not the profile.
                guard let code = invite?.code else { return }
                Analytics.log("invite_share_tapped", properties: [
                    "code": .string(code)
                ])
                activeInviteShareText =
                    "You're invited to Yafa. One-time code: \(code)\nhttps://yafafits.com/i/\(code)"
                return
            }
            guard let url = shareURL else { return }
            Analytics.log("profile_share_tapped", properties: [
                "outfit_id": .string(selectedOutfit?.id ?? "none"),
                "url": .string(url.absoluteString)
            ])
            activeShareURL = url
        } label: {
            Text(isFlipped ? "SHARE INVITE" : "SHARE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isFlipped ? invite?.code == nil : shareURL == nil)
        .sheet(isPresented: Binding(
            get: { activeShareURL != nil },
            set: { if !$0 { activeShareURL = nil } }
        )) {
            if let url = activeShareURL {
                ShareActivityView(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: Binding(
            get: { activeInviteShareText != nil },
            set: { if !$0 { activeInviteShareText = nil } }
        )) {
            if let text = activeInviteShareText {
                ShareActivityView(items: [text])
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

import SwiftUI
import StoreKit

// The clip's one screen: the app's public feed card, verbatim —
// built from the SAME compiled components the app uses (appCard,
// AppIcon's hand-drawn glyphs, WeatherPill with its Lottie icons,
// AppPalette/LayoutMetrics) so the two can't drift. Cart open,
// with the App Store overlay offering the full app.
struct ClipFitView: View {
    @Bindable var model: ClipModel
    @State private var showOverlay = false
    @State private var showProfile = false
    // The app's root-level vibe effect portal — the wave shader,
    // particle burst and hero morph render above the card exactly
    // as they do above the feed.
    @State private var vibesEffectHost = VibesEffectHost()

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            switch model.phase {
            case .loading:
                ProgressView()
                    .tint(AppPalette.textMuted)
            case .unavailable:
                Text("THIS FIT ISN’T AVAILABLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.textFaint)
            case .ready:
                if let fit = model.fit {
                    ScrollView {
                        ClipFeedCard(
                            fit: fit,
                            onRequireApp: {
                                // Social actions need an account — the
                                // clip's answer is the install overlay.
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showOverlay = true
                            },
                            onOpenProfile: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showProfile = true
                            }
                        )
                        .padding(.horizontal, LayoutMetrics.small)
                        .padding(.top, LayoutMetrics.large)
                        .padding(.bottom, 120) // clear the install banner
                    }
                    .scrollIndicators(.hidden)
                }
            }

            // Yafa-styled install CTA — our own chrome instead of the
            // auto-popping system overlay. GET summons Apple's SKOverlay
            // (the only sanctioned install path); this banner just makes
            // the pitch in the app's own voice.
            if model.phase == .ready {
                VStack {
                    Spacer()
                    installBanner
                        .padding(.horizontal, LayoutMetrics.small)
                        .padding(.bottom, LayoutMetrics.xSmall)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The app root's exact vibe layer stack (YaelFitsApp):
            // distorted-snapshot wave, hero flame morph, particle
            // burst, anchored pills — all above the card, none
            // consuming touches.
            VibesWaveOverlay()
            VibesMorphLayer()
            VibesParticleLayer()
            VibesBannerLayer()
        }
        .environment(vibesEffectHost)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.phase)
        .onChange(of: model.phase) { _, phase in
            guard phase == .ready else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIP_AUTO_PROFILE"] == "1" {
                showProfile = true
                return
            }
            #endif
            // Hot path stays one tap: Apple's overlay (with its GET
            // button) auto-presents once after load. Our banner is the
            // persistent re-entry after the viewer dismisses it.
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                showOverlay = true
            }
        }
        .appStoreOverlay(isPresented: $showOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
        .sheet(isPresented: $showProfile) {
            if let fit = model.fit {
                ClipProfileSheet(
                    userId: fit.userId,
                    seedUsername: fit.username,
                    seedAvatarURL: fit.avatarURL,
                    preloaded: model.preloadedProfile,
                    onRequireApp: {
                        showProfile = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showOverlay = true
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                // Presented contexts do NOT inherit the ZStack's
                // .environment — without this, the carousel's vibe
                // layers fatal-error on a missing observable.
                .environment(vibesEffectHost)
            }
        }
    }

    /// The clip's own pitch, in the app's chrome: appCard surface,
    /// hand-drawn tshirt glyph, mono caps title, solid GET capsule.
    private var installBanner: some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            if let icon = UIImage(named: "BannerAppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                    )
            } else {
                AppIcon(glyph: .tshirt, size: 18, color: AppPalette.iconPrimary)
                    .frame(width: 40, height: 40)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("YAFA")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.textStrong)
                Text("Spin fits. Shop looks. Join in.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textSecondary)
            }

            Spacer(minLength: LayoutMetrics.xxSmall)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showOverlay = true
            } label: {
                Text("GET")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
        }
        .padding(LayoutMetrics.xSmall)
        .appCard()
    }
}

/// FeedPostCard's layout, fed by clip data. Every metric, color and
/// modifier is the app's own (LayoutMetrics / AppPalette / appCard /
/// appCircle / AppIcon / WeatherPill). Internal so the profile
/// carousel can page through the same card.
struct ClipFeedCard: View {
    let fit: ClipFit
    var onRequireApp: () -> Void
    var onOpenProfile: () -> Void
    @State private var cartOpen = true
    // Playful local reactions — they fill and count up like the app's,
    // but a clip has no account, so they live only in this moment.
    @State private var liked = false
    @State private var vibed = false
    @State private var saved = false
    // Backing state for the REAL VibeButton (stubbed service always
    // succeeds, so the vibe sticks for the clip session).
    @State private var vibeCount: Int
    @State private var remainingVibes = 3
    @State private var showComments = false
    @Environment(\.openURL) private var openURL

    init(
        fit: ClipFit,
        onRequireApp: @escaping () -> Void,
        onOpenProfile: @escaping () -> Void
    ) {
        self.fit = fit
        self.onRequireApp = onRequireApp
        self.onOpenProfile = onOpenProfile
        _vibeCount = State(initialValue: fit.vibeCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            header

            FrameSpinner(fit: fit)
                .frame(height: 292)
                .frame(maxWidth: .infinity)

            if let caption = fit.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actions
        }
        .padding(LayoutMetrics.medium)
        .appCard()
        .sheet(isPresented: $showComments) {
            ClipCommentsSheet(comments: fit.comments, onRequireApp: {
                showComments = false
                onRequireApp()
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            // Avatar + username open the creator's profile — same
            // affordance as the app's public feed.
            Button(action: onOpenProfile) {
                HStack(spacing: LayoutMetrics.xSmall) {
                    avatar

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fit.username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                        Text(fit.dateLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
            }
            .buttonStyle(SolidPressButtonStyle())

            Spacer()

            if let weather = fit.weather {
                WeatherPill(weather: weather, useFahrenheit: false)
            }
        }
    }

    private var avatar: some View {
        // The app's own AvatarView — same cache, same fallback.
        AvatarView(
            url: fit.avatarURL?.absoluteString,
            initial: String(fit.username.prefix(1)).uppercased()
        )
    }

    private var actions: some View {
        VStack(spacing: 0) {
            HStack(spacing: LayoutMetrics.xxSmall) {
                actionButton(
                    icon: .heart,
                    count: fit.likeCount + (liked ? 1 : 0),
                    filled: liked,
                    isActive: liked
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.18)) { liked.toggle() }
                }
                actionButton(icon: .comment, count: fit.commentCount) {
                    if fit.comments.isEmpty {
                        onRequireApp()
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showComments = true
                    }
                }
                actionButton(
                    icon: .bookmark,
                    filled: saved,
                    isActive: saved
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.18)) { saved.toggle() }
                }
                if !fit.products.isEmpty {
                    actionButton(icon: .cart, isActive: cartOpen) {
                        // The app's exact cart toggle curve.
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                            cartOpen.toggle()
                        }
                    }
                }
                Spacer()
                // The app's REAL vibe button — full burst choreography
                // (wave shader, particles, hero morph, haptic score).
                VibeButton(
                    outfitId: fit.outfitId,
                    vibeCount: $vibeCount,
                    isVibedByMe: $vibed,
                    remainingThisWeek: $remainingVibes
                )
            }
            .padding(.top, LayoutMetrics.xxxSmall)

            if cartOpen, !fit.products.isEmpty {
                productStrip
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
    }

    /// FeedPostCard.actionButton, verbatim — social taps hand off to
    /// the full app via the overlay (a clip has no account).
    private func actionButton(icon: AppIconGlyph, count: Int? = nil, filled: Bool = false, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
        ZStack(alignment: .topTrailing) {
            AppIcon(
                glyph: icon,
                size: 14,
                color: isActive ? AppPalette.iconActive : AppPalette.iconPrimary,
                filled: filled
            )
            .frame(width: 40, height: 40)
            .appCircle(shadowRadius: 0, shadowY: 0)
            .scaleEffect(isActive ? 0.96 : 1)

            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppPalette.textMuted)
                    .frame(minWidth: 16, minHeight: 16)
                    .background {
                        LightBlurView(style: .systemThinMaterialLight)
                            .clipShape(Circle())
                            .overlay(Circle().fill(Color.white.opacity(0.96)))
                    }
                    .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                    .offset(x: 4, y: -2)
            }
        }
        }
        .buttonStyle(SolidPressButtonStyle())
        .frame(minWidth: LayoutMetrics.touchTarget, minHeight: LayoutMetrics.touchTarget)
    }

    /// FeedPostCard's cart row, verbatim, permanently open.
    private var productStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(fit.products) { product in
                    Button {
                        // Same cascade as the app's ProductShopLink:
                        // direct shop when linked; otherwise Lens visual
                        // search in the in-app sheet (clean cookie store —
                        // Safari's logged-in Google session breaks
                        // uploadbyurl), with a Shopping name search as
                        // the sheet's own hard-failure fallback.
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
                    } label: {
                        VStack(spacing: 6) {
                            productImage(product)
                            Text("BUY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(AppPalette.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.45)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
                        }
                    }
                    .buttonStyle(SolidPressButtonStyle())
                }
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.top, LayoutMetrics.xxSmall)
            .padding(.bottom, LayoutMetrics.xxxSmall)
        }
        .padding(.horizontal, -LayoutMetrics.medium)
    }

    /// ProductImageView's look (white-28% rounded tile, contained
    /// image) without dragging in the app's cache stack.
    private func productImage(_ product: ClipProduct) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.28))
            AsyncImage(url: product.imageURL) { image in
                image.resizable().scaledToFit().padding(3)
            } placeholder: {
                Color.clear
            }
        }
        .frame(width: 56, height: 56)
    }
}


/// Read-only comment thread — the same rows the app renders, with a
/// join CTA where the composer would be. Internal: the profile
/// carousel presents it too.
struct ClipCommentsSheet: View {
    let comments: [ClipComment]
    var onRequireApp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("COMMENTS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.xSmall)

            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.small) {
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: LayoutMetrics.xxSmall + 2) {
                            AvatarView(
                                url: comment.avatarURL?.absoluteString,
                                initial: String(comment.author.prefix(1)).uppercased(),
                                size: 28
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.author)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppPalette.textStrong)
                                Text(comment.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppPalette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, LayoutMetrics.medium)
                .padding(.top, LayoutMetrics.xxSmall)
            }

            Button(action: onRequireApp) {
                Text("JOIN THE CONVERSATION")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .appCapsule(shadowRadius: 6, shadowY: 3)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.vertical, LayoutMetrics.small)
        }
        .presentationBackground(AppPalette.groupedBackground)
    }
}

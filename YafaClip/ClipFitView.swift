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
                        ClipFeedCard(fit: fit, onRequireApp: {
                            // Social actions need an account — the
                            // clip's answer is the install overlay.
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showOverlay = true
                        })
                        .padding(.horizontal, LayoutMetrics.small)
                        .padding(.top, LayoutMetrics.large)
                        .padding(.bottom, 170) // clear the overlay
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .ready else { return }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                showOverlay = true
            }
        }
        .appStoreOverlay(isPresented: $showOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }
}

/// FeedPostCard's layout, fed by clip data. Every metric, color and
/// modifier is the app's own (LayoutMetrics / AppPalette / appCard /
/// appCircle / AppIcon / WeatherPill).
private struct ClipFeedCard: View {
    let fit: ClipFit
    var onRequireApp: () -> Void
    @State private var cartOpen = true
    @Environment(\.openURL) private var openURL

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
    }

    private var header: some View {
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
                actionButton(icon: .heart, count: fit.likeCount, action: onRequireApp)
                actionButton(icon: .comment, count: fit.commentCount, action: onRequireApp)
                actionButton(icon: .bookmark, action: onRequireApp)
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
                actionButton(icon: .flame, action: onRequireApp)
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
    private func actionButton(icon: AppIconGlyph, count: Int? = nil, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
        ZStack(alignment: .topTrailing) {
            AppIcon(
                glyph: icon,
                size: 14,
                color: isActive ? AppPalette.iconActive : AppPalette.iconPrimary
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
                        if let shop = product.shopURL { openURL(shop) }
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

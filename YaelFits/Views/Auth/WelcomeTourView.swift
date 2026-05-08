import SwiftUI

/// Pre-auth feature tour shown to first-time users before the AuthView.
/// 5 swipe-able pages, each highlighting a core feature with a stylized
/// mockup + caption. Skippable from the top-right; final page CTA leads
/// to AuthView. Persists completion via `hasSeenWelcomeTour` AppStorage
/// so it never shows twice.
struct WelcomeTourView: View {
    @AppStorage("hasSeenWelcomeTour") private var hasSeenWelcomeTour = false
    @State private var pageIndex = 0

    let onComplete: () -> Void

    private let pages: [WelcomePage] = [
        WelcomePage(
            id: 0,
            eyebrow: "CAPTURE YOUR DAILY FIT",
            title: "Your style, in 3D",
            subtitle: "Log your daily outfits and watch your wardrobe come alive as a 3D avatar of yourself.",
            mockup: .avatar
        ),
        WelcomePage(
            id: 1,
            eyebrow: "QUICK ADD",
            title: "Your closet, in seconds",
            subtitle: "Tap any item to add it to your closet — a few seconds turns a screenshot into your wardrobe.",
            mockup: .quickAdd
        ),
        WelcomePage(
            id: 2,
            eyebrow: "SOCIAL",
            title: "Share with your circle",
            subtitle: "Like, comment, and follow along with what your friends are wearing every day.",
            mockup: .social
        ),
        WelcomePage(
            id: 3,
            eyebrow: "SHOP & LINK",
            title: "Shop the look, instantly",
            subtitle: "Tap any product on someone's outfit to find or buy it. Or link your own pieces for fans to shop.",
            mockup: .shop
        ),
        WelcomePage(
            id: 4,
            eyebrow: "SHARE",
            title: "Beautiful daily cards",
            subtitle: "Turn every OOTD into a stunning share card — designed for your story or feed.",
            mockup: .ootd
        )
    ]

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                pager
                pageIndicator
                    .padding(.bottom, LayoutMetrics.medium)
                continueButton
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                complete()
            } label: {
                Text("SKIP")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: $pageIndex) {
            ForEach(pages) { page in
                WelcomePageView(page: page, isVisible: pageIndex == page.id)
                    .tag(page.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.25), value: pageIndex)
    }

    // MARK: - Page dots

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == pageIndex ? AppPalette.textPrimary : AppPalette.textFaint.opacity(0.35))
                    .frame(width: i == pageIndex ? 22 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: pageIndex)
            }
        }
    }

    // MARK: - Continue / Get Started

    private var continueButton: some View {
        // Matches AuthView's primary action: tracked uppercase label on
        // a frosted .appCapsule, with shadow on the active state. Same
        // visual language as the rest of the app's primary buttons.
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if pageIndex < pages.count - 1 {
                withAnimation(.easeInOut(duration: 0.30)) {
                    pageIndex += 1
                }
            } else {
                complete()
            }
        } label: {
            Text(pageIndex == pages.count - 1 ? "GET STARTED" : "CONTINUE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .appCapsule(shadowRadius: 8, shadowY: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, LayoutMetrics.screenPadding + 8)
        .padding(.bottom, LayoutMetrics.large)
    }

    private func complete() {
        hasSeenWelcomeTour = true
        onComplete()
    }
}

// MARK: - Page model

private struct WelcomePage: Identifiable {
    let id: Int
    let eyebrow: String
    let title: String
    let subtitle: String
    let mockup: WelcomeMockup
}

private enum WelcomeMockup {
    case avatar, quickAdd, social, shop, ootd
}

// MARK: - Page view

private struct WelcomePageView: View {
    let page: WelcomePage
    let isVisible: Bool

    @State private var animateIn = false

    var body: some View {
        VStack(spacing: 0) {
            // Eyebrow + title at the TOP — sets context first.
            VStack(spacing: 10) {
                Text(page.eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.textFaint)

                Text(page.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, LayoutMetrics.large)
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 8)
            .padding(.top, LayoutMetrics.small)
            .padding(.bottom, LayoutMetrics.medium)

            // Media (mockup or — eventually — looping video) in the
            // MIDDLE. Takes up the remaining flexible vertical space.
            mockupArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, LayoutMetrics.screenPadding + 8)

            // Description at the BOTTOM — final caption beat.
            Text(page.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, LayoutMetrics.large)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.large)
                .opacity(animateIn ? 1 : 0)
                .offset(y: animateIn ? 0 : 8)
        }
        .onChange(of: isVisible, initial: true) { _, newValue in
            animateIn = false
            if newValue {
                withAnimation(.easeOut(duration: 0.55).delay(0.05)) {
                    animateIn = true
                }
            }
        }
    }

    @ViewBuilder
    private var mockupArea: some View {
        switch page.mockup {
        case .avatar: AvatarMockup(animate: animateIn)
        case .quickAdd: QuickAddMockup(animate: animateIn)
        case .social: SocialMockup(animate: animateIn)
        case .shop: ShopMockup(animate: animateIn)
        case .ootd: OOTDMockup(animate: animateIn)
        }
    }
}

// MARK: - Mockup primitives

/// Card-style frame used as the backdrop for every mockup. Matches the
/// rest of the app's aesthetic (frosted, soft shadow, rounded corners).
private struct MockupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white)
                .shadow(color: AppPalette.cardShadow, radius: 24, y: 14)
            content()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .aspectRatio(0.78, contentMode: .fit)
    }
}

/// Tag/pill used for floating UI bits (e.g., "+ Top", "BUY", etc).
private struct FloatingPill: View {
    let icon: String?
    let text: String
    var background: Color = .white
    var foreground: Color = AppPalette.textPrimary

    var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(background))
        .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.5))
        .shadow(color: AppPalette.cardShadow.opacity(0.6), radius: 6, y: 3)
    }
}

// MARK: - Mockup 1: Avatar

private struct AvatarMockup: View {
    let animate: Bool

    var body: some View {
        MockupCard {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.97, blue: 1.00),
                        Color(red: 0.94, green: 0.95, blue: 0.99),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Stylized silhouette in the center.
                // (SF Symbol; `Image("AppIcon")` is reserved by iOS for
                // the home-screen icon and won't render here.)
                Image(systemName: "figure.stand")
                    .font(.system(size: 130, weight: .light))
                    .foregroundStyle(AppPalette.textStrong)
                    .padding(.bottom, 8)

                // Floating outfit chips around the silhouette.
                VStack {
                    HStack {
                        FloatingPill(icon: "tshirt.fill", text: "TOP")
                            .offset(x: animate ? 0 : -16, y: animate ? 0 : -8)
                            .opacity(animate ? 1 : 0)
                            .animation(.easeOut(duration: 0.45).delay(0.20), value: animate)
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        FloatingPill(icon: "shoeprints.fill", text: "SHOES")
                            .offset(x: animate ? 0 : 16, y: animate ? 0 : 8)
                            .opacity(animate ? 1 : 0)
                            .animation(.easeOut(duration: 0.45).delay(0.40), value: animate)
                    }
                }
                .padding(20)

                HStack {
                    Spacer()
                    FloatingPill(icon: "sparkles", text: "BOTTOM")
                        .offset(x: animate ? 0 : 24, y: animate ? 0 : 0)
                        .opacity(animate ? 1 : 0)
                        .animation(.easeOut(duration: 0.45).delay(0.30), value: animate)
                }
                .padding(.trailing, 24)
            }
        }
    }
}

// MARK: - Mockup 2: Quick Add

private struct QuickAddMockup: View {
    let animate: Bool

    var body: some View {
        MockupCard {
            ZStack {
                Color(red: 0.97, green: 0.96, blue: 0.94)

                // Stylized garment item: a soft hanger silhouette + label.
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white)
                            .frame(width: 160, height: 200)
                            .shadow(color: AppPalette.cardShadow, radius: 12, y: 6)
                        Image(systemName: "tshirt.fill")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(AppPalette.textFaint.opacity(0.6))
                    }
                    .scaleEffect(animate ? 1 : 0.92)
                    .animation(.spring(response: 0.55, dampingFraction: 0.75).delay(0.10), value: animate)

                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text("Quick Add")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(.white)
                    )
                    .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.5))
                    .shadow(color: AppPalette.cardShadow.opacity(0.6), radius: 8, y: 3)
                    .opacity(animate ? 1 : 0)
                    .offset(y: animate ? 0 : 12)
                    .animation(.easeOut(duration: 0.45).delay(0.30), value: animate)
                }

                // A floating "+" button in the corner.
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(AppPalette.textStrong))
                            .shadow(color: AppPalette.cardShadow, radius: 8, y: 4)
                            .scaleEffect(animate ? 1 : 0.6)
                            .opacity(animate ? 1 : 0)
                            .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.45), value: animate)
                    }
                    Spacer()
                }
                .padding(20)
            }
        }
    }
}

// MARK: - Mockup 3: Social

private struct SocialMockup: View {
    let animate: Bool

    var body: some View {
        MockupCard {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.96, blue: 0.97),
                        Color(red: 0.96, green: 0.95, blue: 0.99),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Mini feed card mockup.
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(AppPalette.textFaint.opacity(0.5))
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppPalette.textPrimary.opacity(0.7))
                                .frame(width: 60, height: 8)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppPalette.textFaint.opacity(0.5))
                                .frame(width: 40, height: 5)
                        }
                        Spacer()
                    }
                    .padding(12)

                    RoundedRectangle(cornerRadius: 0)
                        .fill(AppPalette.textFaint.opacity(0.18))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(AppPalette.textFaint.opacity(0.5))
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)

                    HStack(spacing: 12) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.pink)
                        Text("12")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppPalette.textPrimary)
                        Text("3")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(12)
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: AppPalette.cardShadow, radius: 14, y: 8)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)

                // Floating heart that pops in.
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.pink)
                            .padding(14)
                            .background(Circle().fill(.white))
                            .shadow(color: AppPalette.cardShadow, radius: 10, y: 4)
                            .scaleEffect(animate ? 1 : 0.4)
                            .opacity(animate ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.35), value: animate)
                    }
                    Spacer()
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
            }
        }
    }
}

// MARK: - Mockup 4: Shop

private struct ShopMockup: View {
    let animate: Bool

    var body: some View {
        MockupCard {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.98, blue: 0.97),
                        Color(red: 0.95, green: 0.97, blue: 0.96),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 16) {
                    // Mini outfit card with cart icon.
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white)
                            .frame(height: 140)
                            .shadow(color: AppPalette.cardShadow, radius: 12, y: 6)
                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(AppPalette.textFaint.opacity(0.5))
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "cart.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(AppPalette.textStrong))
                            }
                        }
                        .padding(10)
                    }
                    .padding(.horizontal, 32)
                    .scaleEffect(animate ? 1 : 0.95)
                    .animation(.easeOut(duration: 0.45).delay(0.10), value: animate)

                    // Row of product chips with BUY pills.
                    HStack(spacing: 12) {
                        ForEach(0..<3) { i in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white)
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Image(systemName: ["tshirt.fill", "shoeprints.fill", "bag.fill"][i])
                                            .font(.system(size: 22))
                                            .foregroundStyle(AppPalette.textFaint)
                                    )
                                    .shadow(color: AppPalette.cardShadow.opacity(0.7), radius: 6, y: 3)
                                Text("BUY")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(1)
                                    .foregroundStyle(AppPalette.textMuted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(.white))
                                    .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.5))
                            }
                            .opacity(animate ? 1 : 0)
                            .offset(y: animate ? 0 : 10)
                            .animation(
                                .easeOut(duration: 0.40)
                                    .delay(0.30 + Double(i) * 0.08),
                                value: animate
                            )
                        }
                    }
                }
                .padding(.vertical, 28)
            }
        }
    }
}

// MARK: - Mockup 5: OOTD share card

private struct OOTDMockup: View {
    let animate: Bool

    var body: some View {
        MockupCard {
            ZStack {
                // Iridescent/colorama-feeling backdrop.
                LinearGradient(
                    colors: [
                        Color(red: 0.85, green: 0.88, blue: 1.00),
                        Color(red: 0.95, green: 0.85, blue: 0.95),
                        Color(red: 0.99, green: 0.93, blue: 0.85),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Center share-card mockup — 9:16 portrait.
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white)
                        .shadow(color: AppPalette.cardShadow, radius: 18, y: 10)

                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "person.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(AppPalette.textFaint.opacity(0.4))
                        Spacer()
                        Text("MAY 8")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textFaint)
                        Text("OOTD")
                            .font(.custom("PlayfairDisplay-Italic", size: 24))
                            .foregroundStyle(AppPalette.textPrimary)
                            // ^ Playfair is fine HERE because this mockup
                            //   is showing the OOTD share card preview —
                            //   ShareCardComposer actually uses Playfair
                            //   for that exact card type.
                        Spacer().frame(height: 16)
                    }
                    .padding(20)
                }
                .aspectRatio(9.0/16.0, contentMode: .fit)
                .padding(.horizontal, 64)
                .padding(.vertical, 24)
                .scaleEffect(animate ? 1 : 0.92)
                .animation(.spring(response: 0.55, dampingFraction: 0.75).delay(0.10), value: animate)
            }
        }
    }
}

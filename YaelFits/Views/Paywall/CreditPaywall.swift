import SwiftUI

/// Sheet that surfaces when the user is out of free 3D credits and
/// wants to keep generating. Presents the four `CreditBundle` tiers
/// (single / starter / standard / bestValue) and routes the user
/// through a "select tier → tap Buy" flow.
///
/// Design language mirrors `ShareCardComposer` and
/// `ProfileHeaderCustomizeSheet` so the "this is a modal action
/// sheet from Yafa" pattern stays consistent: xmark close on the
/// left, monospaced caps title in the center, capsule action
/// button at the bottom.
///
/// Pure presentation — no StoreKit, no Supabase. The owner passes
/// in:
///   * `priceLookup` — resolves a bundle to its localized price
///     string. Returns nil while StoreKit's `Product` is still
///     loading; the view falls back to `bundle.fallbackPriceUSD`
///     so the cards always show *something*. This decoupling
///     also makes the view trivially testable without a working
///     StoreKit environment.
///   * `onBuy` — called when the user taps the action button.
///     Owner is responsible for kicking off the StoreKit purchase
///     flow + handling success / failure (including dismissing
///     this sheet).
///   * `currentBalance` — surfaced as a small "X left" chip in
///     the header so the user sees their starting state at a
///     glance.
///   * `isPurchasing` — drives the action button's loading state
///     and disables tier selection while a purchase is in flight.
struct CreditPaywall: View {
    /// All bundles to show, in render order (top → bottom).
    /// Defaulted to all `CreditBundle` cases so callers don't
    /// have to think about ordering — but exposed so a future
    /// A/B test could trim or reorder tiers.
    var bundles: [CreditBundle] = CreditBundle.allCases
    var currentBalance: Int
    var priceLookup: (CreditBundle) -> String?
    var isPurchasing: Bool
    /// True when running against Apple's sandbox (TestFlight, dev,
    /// sandbox tester sign-in). Drives a small "no real charge"
    /// banner so testers aren't confused — production builds
    /// hide it.
    var isSandboxBuild: Bool = false
    var onBuy: (CreditBundle) -> Void
    var onDismiss: () -> Void

    @State private var selectedBundle: CreditBundle = CreditBundle.highlightedTier

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)

                Spacer(minLength: LayoutMetrics.medium)

                contextLine
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, isSandboxBuild ? LayoutMetrics.small : LayoutMetrics.large)

                if isSandboxBuild {
                    sandboxBanner
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                        .padding(.bottom, LayoutMetrics.medium)
                }

                bundlesList
                    .padding(.horizontal, LayoutMetrics.screenPadding)

                Spacer(minLength: LayoutMetrics.large)

                buyButton
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
            }
        }
    }

    // MARK: - Header (matches ProfileHeaderCustomizeSheet pattern)

    private var header: some View {
        HStack {
            Button(action: onDismiss) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(SolidPressButtonStyle())
            .accessibilityLabel("Close")

            Spacer()

            Text("BUY MORE CREDITS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            // Invisible matching slot so the title stays optically
            // centered between left + right. No content here — the
            // balance moved to a plain text line under the context
            // copy below.
            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Context

    /// Short sentence above the bundle list, with the current
    /// balance shown as a small subline below. Plain language —
    /// "you ran out" rather than "no remaining quota." Sets the
    /// emotional tone before the user looks at prices.
    private var contextLine: some View {
        VStack(spacing: 6) {
            Text(currentBalance == 0
                 ? "You've used all your free 3D fits this month. Top up to keep playing."
                 : "Get more 3D fits. Credits never expire.")
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textMuted)
            .multilineTextAlignment(.center)

            Text("\(currentBalance) \(currentBalance == 1 ? "credit" : "credits") left this month")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textFaint)

            // How the free credits work — sets expectations so the
            // paywall doesn't read as the only way to get fits.
            Text("You get 6 free 3D fits a month, plus 1 for every 5 vibes you receive. Want more now? Grab credits below.")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sandbox banner

    /// Tiny pill above the bundle list when running in sandbox /
    /// TestFlight. Hidden on production builds. The goal is to
    /// stop testers from bouncing off the paywall thinking
    /// they'll be charged — Apple's purchase sheet itself shows
    /// "[Environment: Sandbox]" after the tap, but BEFORE the
    /// tap (when conversion decisions get made) the user can't
    /// tell. This banner closes that gap.
    private var sandboxBanner: some View {
        HStack(spacing: 6) {
            Text("TESTFLIGHT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppPalette.textPrimary))

            Text("No real charge — sandbox testing")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(AppPalette.textPrimary.opacity(0.05))
        )
    }

    // MARK: - Bundle cards

    private var bundlesList: some View {
        VStack(spacing: 10) {
            ForEach(bundles) { bundle in
                BundleCard(
                    bundle: bundle,
                    priceText: priceLookup(bundle) ?? bundle.fallbackPriceUSD,
                    isSelected: selectedBundle == bundle,
                    isHighlighted: bundle == CreditBundle.highlightedTier
                ) {
                    guard !isPurchasing else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedBundle = bundle
                }
            }
        }
    }

    // MARK: - Action button (same shape as ProfileView.saveButton)

    private var buyButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onBuy(selectedBundle)
        } label: {
            Group {
                if isPurchasing {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("BUY \(priceLookup(selectedBundle) ?? selectedBundle.fallbackPriceUSD)")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isPurchasing)
        .accessibilityLabel("Buy \(selectedBundle.credits) credits for \(priceLookup(selectedBundle) ?? selectedBundle.fallbackPriceUSD)")
    }
}

// MARK: - Bundle card

/// One row in the paywall — title / subtitle / discount badge /
/// per-credit footer / price on the right. Selection is purely
/// visual (border + light fill); the buy action lives on the
/// parent's button.
private struct BundleCard: View {
    let bundle: CreditBundle
    let priceText: String
    let isSelected: Bool
    let isHighlighted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bundle.title)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textPrimary)

                        if isHighlighted {
                            Text("MOST POPULAR")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(AppPalette.textPrimary)
                                )
                        }
                    }

                    Text(bundle.subtitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppPalette.textStrong)

                    Text(bundle.perCreditPrice)
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.textFaint)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(priceText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppPalette.textStrong)

                    if let discount = bundle.discountBadge {
                        Text(discount)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(AppPalette.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(AppPalette.cardBorder.opacity(0.5))
                            )
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            // Match the app's card family: `appCard` gives the
            // light blur backdrop, soft shadow, and 0.75pt
            // cardBorder stroke that every other card surface in
            // Yafa uses. Selected state adds a thin dark overlay
            // stroke (1pt — the lightest weight that still reads
            // as a deliberate UI affordance).
            .appCard()
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        AppPalette.textPrimary,
                        lineWidth: isSelected ? 1 : 0
                    )
            )
        }
        .buttonStyle(SolidPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bundle.title), \(bundle.subtitle), \(priceText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "" : "Double-tap to select this bundle")
    }
}

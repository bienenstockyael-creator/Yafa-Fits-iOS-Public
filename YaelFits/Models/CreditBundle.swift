import Foundation

/// Defines the four IAP bundles users can purchase to top up their
/// 3D generation credits. The single source of truth for pricing,
/// credit counts, and product IDs across the app.
///
/// Pricing rationale (from project_yafa_paid_credits memory):
///   * 3D gen costs $0.72 (Kling 2.5 Turbo Pro 10s + small prep).
///   * Apple takes 30%, so break-even per credit is ~$1.03.
///   * Single tier exists at $1.99 to anchor "save X%" narratives
///     and capture true impulse buys.
///   * Starter (3/$4.99) clears the under-$5 psychological barrier
///     and matches the free monthly tier in size — feels fair.
///   * Standard (10/$13.99) is the "real user" middle tier.
///   * Best value (30/$34.99) is the whale tier with the biggest
///     discount badge to anchor the others as reasonable.
///
/// Product IDs MUST match the App Store Connect IAP product
/// identifiers EXACTLY — StoreKit looks them up by string. Any
/// change here means a corresponding change in App Store Connect
/// (and vice versa). Reverse-DNS style is the App Store
/// convention.
enum CreditBundle: String, CaseIterable, Identifiable, Sendable {
    case single   = "com.yafa.credits.single"
    case starter  = "com.yafa.credits.starter"
    case standard = "com.yafa.credits.standard"
    case bestValue = "com.yafa.credits.bestvalue"

    var id: String { rawValue }

    /// Number of 3D credits granted when this bundle is purchased.
    /// Matched on the server side in `grant_paid_credits` (the
    /// Edge Function decides credits_granted from product_id; the
    /// iOS app is informational only — never trusted to grant
    /// credits to itself).
    var credits: Int {
        switch self {
        case .single:    return 1
        case .starter:   return 3
        case .standard:  return 10
        case .bestValue: return 30
        }
    }

    /// Display price in USD. The actual transaction price comes
    /// from StoreKit (which respects App Store Connect's localized
    /// pricing matrix). This is fallback text shown while the
    /// StoreKit `Product` is still loading + a sanity reference.
    var fallbackPriceUSD: String {
        switch self {
        case .single:    return "$1.99"
        case .starter:   return "$4.99"
        case .standard:  return "$13.99"
        case .bestValue: return "$34.99"
        }
    }

    /// Short marketing line shown above the price. Sets the
    /// emotional pitch for each tier; not a discount math
    /// statement.
    var title: String {
        switch self {
        case .single:    return "JUST ONE"
        case .starter:   return "STARTER"
        case .standard:  return "STANDARD"
        case .bestValue: return "BEST VALUE"
        }
    }

    /// Body line shown in the bundle card under the title. One
    /// concrete, neutral sentence describing what the user gets.
    var subtitle: String {
        switch self {
        case .single:    return "1 generation"
        case .starter:   return "3 generations"
        case .standard:  return "10 generations"
        case .bestValue: return "30 generations"
        }
    }

    /// Discount badge shown next to the price for the bundles
    /// that beat the single-gen rate. The single tier itself has
    /// no badge — it's the anchor.
    var discountBadge: String? {
        switch self {
        case .single:    return nil
        case .starter:   return "save 16%"
        case .standard:  return "save 30%"
        case .bestValue: return "save 41%"
        }
    }

    /// Per-credit rate, shown as a small footer line in the
    /// bundle card. Lets users quickly compare bundles without
    /// doing the math themselves.
    var perCreditPrice: String {
        switch self {
        case .single:    return "$1.99/credit"
        case .starter:   return "$1.66/credit"
        case .standard:  return "$1.40/credit"
        case .bestValue: return "$1.17/credit"
        }
    }

    /// Which tier (if any) gets the "Most popular" highlight in
    /// the paywall. Starter is intentional — small-bundle first
    /// purchases convert at the highest rate, and converting at
    /// all is the v1 goal.
    static var highlightedTier: CreditBundle { .starter }
}

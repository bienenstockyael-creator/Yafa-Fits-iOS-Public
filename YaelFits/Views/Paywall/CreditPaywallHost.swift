import SwiftUI
import StoreKit

/// Wraps `CreditPaywall` and connects it to the real StoreKit flow.
/// The view layer just presents this; everything between "tap Buy"
/// and "credit lands in your balance" lives here.
///
/// Flow:
///   1. On appear, ask `CreditPurchaseService` to load the four
///      products from the App Store (or `.storekit` test config).
///      Until they load, the paywall shows fallback USD prices.
///   2. User selects a tier + taps Buy.
///   3. `purchase()` runs the StoreKit sheet. On success we get a
///      `VerifiedTransaction` (JWS + Transaction).
///   4. (PHASE 4 — not yet built) Hand the JWS to the
///      `validate-apple-receipt` Edge Function. The function verifies
///      Apple's signature, calls `grant_paid_credits`, returns the
///      new balance.
///   5. Mark the transaction `finished()` only AFTER the server
///      confirms it credited the user. If the server call fails,
///      the transaction stays in StoreKit's queue and the launch-
///      time listener will retry it.
///   6. Refresh local balance + dismiss the sheet.
///
/// Until Phase 4 ships, step 4 is stubbed (the user sees a
/// "purchase succeeded" toast but no credit is actually granted —
/// the server still has to do the verification + grant). Marked
/// TODO so it's easy to find.
struct CreditPaywallHost: View {
    /// Feature flag for paid credits. **False during beta**: the
    /// paywall still surfaces (to show the tier design + capture
    /// demand signal) but Buy taps fire an analytics event and
    /// surface a "Coming soon" alert instead of opening StoreKit.
    /// Flip to true once the App Store v2 submission (with IAPs)
    /// is approved and the real purchase flow is desired.
    ///
    /// Demand signal lives in `analytics_events`:
    ///   * `paywall_viewed`     — paywall surfaced for a user
    ///   * `paywall_tapped_buy` — user tapped Buy on a bundle
    ///                            (properties: bundle_id, credits)
    ///   * `paywall_dismissed`  — closed without tapping Buy
    static let paidCreditsEnabled = false

    /// Current 3D credit balance to display in the chip. Owner
    /// supplies it because this view doesn't own the user's
    /// session / profile.
    let currentBalance: Int
    /// Called after a successful purchase + credit so the owner can
    /// re-read the balance and (if applicable) retry whatever
    /// generation hit the paywall in the first place.
    let onPurchaseComplete: () async -> Void
    /// Owner dismisses the sheet however it was presented.
    let onDismiss: () -> Void

    @State private var isPurchasing = false
    @State private var loadedPrices: [CreditBundle: String] = [:]
    @State private var errorMessage: String?
    @State private var showComingSoonAlert = false

    /// True when the build is running against StoreKit's sandbox
    /// environment (TestFlight, local development). The paywall
    /// uses this to surface a "TESTFLIGHT — no real charge"
    /// banner so testers don't think a real purchase went through.
    static var isSandboxBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        CreditPaywall(
            currentBalance: currentBalance,
            priceLookup: { loadedPrices[$0] },
            isPurchasing: isPurchasing,
            isSandboxBuild: Self.isSandboxBuild,
            onBuy: { bundle in
                if Self.paidCreditsEnabled {
                    Task { await handleBuy(bundle) }
                } else {
                    handleComingSoonTap(bundle)
                }
            },
            onDismiss: {
                Analytics.log("paywall_dismissed", properties: [
                    "balance": .int(currentBalance)
                ])
                onDismiss()
            }
        )
        .task {
            Analytics.log("paywall_viewed", properties: [
                "balance": .int(currentBalance)
            ])
            // Skip StoreKit product fetch when paid credits are off
            // — fallback USD prices already render correctly, and
            // there's no need to hit Apple's servers for a flow we
            // won't run.
            if Self.paidCreditsEnabled {
                await loadPrices()
            }
        }
        .alert(
            "Coming soon",
            isPresented: $showComingSoonAlert,
            actions: { Button("Got it") {} },
            message: {
                Text("Paid 3D fits are coming soon. We'll let you know the moment they launch.")
            }
        )
        .alert(
            "Purchase issue",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK") { errorMessage = nil } },
            message: { Text(errorMessage ?? "") }
        )
    }

    // MARK: - Coming-soon path

    /// Fires when paid credits are disabled (beta mode). Logs the
    /// demand signal — which bundle and at what implied price —
    /// then surfaces a non-blocking "Coming soon" alert.
    private func handleComingSoonTap(_ bundle: CreditBundle) {
        Analytics.log("paywall_tapped_buy", properties: [
            "bundle_id": .string(bundle.rawValue),
            "credits": .int(bundle.credits),
            "fallback_price_usd": .string(bundle.fallbackPriceUSD)
        ])
        showComingSoonAlert = true
    }

    // MARK: - StoreKit wiring

    private func loadPrices() async {
        do {
            // Explicit type annotation + closure form (rather than
            // a keypath) so the compiler resolves `displayPrice`
            // against `StoreKit.Product` unambiguously — the
            // codebase has a same-named `Product` type in
            // `Outfit.swift` that otherwise shadows it.
            let products: [CreditBundle: StoreKit.Product] =
                try await CreditPurchaseService.shared.loadProducts()
            await MainActor.run {
                loadedPrices = products.mapValues { $0.displayPrice }
            }
        } catch {
            // Silent: the paywall already falls back to hardcoded
            // USD prices. We don't want to nag a user who's offline
            // — they can still see the bundles and try again.
        }
    }

    private func handleBuy(_ bundle: CreditBundle) async {
        await MainActor.run { isPurchasing = true }
        defer { Task { await MainActor.run { isPurchasing = false } } }

        do {
            let outcome = try await CreditPurchaseService.shared.purchase(bundle)
            switch outcome {
            case .success(let verified):
                await handleSuccessfulPurchase(verified)
            case .userCancelled:
                break  // No UI — silent dismissal of the StoreKit sheet.
            case .pending:
                await MainActor.run {
                    errorMessage = "Purchase is pending approval. Your credits will arrive once it's approved."
                }
            }
        } catch let error as PurchaseError {
            await MainActor.run { errorMessage = error.errorDescription }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    /// Hand the JWS to the server, await confirmation, finish the
    /// transaction, refresh balance, dismiss. Order matters:
    /// finish ONLY after the server confirms it credited the
    /// user, so an Edge Function outage leaves the txn in
    /// StoreKit's queue (the launch-time listener will retry it
    /// on next app open).
    private func handleSuccessfulPurchase(_ verified: VerifiedTransaction) async {
        do {
            _ = try await CreditPurchaseService.shared.validateAndCredit(verified)
        } catch let error as PurchaseError {
            await MainActor.run { errorMessage = error.errorDescription }
            return
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
            return
        }

        // Server credited the user — safe to dequeue the
        // StoreKit transaction.
        await CreditPurchaseService.shared.finishTransaction(verified.transaction)
        await onPurchaseComplete()
        await MainActor.run { onDismiss() }
    }
}

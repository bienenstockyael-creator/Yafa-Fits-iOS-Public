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

    /// True when this build is running against Apple's sandbox
    /// environment — either from Xcode (dev), via TestFlight, or
    /// a sandbox tester sign-in on a production build. The
    /// receipt URL's last path component is the canonical signal
    /// (production = "receipt", sandbox = "sandboxReceipt").
    /// Used to surface a small "no real charge" banner on the
    /// paywall so testers aren't confused by a paid flow that
    /// won't actually charge them.
    static var isSandboxBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        CreditPaywall(
            currentBalance: currentBalance,
            priceLookup: { loadedPrices[$0] },
            isPurchasing: isPurchasing,
            isSandboxBuild: Self.isSandboxBuild,
            onBuy: { bundle in Task { await handleBuy(bundle) } },
            onDismiss: onDismiss
        )
        .task { await loadPrices() }
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

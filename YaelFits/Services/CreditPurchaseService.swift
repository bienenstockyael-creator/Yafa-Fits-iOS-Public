import Foundation
import StoreKit

/// Aliased to dodge a name collision: the codebase already defines
/// its own `Product` type (`Models/Outfit.swift`) for items inside an
/// outfit, which shadows `StoreKit.Product` whenever Swift's
/// resolver picks the same-module type first. Using `IAPProduct`
/// throughout this file keeps every StoreKit reference unambiguous
/// without forcing fully-qualified `StoreKit.Product` syntax.
private typealias IAPProduct = StoreKit.Product

/// Thin StoreKit 2 wrapper that powers the paid-credit purchase flow.
///
/// Responsibilities:
///   1. Load the four `CreditBundle` IAP products from the App Store
///      (or from the local `.storekit` config when testing).
///   2. Initiate purchases and surface the resulting transaction's
///      JWS payload to the caller, who hands it to the
///      `validate-apple-receipt` Edge Function for server-side
///      verification + crediting.
///   3. Listen for "unfinished transactions" at app launch — pending
///      purchases that weren't confirmed on a prior session (e.g. the
///      app was killed mid-flow). These get verified + credited the
///      same way as in-session purchases.
///
/// Why an actor: StoreKit 2's purchase result and `Transaction.updates`
/// cross task boundaries; serialising state inside an actor avoids
/// the need for ad-hoc locks while still playing nicely with
/// structured concurrency.
///
/// What this DOES NOT do (intentional separation):
///   * Verify the transaction's JWS signature against Apple's keys.
///     That's the Edge Function's job — doing it client-side gives
///     no security guarantee since the client could lie about the
///     result.
///   * Grant credits. The server (`grant_paid_credits` RPC) is the
///     only path that touches `gen_credits_paid_balance`.
///   * Mark transactions `finished()`. We only call `finished()` AFTER
///     the server confirms it credited the user; otherwise an Edge
///     Function outage would lose the purchase.
actor CreditPurchaseService {
    static let shared = CreditPurchaseService()

    /// StoreKit IAP products indexed by their `productID`. Empty
    /// until `loadProducts()` succeeds the first time, then cached
    /// for the lifetime of the process.
    private var loadedProducts: [String: IAPProduct] = [:]

    /// Background task that watches `Transaction.updates`. Cancelled
    /// on deinit. Created lazily when `startTransactionListener()` is
    /// first called (typically at app launch).
    private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Product loading

    /// Fetches the four credit bundles from StoreKit. Idempotent —
    /// repeated calls return the cached set. Caller catches errors
    /// (network failure, App Store outage) and surfaces "couldn't
    /// load prices" in the paywall.
    func loadProducts() async throws -> [CreditBundle: StoreKit.Product] {
        if !loadedProducts.isEmpty {
            return mapped()
        }
        let products = try await IAPProduct.products(
            for: CreditBundle.allCases.map(\.rawValue)
        )
        for product in products {
            loadedProducts[product.id] = product
        }
        return mapped()
    }

    /// Convenience accessor for the paywall view: returns the
    /// localized display price for a bundle, or nil if products
    /// haven't loaded yet (caller falls back to
    /// `bundle.fallbackPriceUSD`).
    func displayPrice(for bundle: CreditBundle) -> String? {
        loadedProducts[bundle.rawValue]?.displayPrice
    }

    private func mapped() -> [CreditBundle: IAPProduct] {
        var out: [CreditBundle: IAPProduct] = [:]
        for bundle in CreditBundle.allCases {
            if let product = loadedProducts[bundle.rawValue] {
                out[bundle] = product
            }
        }
        return out
    }

    // MARK: - Purchase flow

    /// Result returned to the paywall view after the user completes
    /// (or doesn't complete) a purchase. Lets the view differentiate
    /// "show success animation" from "show error" from "user just
    /// cancelled, don't show anything."
    enum PurchaseOutcome: Sendable {
        /// Purchase succeeded. The associated `Transaction` has NOT
        /// been finished yet — the paywall view must hand the JWS
        /// to the server and only call `finishTransaction` once the
        /// server confirms it was credited.
        case success(VerifiedTransaction)
        /// User dismissed the StoreKit sheet without buying. No
        /// further action needed.
        case userCancelled
        /// Purchase is pending (e.g. Ask to Buy parental approval).
        /// We'll get the transaction later via the listener.
        case pending
    }

    /// Initiate a purchase. The returned outcome tells the caller
    /// what UI to show next. On `.success`, the caller is
    /// responsible for sending the JWS to the backend AND calling
    /// `finishTransaction` once the backend credits the user.
    func purchase(_ bundle: CreditBundle) async throws -> PurchaseOutcome {
        guard let product = loadedProducts[bundle.rawValue] else {
            throw PurchaseError.productNotLoaded(bundle: bundle)
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            return .success(try unwrap(verification, bundle: bundle))
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            throw PurchaseError.unexpectedResult
        }
    }

    /// Mark a transaction finished AFTER the server has credited
    /// the user. Calling this before server confirmation risks
    /// losing the purchase if the Edge Function call fails — the
    /// transaction is gone from StoreKit's queue but the user has
    /// no credits.
    func finishTransaction(_ transaction: Transaction) async {
        await transaction.finish()
    }

    // MARK: - Server-side validation + credit grant

    /// Result returned from the `validate-apple-receipt` Edge
    /// Function on success. Decoded straight off the wire.
    struct CreditGrantResult: Decodable, Sendable {
        let new_paid_balance: Int
        let was_already_credited: Bool
    }

    /// Sends a verified StoreKit transaction's JWS to the
    /// Supabase Edge Function. The function authenticates the
    /// caller, decodes the JWS payload, maps `product_id` →
    /// credits server-side (so the client can't lie about the
    /// bundle size), and calls `grant_paid_credits` under
    /// service_role. Returns the new paid balance + whether
    /// this txn was already credited on a prior call.
    ///
    /// IMPORTANT: only call `finishTransaction` AFTER this
    /// resolves successfully — otherwise an Edge Function
    /// outage would dequeue the StoreKit transaction without
    /// the user ever getting credits.
    func validateAndCredit(_ verified: VerifiedTransaction) async throws -> CreditGrantResult {
        let url = SupabaseConfig.url
            .appendingPathComponent("functions/v1/validate-apple-receipt")

        let jwt = try await supabase.auth.session.accessToken

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let payload: [String: String] = [
            "jws": verified.jwsRepresentation,
            "product_id": verified.productID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PurchaseError.unexpectedResult
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's error code in the LocalizedError
            // chain so the paywall can display something better
            // than a generic alert at sandbox / debug time.
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw PurchaseError.serverRejected(status: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(CreditGrantResult.self, from: data)
    }

    // MARK: - Background listener for queued transactions

    /// Should be called once at app launch. Watches for transactions
    /// that came in while the app was backgrounded / killed (e.g.
    /// Ask-to-Buy approvals that arrived later, App Store retries).
    /// Each transaction is handed to `onTransaction` so the caller
    /// can route it through the same server-verify-and-credit path
    /// as a live purchase.
    func startTransactionListener(
        onTransaction: @escaping @Sendable (VerifiedTransaction) async -> Void
    ) {
        transactionListenerTask?.cancel()
        transactionListenerTask = Task {
            for await update in Transaction.updates {
                if case .verified(let txn) = update {
                    let verified = VerifiedTransaction(
                        transaction: txn,
                        jwsRepresentation: update.jwsRepresentation,
                        productID: txn.productID
                    )
                    await onTransaction(verified)
                }
                // .unverified updates are dropped on purpose —
                // server-side verification will refuse them anyway,
                // and we don't want to bother the user with a
                // failure UI for something they didn't initiate
                // this session.
            }
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Helpers

    /// Pulls the verified `Transaction` out of StoreKit's
    /// verification result, preserves the raw JWS payload (which is
    /// what the server actually validates against Apple's public
    /// keys), and bundles it for the caller.
    private func unwrap(
        _ verification: VerificationResult<Transaction>,
        bundle: CreditBundle
    ) throws -> VerifiedTransaction {
        switch verification {
        case .verified(let txn):
            return VerifiedTransaction(
                transaction: txn,
                jwsRepresentation: verification.jwsRepresentation,
                productID: txn.productID
            )
        case .unverified(_, let error):
            throw PurchaseError.unverified(error)
        }
    }
}

// MARK: - Public value types

/// A purchase that StoreKit has verified against the App Store's
/// signing keys. The view layer ferries this to the
/// `validate-apple-receipt` Edge Function; the server re-verifies
/// the JWS independently (defense-in-depth — never trust the
/// client's claim that StoreKit said it was verified).
struct VerifiedTransaction: Sendable {
    /// StoreKit's representation, used for `finish()` after the
    /// server credits the user.
    let transaction: Transaction
    /// The raw JWS string the server validates. This is the actual
    /// security payload — everything else here is convenience.
    let jwsRepresentation: String
    /// Bundle product ID (e.g. "com.yafa.credits.starter"). Helps
    /// the server look up `credits_granted` without re-deriving
    /// from the JWS payload.
    let productID: String
}

/// Distinct errors that the paywall view can switch on to show
/// the right recovery UI. `unverified` and `productNotLoaded` are
/// developer / configuration errors; `unexpectedResult` is a
/// future-proofing catch-all for StoreKit SDK additions.
enum PurchaseError: Error, LocalizedError {
    case productNotLoaded(bundle: CreditBundle)
    case unverified(Error?)
    case unexpectedResult
    /// The Apple-side purchase succeeded but our server's
    /// validate-apple-receipt Edge Function rejected the JWS /
    /// product_id pair (HTTP non-2xx). The transaction has NOT
    /// been finished, so the App Store launch-time listener will
    /// retry it — but in the current session we surface this so
    /// the paywall can show the user something better than a
    /// silent failure.
    case serverRejected(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .productNotLoaded(let bundle):
            return "Bundle \(bundle.rawValue) isn't available right now. Try again in a moment."
        case .unverified:
            return "We couldn't verify that purchase with Apple. No charge was made."
        case .unexpectedResult:
            return "Something unexpected happened during the purchase. No charge was made."
        case .serverRejected(let status, _):
            return "We couldn't credit your purchase (server returned \(status)). Your transaction is safe — we'll retry on next launch."
        }
    }
}

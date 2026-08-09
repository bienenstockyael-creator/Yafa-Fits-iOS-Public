import SwiftUI
import UIKit

/// Resolves a product to a launchable shop URL and opens it. Shared
/// by the public feed's cart drawer and the carousel detail card's
/// per-product BUY pill — same three-tier resolution in both surfaces.
enum ProductShopLink {
    @MainActor
    static func open(_ product: Product) {
        Analytics.log("buy_tapped", properties: [
            "product": .string(product.name),
            "has_link": .bool(!(product.shopLink ?? "").isEmpty),
        ])
        // 1. User-entered shop link wins — they have a specific product
        //    page in mind. Normalise scheme-less URLs (e.g.
        //    "amazon.com/x") by prefixing https:// so they actually
        //    open, instead of falling through to Lens.
        if let raw = product.shopLink?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = normalizedShopURL(raw) {
            UIApplication.shared.open(url)
            return
        }

        // 2. Thumbnail → Google Lens visual search, opened in the
        //    IN-APP browser sheet — never Safari. Safari shares the
        //    user's logged-in Google session, and for EU sessions the
        //    uploadbyurl redirect drops the image (empty results). The
        //    sheet's WKWebView has the app's own clean cookie store,
        //    where Lens works — and if the load hard-fails, the sheet
        //    cascades to the name search below on its own.
        if let thumbnailURL = product.resolvedImageURL,
           let encodedThumb = thumbnailURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let lensURL = URL(string: "https://lens.google.com/uploadbyurl?url=\(encodedThumb)") {
            ShopBrowser.present(primary: lensURL, fallback: nameSearchURL(for: product))
            return
        }

        // 3. No image either — Google Shopping text search on the label.
        guard let url = nameSearchURL(for: product) else { return }
        UIApplication.shared.open(url)
    }

    /// Google Shopping (udm=28) text search on the product label —
    /// the cascade's last tier. Renders buyable tiles deterministically,
    /// logged in or out, but is only as specific as the name.
    private static func nameSearchURL(for product: Product) -> URL? {
        let query = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "https://www.google.com/search?udm=28&q=\(encoded)")
    }

    /// Returns a launchable https URL for a user-entered shop link.
    /// Accepts inputs with or without a scheme: "https://amazon.com/x",
    /// "amazon.com/x", "//amazon.com/x" all map to a valid https URL.
    /// Returns nil only if the string can't be parsed even after
    /// prepending a scheme.
    private static func normalizedShopURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        let stripped = raw.hasPrefix("//") ? String(raw.dropFirst(2)) : raw
        return URL(string: "https://\(stripped)")
    }
}

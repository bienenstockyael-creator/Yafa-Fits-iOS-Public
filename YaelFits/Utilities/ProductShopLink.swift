import SwiftUI
import UIKit

/// Resolves a product to a launchable shop URL and opens it. Shared
/// by the public feed's cart drawer and the carousel detail card's
/// per-product BUY pill — same three-tier resolution in both surfaces.
enum ProductShopLink {
    static func open(_ product: Product) {
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

        // 2. Thumbnail → Google Lens visual search. The thumbnail is more
        //    discriminating than the label alone, so this returns the
        //    closest visual matches for the actual product image.
        if let thumbnailURL = product.resolvedImageURL,
           let encodedThumb = thumbnailURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let lensURL = URL(string: "https://lens.google.com/uploadbyurl?url=\(encodedThumb)") {
            UIApplication.shared.open(lensURL)
            return
        }

        // 3. Fallback — Google Images text search using the product label.
        let query = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?tbm=isch&q=\(encoded)")
        else { return }
        UIApplication.shared.open(url)
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

import UIKit

/// In-extension product-page scrape. URLSession carries Apple's TLS
/// fingerprint (≈ Safari), so shops whose Cloudflare walls 403 the
/// server's scrape (Jacquemus — verified to block every non-browser
/// fingerprint) still serve the extension. Getting the image bytes
/// HERE means the save lands complete: no stub row, no WKWebView
/// backfill, no screenshot — the server polishes the provided bytes
/// immediately. Every failure returns nil and the save proceeds
/// URL-only exactly as before, so this path can only ever add speed.
///
/// Field priorities mirror the server scrape (JSON-LD Product → og:
/// metas), including its malformed-URL lesson: values like
/// "https:files/x.jpg" (scheme without authority — Cult Gaia ships
/// these) are rejected per candidate, not after the pick.
enum PageScraper {

    struct Enriched {
        let name: String?
        let image: String
        let imageData: String
        let price: String?
        let brand: String?
    }

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// Best-effort with a hard per-request budget; the share card's
    /// sparkle animation covers the wait, but a wedged save is worse
    /// than a slow backfill, so nothing here may hang.
    static func enrich(url: URL) async -> Enriched? {
        guard let html = await fetchHTML(url) else { return nil }

        var name: String?
        var imageCandidate: String?
        var price: String?
        var brand: String?

        if let ld = productJsonLd(in: html) {
            name = ld.name
            imageCandidate = ld.image.flatMap { absolutize($0, base: url) }
            price = ld.price
            brand = ld.brand
        }
        // og: fallbacks, per-candidate absolutize validation.
        if imageCandidate == nil {
            imageCandidate = meta(html, "og:image:secure_url").flatMap { absolutize($0, base: url) }
                ?? meta(html, "og:image").flatMap { absolutize($0, base: url) }
                ?? meta(html, "twitter:image").flatMap { absolutize($0, base: url) }
        }
        if name == nil {
            name = meta(html, "og:title") ?? titleTag(html)
        }
        if price == nil {
            if let amount = meta(html, "product:price:amount") ?? meta(html, "og:price:amount") {
                let currency = meta(html, "product:price:currency") ?? meta(html, "og:price:currency")
                price = currency.map { "\(amount) \($0)" } ?? amount
            }
        }

        guard let imageURLString = imageCandidate,
              let imageURL = URL(string: imageURLString),
              let dataURI = await fetchImageDataURI(imageURL, referer: url) else { return nil }

        // Page titles carry site suffixes ("… | Valentino US") — keep
        // the product part, same trim the backfill applies.
        let cleanName = name?
            .components(separatedBy: " | ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Enriched(
            name: (cleanName?.isEmpty == false) ? String(cleanName!.prefix(120)) : nil,
            image: imageURLString,
            imageData: dataURI,
            price: price.map { String($0.prefix(40)) },
            brand: brand.map { String($0.prefix(60)) }
        )
    }

    // MARK: Fetching

    private static func fetchHTML(_ url: URL) async -> String? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data.prefix(600_000), encoding: .utf8) else { return nil }
        return html
    }

    /// Downloads the hero, re-encodes to a bounded JPEG data URI. The
    /// re-encode both caps the POST body (~600KB) and normalizes CDN
    /// formats (webp etc.) into something nano always accepts.
    private static func fetchImageDataURI(_ url: URL, referer: URL) async -> String? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              data.count > 1_000, data.count < 15_000_000,
              let image = UIImage(data: data) else { return nil }

        let maxSide: CGFloat = 1600
        let side = max(image.size.width, image.size.height)
        let scaled: UIImage
        if side > maxSide, side > 0 {
            let factor = maxSide / side
            let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            scaled = image
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    // MARK: JSON-LD

    private struct ProductLD {
        let name: String?
        let image: String?
        let price: String?
        let brand: String?
    }

    private static func productJsonLd(in html: String) -> ProductLD? {
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html),
                  let data = String(html[r]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let product = findProductNode(json) {
                return ProductLD(
                    name: product["name"] as? String,
                    image: firstImageString(product["image"]),
                    price: priceString(product["offers"]),
                    brand: brandString(product["brand"])
                )
            }
        }
        return nil
    }

    private static func findProductNode(_ json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if let type = dict["@type"] {
                let types = (type as? [String]) ?? [(type as? String) ?? ""]
                if types.contains(where: { $0.caseInsensitiveCompare("Product") == .orderedSame }) {
                    return dict
                }
                // schema.org ProductGroup (Valentino et al.): the real
                // Product nodes live under hasVariant, and such pages
                // often ship NO og:image fallback — without this dive
                // the whole scrape comes back empty.
                if types.contains(where: { $0.caseInsensitiveCompare("ProductGroup") == .orderedSame }),
                   let variants = dict["hasVariant"] {
                    return findProductNode(variants)
                }
            }
            if let graph = dict["@graph"] { return findProductNode(graph) }
            return nil
        }
        if let array = json as? [Any] {
            for element in array {
                if let found = findProductNode(element) { return found }
            }
        }
        return nil
    }

    private static func firstImageString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] { return dict["url"] as? String }
        if let array = value as? [Any] {
            for element in array {
                if let found = firstImageString(element) { return found }
            }
        }
        return nil
    }

    private static func priceString(_ offers: Any?) -> String? {
        let offer: [String: Any]?
        if let dict = offers as? [String: Any] { offer = dict }
        else if let array = offers as? [Any] { offer = array.first as? [String: Any] }
        else { offer = nil }
        guard let offer else { return nil }
        let raw = offer["price"]
        let amount: String?
        if let s = raw as? String { amount = s }
        else if let n = raw as? NSNumber { amount = n.stringValue }
        else { amount = nil }
        guard let amount, !amount.isEmpty else { return nil }
        if let currency = offer["priceCurrency"] as? String, !currency.isEmpty {
            return "\(amount) \(currency)"
        }
        return amount
    }

    private static func brandString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] { return dict["name"] as? String }
        return nil
    }

    // MARK: HTML helpers

    /// <meta property|name="key" content="…"> in either attribute order.
    private static func meta(_ html: String, _ key: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"<meta[^>]*(?:property|name)\s*=\s*["']"# + escaped + #"["'][^>]*content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]*content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["']"# + escaped + #"["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let r = Range(match.range(at: 1), in: html) {
                let value = decodeEntities(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func titleTag(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        let value = decodeEntities(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Resolves relative URLs against the page; rejects the
    /// scheme-without-authority junk ("https:files/x.jpg") that
    /// resolves into dead same-site paths.
    private static func absolutize(_ candidate: String, base: URL) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http:") || trimmed.lowercased().hasPrefix("https:") {
            guard trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        // ATS blocks plain-http downloads in extensions, and shops do
        // publish http:// og:images (Cult Gaia). CDNs all serve https.
        if scheme == "http" {
            var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url?.absoluteString ?? resolved.absoluteString
        }
        return resolved.absoluteString
    }
}

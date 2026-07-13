import Foundation
import UIKit
import WebKit

/// Completes wishlist items that bot-walled shops refused to let the
/// server scrape (`thumb_status == "needs_client_scrape"` — e.g.
/// Farfetch 403s any non-browser page fetch, and its image CDN blocks
/// direct downloads too).
///
/// The app has what the server never will: a real WebKit engine.
/// The product page is loaded in an offscreen WKWebView — which
/// anti-bot walls treat exactly like Safari — the metadata the page
/// renders for humans is extracted, and the product image is captured
/// via `takeSnapshot` of the displayed element's rect, which is
/// immune to CORS taint and hotlink defenses because it is literally
/// a screenshot of what WebKit drew. The bytes are uploaded and the
/// stub row completed in place.
@MainActor
final class WishlistBackfillService: NSObject {
    static let shared = WishlistBackfillService()

    private var isRunning = false
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Max items completed per app session — each costs a full page
    /// load; a long backlog drains over a few launches instead of
    /// hammering the network on one.
    private let batchLimit = 3

    private struct StubRow: Decodable {
        let id: UUID
        let name: String
        let sourceUrl: String?
        enum CodingKeys: String, CodingKey {
            case id, name
            case sourceUrl = "source_url"
        }
    }

    private struct PageMeta: Decodable {
        let name: String?
        let price: String?
        let brand: String?
        let hasImage: Bool
    }

    private struct ImageRect: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    func backfillIfNeeded(userId: UUID) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer {
                isRunning = false
                teardownWebView()
            }
            await run(userId: userId)
        }
    }

    private func run(userId: UUID) async {
        let stubs: [StubRow]
        do {
            stubs = try await supabase
                .from("products")
                .select("id, name, source_url")
                .eq("user_id", value: userId.uuidString)
                .eq("thumb_status", value: "needs_client_scrape")
                .order("created_at", ascending: false)
                .limit(batchLimit)
                .execute()
                .value
        } catch {
            return
        }
        guard !stubs.isEmpty else { return }

        for stub in stubs {
            guard let urlString = stub.sourceUrl, let url = URL(string: urlString) else {
                await mark(stub.id, status: "client_scrape_failed")
                continue
            }
            do {
                try await complete(stub: stub, url: url, userId: userId)
            } catch {
                // Leave the stub for a retry next session rather than
                // burning it on one flaky page load — unless the URL
                // itself was the problem (handled above).
            }
        }
    }

    private func complete(stub: StubRow, url: URL, userId: UUID) async throws {
        let webView = makeWebView()

        try await load(url, in: webView, timeout: 25)
        // Bot-check interstitials and lazy hero images need a beat
        // after `didFinish` before the real content is on screen.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // Pass 1: metadata + pick the hero image (largest rendered
        // <img>), tag it, and scroll it into view.
        let metaJSON = try await evaluate(Self.extractAndTagJS, in: webView)
        let meta = try JSONDecoder().decode(PageMeta.self, from: Data(metaJSON.utf8))

        var uploadedImageURL: String?
        if meta.hasImage {
            // Pass 2: after the scroll settles, read the tagged
            // element's on-screen rect and snapshot exactly that.
            try await Task.sleep(nanoseconds: 800_000_000)
            let rectJSON = try await evaluate(Self.taggedRectJS, in: webView)
            let rect = try JSONDecoder().decode(ImageRect.self, from: Data(rectJSON.utf8))
            if rect.w > 40, rect.h > 40 {
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
                let image = try await webView.takeSnapshot(configuration: config)
                uploadedImageURL = try? await ProductThumbnailUploadService.upload(image, userId: userId)
            }
        }

        // Keep the slug-derived stub name unless the page gave a
        // better one; never downgrade to a generic title.
        let pageName = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await WardrobeService.updateItem(
            id: stub.id,
            name: (pageName?.isEmpty == false && pageName!.count > 2) ? String(pageName!.prefix(120)) : nil,
            brand: meta.brand.map { String($0.prefix(60)) },
            price: meta.price.map { String($0.prefix(40)) },
            imageURL: uploadedImageURL,
            thumbStatus: uploadedImageURL != nil ? "ready" : "client_scrape_failed"
        )
    }

    private func mark(_ id: UUID, status: String) async {
        try? await WardrobeService.updateItem(id: id, thumbStatus: status)
    }

    // MARK: WebKit plumbing

    private func makeWebView() -> WKWebView {
        if let existing = webView { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            configuration: config
        )
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.alpha = 0
        // Must live in a window for WebKit to render (snapshots of a
        // detached web view come back blank). Alpha 0 + behind
        // everything + non-interactive = invisible to the user.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first {
            window.insertSubview(view, at: 0)
        }
        webView = view
        return view
    }

    private func teardownWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func load(_ url: URL, in webView: WKWebView, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.loadContinuation = cont
                    webView.load(URLRequest(url: url))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func evaluate(_ js: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(js)
        guard let json = result as? String else { throw URLError(.cannotParseResponse) }
        return json
    }

    // MARK: Extraction scripts

    /// Metadata + hero-image selection. Mirrors the server scrape's
    /// field priorities (JSON-LD → og: meta), including the
    /// malformed-URL lesson: values only inform NAME/PRICE/BRAND —
    /// the image is never fetched by URL, it's snapshotted as drawn.
    private static let extractAndTagJS = """
    (function () {
      function meta(p) {
        var el = document.querySelector('meta[property="' + p + '"]') ||
                 document.querySelector('meta[name="' + p + '"]');
        return el ? el.getAttribute('content') : null;
      }
      var name = null, price = null, brand = null;
      try {
        var blocks = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < blocks.length; i++) {
          var data; try { data = JSON.parse(blocks[i].textContent); } catch (e) { continue; }
          var nodes = Array.isArray(data) ? data : (data['@graph'] || [data]);
          for (var j = 0; j < nodes.length; j++) {
            var n = nodes[j]; if (!n) continue;
            var t = n['@type'];
            if (!(t === 'Product' || (Array.isArray(t) && t.indexOf('Product') >= 0))) continue;
            if (!name && typeof n.name === 'string') name = n.name;
            if (!brand) brand = typeof n.brand === 'string' ? n.brand : (n.brand && n.brand.name);
            var off = Array.isArray(n.offers) ? n.offers[0] : n.offers;
            if (!price && off && off.price != null) {
              price = (off.priceCurrency ? off.priceCurrency + ' ' : '') + off.price;
            }
          }
        }
      } catch (e) {}
      if (!name) name = meta('og:title') || document.title;
      if (!price) price = meta('product:price:amount') || meta('og:price:amount');
      if (!brand) brand = meta('og:site_name');

      // Hero image: largest rendered <img> that is plausibly the
      // product shot (big, mostly square-ish, not a sprite).
      var best = null, bestArea = 0;
      var imgs = document.querySelectorAll('img');
      for (var k = 0; k < imgs.length; k++) {
        var r = imgs[k].getBoundingClientRect();
        var area = r.width * r.height;
        if (area > bestArea && r.width > 120 && r.height > 120) {
          bestArea = area; best = imgs[k];
        }
      }
      if (best) {
        best.setAttribute('data-yafa-hero', '1');
        try { best.scrollIntoView({ block: 'center' }); } catch (e) {}
      }
      return JSON.stringify({
        name: typeof name === 'string' ? name : null,
        price: typeof price === 'string' ? price : (typeof price === 'number' ? String(price) : null),
        brand: typeof brand === 'string' ? brand : null,
        hasImage: !!best
      });
    })()
    """

    /// On-screen rect of the tagged hero image, post-scroll.
    private static let taggedRectJS = """
    (function () {
      var el = document.querySelector('[data-yafa-hero]');
      if (!el) return JSON.stringify({ x: 0, y: 0, w: 0, h: 0 });
      var r = el.getBoundingClientRect();
      return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
    })()
    """
}

extension WishlistBackfillService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

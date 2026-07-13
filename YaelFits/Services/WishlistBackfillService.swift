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

    private struct HealRow: Decodable {
        let id: UUID
        let name: String
        let imageUrl: String?
        let thumbStatus: String?
        enum CodingKeys: String, CodingKey {
            case id, name
            case imageUrl = "image_url"
            case thumbStatus = "thumb_status"
        }
    }

    /// IDs this service flipped to 'generating' whose polish hasn't
    /// finished. Persisted so an app kill mid-polish can't wedge a row
    /// at 'generating' forever (eternal sparkles + the closet's 4s
    /// polish poll re-fetching on every future session). Only OUR ids
    /// go in here — a row at 'generating' owned by the tagging flow is
    /// someone else's in-flight work and must not be touched.
    private static let pendingPolishKey = "yafa.backfill.pendingPolish"
    private var pendingPolishIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingPolishKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingPolishKey) }
    }
    private func rememberPolishing(_ id: UUID) {
        var ids = pendingPolishIDs
        if !ids.contains(id.uuidString) { ids.append(id.uuidString) }
        pendingPolishIDs = ids
    }
    private func forgetPolishing(_ id: UUID) {
        pendingPolishIDs = pendingPolishIDs.filter { $0 != id.uuidString }
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
        await healWedgedPolishes(userId: userId)

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
        // <img>), tag it, and scroll it into view. Lazy loaders on
        // cellular can take several more seconds to materialize the
        // hero — poll up to 4 extra rounds before giving up on the
        // image (metadata is kept either way).
        var metaJSON = try await evaluate(Self.extractAndTagJS, in: webView)
        var meta = try JSONDecoder().decode(PageMeta.self, from: Data(metaJSON.utf8))
        var rounds = 0
        while !meta.hasImage && rounds < 4 {
            rounds += 1
            try await Task.sleep(nanoseconds: 1_500_000_000)
            metaJSON = try await evaluate(Self.extractAndTagJS, in: webView)
            meta = try JSONDecoder().decode(PageMeta.self, from: Data(metaJSON.utf8))
        }
        #if DEBUG
        print("[Backfill] \(url.host ?? "") meta=\(metaJSON) rounds=\(rounds)")
        #endif

        var uploadedImageURL: String?
        var capturedImage: UIImage?
        if meta.hasImage {
            // Pass 2: after the scroll settles, read the tagged
            // element's on-screen rect and snapshot exactly that.
            try await Task.sleep(nanoseconds: 800_000_000)
            let rectJSON = try await evaluate(Self.taggedRectJS, in: webView)
            let rect = try JSONDecoder().decode(ImageRect.self, from: Data(rectJSON.utf8))
            #if DEBUG
            print("[Backfill] hero rect=(\(rect.x), \(rect.y), \(rect.w), \(rect.h))")
            #endif
            if rect.w > 40, rect.h > 40 {
                // Full-viewport snapshot, cropped OURSELVES. Handing
                // the rect to WKSnapshotConfiguration silently
                // captured the whole viewport on-device (a y=105 crop
                // came back containing the page's y=0 logo bar), so
                // the crop is done deterministically in Swift from
                // the same numbers.
                let full = try await webView.takeSnapshot(configuration: nil)
                #if DEBUG
                let sv = webView.scrollView
                print("[Backfill] snap=\(Int(full.size.width))x\(Int(full.size.height))@\(full.scale) bounds=\(Int(webView.bounds.width))x\(Int(webView.bounds.height)) offset=\(Int(sv.contentOffset.y)) inset=\(Int(sv.adjustedContentInset.top))")
                #endif
                let image = Self.crop(
                    full,
                    to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h),
                    viewportWidth: webView.bounds.width
                ) ?? full
                // A THROW here (snapshot or upload) leaves the stub
                // flagged and retried next session — only a page with
                // genuinely no hero image gets marked failed below.
                uploadedImageURL = try await ProductThumbnailUploadService.upload(image, userId: userId)
                capturedImage = image
                #if DEBUG
                print("[Backfill] cropped=\(Int(image.size.width))x\(Int(image.size.height)) uploaded=\(uploadedImageURL ?? "nil")")
                #endif
            }
        }

        // Keep the slug-derived stub name unless the page gave a
        // better one; never downgrade to a generic title.
        // Page titles carry site suffixes ("Oval Acetate Glasses for
        // Woman in Havana/brown | Valentino US") — keep the product part.
        let pageName = meta.name?
            .components(separatedBy: " | ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = (pageName?.isEmpty == false && pageName!.count > 2)
            ? String(pageName!.prefix(120)) : nil
        // Raw snapshot lands first with 'generating' so the closet
        // shows the same sparkles as every other polishing item; the
        // catalog cutout swaps in below and the closet's existing
        // polish-polling animates the change.
        if uploadedImageURL != nil { rememberPolishing(stub.id) }
        try await WardrobeService.updateItem(
            id: stub.id,
            name: cleanName,
            brand: meta.brand.map { String($0.prefix(60)) },
            price: meta.price.map { String($0.prefix(40)) },
            imageURL: uploadedImageURL,
            thumbStatus: uploadedImageURL != nil ? "generating" : "client_scrape_failed"
        )

        guard let snapshotImage = capturedImage else { return }
        // Polish: same nano -> Bria -> tight-crop pipeline as tagged
        // products, so backfilled items are visually identical to
        // every other thumbnail. Raw snapshot stays if polish fails.
        do {
            let polished = try await FalProductThumbnailService.shared.generateCatalogThumbnail(
                fromProduct: snapshotImage,
                label: cleanName ?? stub.name
            )
            let polishedURL = try await ProductThumbnailUploadService.upload(polished, userId: userId)
            try await WardrobeService.updateItem(id: stub.id, imageURL: polishedURL, thumbStatus: "ready")
            forgetPolishing(stub.id)
            #if DEBUG
            print("[Backfill] polished=\(polishedURL)")
            #endif
        } catch {
            // Best effort; if this write also fails the id stays in
            // pendingPolishIDs and the healer resolves it next run.
            if (try? await WardrobeService.updateItem(id: stub.id, thumbStatus: "ready")) != nil {
                forgetPolishing(stub.id)
            }
            #if DEBUG
            print("[Backfill] polish failed, keeping raw: \(error.localizedDescription)")
            #endif
        }
    }

    /// Rescue rows a previous session flipped to 'generating' and then
    /// never finished (app killed mid-polish, or the final write
    /// failed). The raw snapshot is already uploaded, so re-polish it;
    /// whatever happens, the row leaves 'generating'.
    private func healWedgedPolishes(userId: UUID) async {
        for idString in pendingPolishIDs {
            guard let id = UUID(uuidString: idString) else {
                pendingPolishIDs = pendingPolishIDs.filter { $0 != idString }
                continue
            }
            let row: HealRow?
            do {
                let rows: [HealRow] = try await supabase
                    .from("products")
                    .select("id, name, image_url, thumb_status")
                    .eq("id", value: id.uuidString)
                    .limit(1)
                    .execute()
                    .value
                row = rows.first
            } catch {
                continue // transient fetch failure — retry next run
            }
            // Row gone, or someone else finished it — nothing to heal.
            guard let row, row.thumbStatus == "generating" else {
                forgetPolishing(id)
                continue
            }
            #if DEBUG
            print("[Backfill] healing wedged polish \(id)")
            #endif
            var healed = false
            if let raw = row.imageUrl, let url = URL(string: raw), !raw.isEmpty {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data),
                   let polished = try? await FalProductThumbnailService.shared.generateCatalogThumbnail(
                       fromProduct: image, label: row.name
                   ),
                   let polishedURL = try? await ProductThumbnailUploadService.upload(polished, userId: userId) {
                    healed = (try? await WardrobeService.updateItem(
                        id: id, imageURL: polishedURL, thumbStatus: "ready"
                    )) != nil
                }
                // Re-polish failed — the raw snapshot is a fine thumbnail;
                // just stop the eternal sparkles.
                if !healed {
                    healed = (try? await WardrobeService.updateItem(id: id, thumbStatus: "ready")) != nil
                }
            } else {
                // No image ever landed — send it back through the scraper.
                healed = (try? await WardrobeService.updateItem(id: id, thumbStatus: "needs_client_scrape")) != nil
            }
            if healed { forgetPolishing(id) }
        }
    }

    /// Crop a full-viewport snapshot to a CSS-point rect. The
    /// snapshot's pixel scale is derived from its width vs the web
    /// view's point width, so the crop is exact on any screen scale.
    private static func crop(_ image: UIImage, to rect: CGRect, viewportWidth: CGFloat) -> UIImage? {
        guard let cg = image.cgImage, viewportWidth > 0 else { return nil }
        let scale = CGFloat(cg.width) / viewportWidth
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard pixelRect.width > 10, pixelRect.height > 10,
              let cropped = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
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
        // Kill safe-area content-inset adjustment: with it on, the
        // page renders shifted down inside the view, so page (CSS)
        // coordinates and view coordinates disagree by the inset —
        // our crops landed higher than requested and captured the
        // site header despite correct page-space rects.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentOffset = .zero
        // FULL alpha, inserted at the very back of the window: the
        // app's opaque root covers it completely, so it's invisible —
        // but unlike alpha = 0 (which iOS may skip compositing
        // entirely), WebKit keeps rendering and takeSnapshot returns
        // real pixels.
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

      // Hide viewport-covering overlays (cookie walls, consent
      // modals, app-download interstitials) BEFORE picking and
      // snapshotting the hero — we capture what's DISPLAYED, and a
      // consent banner over the product becomes the wishlist image
      // (Valentino's cookie wall shipped as a saved item's photo).
      // Hiding rather than clicking: nothing is consented to on the
      // user's behalf.
      try {
        var candidates = document.querySelectorAll(
          'body > *, body > * > *, [class*="cookie"], [id*="cookie"], ' +
          '[class*="consent"], [id*="consent"], [class*="overlay"], ' +
          '[class*="modal"], [aria-modal="true"], #onetrust-consent-sdk'
        );
        var vw = window.innerWidth, vh = window.innerHeight;
        for (var q = 0; q < candidates.length; q++) {
          var el2 = candidates[q];
          var st = window.getComputedStyle(el2);
          if (st.display === 'none') continue;
          if (st.position !== 'fixed' && st.position !== 'sticky' && el2.getAttribute('aria-modal') !== 'true') continue;
          var rr = el2.getBoundingClientRect();
          if (rr.width * rr.height > vw * vh * 0.25) {
            el2.style.setProperty('display', 'none', 'important');
          }
        }
        document.documentElement.style.setProperty('overflow', 'auto', 'important');
        document.body.style.setProperty('overflow', 'auto', 'important');
      } catch (e) {}

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
        // Scroll the hero's TOP to a fixed 140px from the viewport
        // top — below any mobile site header. Centering tall product
        // images pushed their top edge underneath fixed logo bars,
        // which then appeared inside the capture (FARFETCH's bar and
        // breadcrumbs shipped inside saved item photos).
        try {
          var hr = best.getBoundingClientRect();
          window.scrollTo(0, Math.max(0, hr.top + window.pageYOffset - 140));
        } catch (e) {}
      }
      return JSON.stringify({
        name: typeof name === 'string' ? name : null,
        price: typeof price === 'string' ? price : (typeof price === 'number' ? String(price) : null),
        brand: typeof brand === 'string' ? brand : null,
        hasImage: !!best
      });
    })()
    """

    /// On-screen rect of the tagged hero image, post-scroll — clamped
    /// below any fixed header bar and to the viewport, so site chrome
    /// (logo bars, breadcrumbs) doesn't end up inside the capture.
    private static let taggedRectJS = """
    (function () {
      var el = document.querySelector('[data-yafa-hero]');
      if (!el) return JSON.stringify({ x: 0, y: 0, w: 0, h: 0 });
      var r = el.getBoundingClientRect();
      var top = Math.max(r.top, 0), left = Math.max(r.left, 0);
      var right = Math.min(r.right, window.innerWidth);
      var bottom = Math.min(r.bottom, window.innerHeight);
      // Walk the top edge down past anything DRAWN OVER the hero
      // (site headers, breadcrumbs, sticky bars). CSS heuristics and
      // window scrolling both failed on real shops (Farfetch and
      // Valentino scroll inner containers, so the hero stays parked
      // under the header) — elementFromPoint asks the renderer
      // directly what's topmost at a point, which is ground truth.
      function obstructed(y) {
        var xs = [left + (right - left) * 0.25,
                  left + (right - left) * 0.5,
                  left + (right - left) * 0.75];
        for (var i = 0; i < xs.length; i++) {
          var t = document.elementFromPoint(xs[i], y);
          if (!t) continue;
          if (t === el || el.contains(t) || t.contains(el)) continue;
          return true;
        }
        return false;
      }
      var scanLimit = top + (bottom - top) * 0.5;
      var cleanTop = top;
      while (cleanTop < scanLimit && obstructed(cleanTop + 4)) cleanTop += 10;
      // If half the image is 'obstructed', it's probably a transparent
      // zoom layer over the whole photo — capture from the original
      // top rather than eating the product.
      if (cleanTop < scanLimit) top = cleanTop;
      return JSON.stringify({ x: left, y: top, w: Math.max(0, right - left), h: Math.max(0, bottom - top) });
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

//
//  ShareViewController.swift
//  YafaShare
//
//  Saves a shared product URL to the user's Yafa wishlist.
//

import UIKit
import UniformTypeIdentifiers
import Lottie

class ShareViewController: UIViewController {

    // MARK: UI

    private let card = UIView()
    private let logoView = UIImageView()
    private let titleLabel = UILabel()
    private let checkView = UIImageView()

    private var starViews: [LottieAnimationView] = []
    /// The app's real `star-anim` Lottie sparkles — big, scattered across the
    /// white sheet around the logo (positions relative to `card`, per-star size).
    private let sparkleSpecs: [(name: String, x: CGFloat, y: CGFloat, size: CGFloat)] = [
        ("star-anim-1", 0.12, 0.26, 170),
        ("star-anim-3", 0.87, 0.30, 146),
        ("star-anim-2", 0.20, 0.70, 158),
        ("star-anim-5", 0.82, 0.66, 188),
        ("star-anim-4", 0.50, 0.08, 132),
        ("star-anim-2", 0.97, 0.50, 118),
        ("star-anim-1", 0.03, 0.52, 130),
        ("star-anim-3", 0.50, 0.92, 124),
    ]

    // Dark grey — matches the app's body type.
    private let textDark = UIColor(red: 0x37 / 255, green: 0x41 / 255, blue: 0x51 / 255, alpha: 1)
    private let brandAqua = UIColor(red: 0x0B / 255, green: 0xC3 / 255, blue: 0xCC / 255, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupCard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Lay the sparkles out across the sheet, around the logo.
        for (i, v) in starViews.enumerated() {
            let spec = sparkleSpecs[i]
            v.bounds = CGRect(x: 0, y: 0, width: spec.size, height: spec.size)
            v.center = CGPoint(x: card.bounds.width * spec.x, y: card.bounds.height * spec.y)
        }
    }

    private func setupCard() {
        // The whole sheet is white; `card` is just a transparent centred
        // container the logo/text/sparkles lay out against.
        card.backgroundColor = .clear
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        // The app's real Lottie star sparkles, looping behind the logo.
        setupSparkles()

        logoView.image = UIImage(named: "logo")
        logoView.contentMode = .scaleAspectFit
        logoView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.attributedText = capsText("Adding to Yafa", color: textDark)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Small aqua checkmark, shown only on success (next to "ADDED TO YAFA").
        checkView.image = UIImage(systemName: "checkmark")
        checkView.tintColor = brandAqua
        checkView.contentMode = .scaleAspectFit
        checkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        checkView.setContentHuggingPriority(.required, for: .horizontal)
        checkView.isHidden = true
        checkView.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = UIStackView(arrangedSubviews: [checkView, titleLabel])
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 5
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(logoView)
        card.addSubview(statusStack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 360),
            card.heightAnchor.constraint(equalToConstant: 300),

            logoView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -14),
            logoView.widthAnchor.constraint(equalToConstant: 110),
            logoView.heightAnchor.constraint(equalToConstant: 62),

            statusStack.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 22),
            statusStack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 20),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),
        ])
    }

    /// Uppercase, tracked, faint — matches the app's secondary all-caps labels.
    private func capsText(_ s: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .kern: 1.4,
            .font: UIFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: color,
        ])
    }

    // MARK: Sparkles

    private func setupSparkles() {
        for (i, spec) in sparkleSpecs.enumerated() {
            let star = LottieAnimationView(name: spec.name)
            star.loopMode = .playOnce
            star.contentMode = .scaleAspectFit
            star.backgroundBehavior = .pauseAndRestore
            star.isUserInteractionEnabled = false
            card.addSubview(star)            // added before the logo → sits behind it
            starViews.append(star)
            // Stagger each star's first twinkle so they fire out of sync — the
            // same spawn-over-time feel as the app's generation sparkle field.
            let initialDelay = Double(i) * 0.22 + Double.random(in: 0...0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self, weak star] in
                guard let self, let star else { return }
                self.twinkle(star)
            }
        }
    }

    /// Play one twinkle, then re-fire after a short random gap — gives each
    /// star an independent, offset rhythm rather than a synced loop.
    private func twinkle(_ star: LottieAnimationView) {
        star.play { [weak self, weak star] finished in
            guard finished, let self, let star else { return }
            let gap = Double.random(in: 0.35...1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                self.twinkle(star)
            }
        }
    }

    // MARK: Flow

    private func run() async {
        guard let product = await extractProduct() else {
            await finish(message: "No link to save", ok: false)
            return
        }
        guard var token = await accessToken(forceRefresh: false) else {
            await finish(message: "Open the Yafa app to enable saving", ok: false)
            return
        }

        var status = await postSave(product, token: token)
        // Token may have expired between checks — force one refresh and retry.
        if status == 401, let refreshed = await accessToken(forceRefresh: true) {
            token = refreshed
            status = await postSave(product, token: token)
        }

        if let status, (200..<300).contains(status) {
            await finish(message: "Added to Yafa", ok: true)
        } else if status == 422 {
            await finish(message: "Couldn't read this product", ok: false)
        } else {
            await finish(message: "Couldn't save — try again", ok: false)
        }
    }

    @MainActor
    private func finish(message: String, ok: Bool) async {
        // Swap the text; on success reveal the little aqua checkmark.
        titleLabel.attributedText = capsText(message, color: textDark)
        if ok {
            checkView.isHidden = false
            checkView.alpha = 0
            UIView.animate(withDuration: 0.25) { self.checkView.alpha = 1 }
        }
        try? await Task.sleep(nanoseconds: ok ? 1_050_000_000 : 1_450_000_000)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: Product extraction

    /// What the share sheet handed us — the URL plus whatever the in-page JS
    /// managed to scrape (nil fields when shared from a non-Safari context).
    private struct SharedProduct {
        var url: URL
        var name: String?
        var image: String?
        /// Base64 JPEG data URI of the image, grabbed in-page (bypasses
        /// server-side fetch of bot-walled retailer CDNs). Used for FAL.
        var imageData: String?
        var price: String?
        var brand: String?
    }

    private func extractProduct() async -> SharedProduct? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }

        // 1. JavaScript preprocessing results (Safari) — the fields GetProduct.js
        //    pulled straight from the live page, past any bot-wall. One retry
        //    after a beat: on slow anti-bot pages the script can complete
        //    just after the sheet opens, and the first load throws
        //    "Cannot load representation" while results aren't ready.
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) else { continue }
                var dict = try? await loadPlist(provider)
                if dict == nil {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    dict = try? await loadPlist(provider)
                }
                if let dict,
                   let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let urlStr = results["url"] as? String,
                   let url = URL(string: urlStr) {
                    return SharedProduct(
                        url: url,
                        name: results["name"] as? String,
                        image: results["image"] as? String,
                        imageData: results["imageData"] as? String,
                        price: results["price"] as? String,
                        brand: results["brand"] as? String
                    )
                }
            }
        }

        // 2. Plain URL (the primary path now that JS preprocessing is
        //    off) — server-side scrape fills the metadata.
        if let url = await extractURL() {
            return SharedProduct(url: unwrapGoogleRedirect(url), name: nil, image: nil, imageData: nil, price: nil, brand: nil)
        }
        return nil
    }

    private func loadPlist(_ provider: NSItemProvider) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: item as? [String: Any])
            }
        }
    }

    // MARK: URL extraction (fallback)

    /// Google surfaces (Lens results, search redirects) wrap the real
    /// retailer link in their own URL. Saving the wrapper makes a
    /// useless wishlist item — unwrap the target when present.
    private func unwrapGoogleRedirect(_ url: URL) -> URL {
        guard let host = url.host, host.contains("google.") else { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        for key in ["url", "u", "q", "imgrefurl", "adurl"] {
            if let value = components.queryItems?.first(where: { $0.name == key })?.value,
               let target = URL(string: value),
               let targetHost = target.host,
               !targetHost.contains("google.") {
                return target
            }
        }
        return url
    }

    private func extractURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await loadURL(provider, type: UTType.url.identifier) {
                    return url
                }
            }
            // Fallback: some apps share the link as plain text.
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await loadText(provider),
                   let url = firstURL(in: text) {
                    return url
                }
            }
        }
        return nil
    }

    private func loadURL(_ provider: NSItemProvider, type: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let url = item as? URL { cont.resume(returning: url) }
                else if let data = item as? Data, let s = String(data: data, encoding: .utf8), let url = URL(string: s) { cont.resume(returning: url) }
                else if let s = item as? String, let url = URL(string: s) { cont.resume(returning: url) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: item as? String)
            }
        }
    }

    private func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    // MARK: Auth (App Group session, self-refreshing)

    /// Returns a valid access token, refreshing the stored session if needed.
    private func accessToken(forceRefresh: Bool) async -> String? {
        guard let session = ExtensionSessionStore.load() else { return nil }
        if !forceRefresh, session.isFresh() { return session.accessToken }
        return await refresh(session)?.accessToken
    }

    private func refresh(_ session: ExtensionSession) async -> ExtensionSession? {
        var comps = URLComponents(url: YafaShared.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(YafaShared.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            return nil
        }
        let expiresAt: TimeInterval
        if let ea = obj["expires_at"] as? TimeInterval { expiresAt = ea }
        else if let ein = obj["expires_in"] as? TimeInterval { expiresAt = Date().timeIntervalSince1970 + ein }
        else { expiresAt = Date().timeIntervalSince1970 + 3600 }

        let updated = ExtensionSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, userId: session.userId)
        ExtensionSessionStore.save(updated)
        return updated
    }

    // MARK: Save

    /// POSTs to `share-save`; returns the HTTP status (nil on transport error).
    /// Sends the in-page-scraped fields when present so the server can skip
    /// fetching the (often bot-blocked) page.
    private func postSave(_ product: SharedProduct, token: String) async -> Int? {
        var payload: [String: Any] = ["url": product.url.absoluteString]
        if let v = product.name, !v.isEmpty { payload["name"] = v }
        if let v = product.image, !v.isEmpty { payload["image"] = v }
        if let v = product.imageData, !v.isEmpty { payload["imageData"] = v }
        if let v = product.price, !v.isEmpty { payload["price"] = v }
        if let v = product.brand, !v.isEmpty { payload["brand"] = v }

        let endpoint = YafaShared.supabaseURL.appendingPathComponent("functions/v1/share-save")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(YafaShared.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 30

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return http.statusCode
    }
}

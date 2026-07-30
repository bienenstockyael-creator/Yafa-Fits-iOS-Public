import SwiftUI
import WebKit

/// In-app browser for the Google Lens shop fallback, compiled into
/// BOTH the app and the App Clip.
///
/// Why not just open Safari: Lens-by-URL (`uploadbyurl`) breaks in
/// Safari when the user is signed into Google — EU sessions route
/// through the privacy flow and the redirect drops the uploaded
/// image, landing on an empty results page. A WKWebView uses the
/// app's OWN cookie store (no Google login), so Lens behaves like a
/// clean browser: one consent card ever, then visual matches. It
/// also keeps shoppers inside Yafa instead of bouncing them to
/// Safari.
///
/// The web view is also what makes "Lens first, name search second"
/// an actual cascade: we observe navigation, so a hard load failure
/// automatically retries with the text-search fallback URL.
@MainActor
enum ShopBrowser {
    static func present(primary: URL, fallback: URL?) {
        guard let top = topViewController() else {
            // No window to present from — last resort, hand to the
            // system browser rather than dropping the tap.
            UIApplication.shared.open(primary)
            return
        }
        let closer = Closer()
        let sheet = ShopBrowserSheet(
            url: primary,
            fallbackURL: fallback,
            onClose: { closer.close() }
        )
        let host = UIHostingController(rootView: sheet)
        closer.controller = host
        host.modalPresentationStyle = .pageSheet
        if let presentation = host.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first(where: \.isKeyWindow)?
            .rootViewController
        guard var top = root else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    /// Bridges the SwiftUI close button back to the UIKit dismiss
    /// without retaining the hosting controller.
    private final class Closer {
        weak var controller: UIViewController?
        func close() { controller?.dismiss(animated: true) }
    }
}

struct ShopBrowserSheet: View {
    let url: URL
    let fallbackURL: URL?
    var onClose: () -> Void

    /// Live copy of the web page's background color. The sheet's own
    /// chrome adopts it so the page never reads as a "second sheet"
    /// inside ours — Google in dark mode gets a dark sheet, a white
    /// shop gets a light one.
    @State private var pageBackground = UIColor.systemGroupedBackground
    @State private var isLoading = true

    private var pageIsDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        pageBackground.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Fully transparent reports as black — treat it as "unknown,
        // assume light" so the chrome doesn't flash dark on load.
        guard a > 0.1 else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SHOP THIS LOOK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(pageIsDark ? Color.white.opacity(0.55) : AppPalette.textFaint)

                Spacer()

                Button(action: onClose) {
                    if pageIsDark {
                        AppIcon(glyph: .xmark, size: 12, color: .white.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    } else {
                        AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                            .frame(width: 32, height: 32)
                            .appCircle(shadowRadius: 0, shadowY: 0)
                    }
                }
                .buttonStyle(SolidPressButtonStyle())
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.top, LayoutMetrics.medium)
            .padding(.bottom, LayoutMetrics.xSmall)

            ShopWebView(
                url: url,
                fallbackURL: fallbackURL,
                onBackgroundChange: { color in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        pageBackground = color
                    }
                },
                onLoadingChange: { loading in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isLoading = loading
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                // Lens takes a few seconds server-side (image fetch +
                // visual match) — an intentional loading state on the
                // page's own color beats a silent blank page.
                if isLoading {
                    VStack(spacing: LayoutMetrics.small) {
                        ProgressView()
                            .tint(pageIsDark ? .white : AppPalette.textMuted)
                        Text("FINDING MATCHES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(pageIsDark ? Color.white.opacity(0.55) : AppPalette.textFaint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: pageBackground))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .background(Color(uiColor: pageBackground).ignoresSafeArea())
    }
}

private struct ShopWebView: UIViewRepresentable {
    let url: URL
    let fallbackURL: URL?
    var onBackgroundChange: (UIColor) -> Void
    var onLoadingChange: (Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onLoadingChange = onLoadingChange
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        // Follow the page's own background so the sheet chrome can
        // match it — KVO fires as the page (or its dark mode) loads.
        context.coordinator.observeBackground(of: web, onChange: onBackgroundChange)
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(fallbackURL: fallbackURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let fallbackURL: URL?
        var onLoadingChange: ((Bool) -> Void)?
        private var fellBack = false
        private var finishedOnce = false
        private var backgroundObservation: NSKeyValueObservation?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // First finished navigation = real content on screen
            // (later Lens redirects render their own skeletons).
            guard !finishedOnce else { return }
            finishedOnce = true
            onLoadingChange?(false)
        }

        init(fallbackURL: URL?) {
            self.fallbackURL = fallbackURL
        }

        func observeBackground(
            of webView: WKWebView,
            onChange: @escaping (UIColor) -> Void
        ) {
            backgroundObservation = webView.observe(
                \.underPageBackgroundColor,
                options: [.initial, .new]
            ) { webView, _ in
                let color = webView.underPageBackgroundColor
                    .resolvedColor(with: webView.traitCollection)
                DispatchQueue.main.async { onChange(color) }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            loadFallback(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            loadFallback(in: webView)
        }

        private func loadFallback(in webView: WKWebView) {
            guard !fellBack, let fallbackURL else {
                // Nothing left to try — reveal whatever the web view
                // shows rather than spinning forever.
                onLoadingChange?(false)
                return
            }
            fellBack = true
            webView.load(URLRequest(url: fallbackURL))
        }
    }
}

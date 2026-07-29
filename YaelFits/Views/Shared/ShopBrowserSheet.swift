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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SHOP THIS LOOK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.textFaint)

                Spacer()

                Button(action: onClose) {
                    AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                        .frame(width: 32, height: 32)
                        .appCircle(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(SolidPressButtonStyle())
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.top, LayoutMetrics.medium)
            .padding(.bottom, LayoutMetrics.xSmall)

            ShopWebView(url: url, fallbackURL: fallbackURL)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        topTrailingRadius: 16
                    )
                )
                .ignoresSafeArea(edges: .bottom)
        }
        .background(AppPalette.groupedBackground)
    }
}

private struct ShopWebView: UIViewRepresentable {
    let url: URL
    let fallbackURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(fallbackURL: fallbackURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let fallbackURL: URL?
        private var fellBack = false

        init(fallbackURL: URL?) {
            self.fallbackURL = fallbackURL
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
            guard !fellBack, let fallbackURL else { return }
            fellBack = true
            webView.load(URLRequest(url: fallbackURL))
        }
    }
}

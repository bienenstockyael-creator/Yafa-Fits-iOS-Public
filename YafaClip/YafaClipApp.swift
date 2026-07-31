import SwiftUI

// The Yafa App Clip: a shared fit, spinnable and shoppable, with a
// one-tap path into the full app. Invoked from yafafits.com/fit/<slug>
// links (Safari, iMessage, QR / App Clip Codes). Deliberately tiny:
// no SDKs, no accounts — the clip reads public data and funnels every
// interaction to the install overlay.
@main
struct YafaClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipFitView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    model.handleInvocation(url: url)
                }
                .onAppear {
                    // Xcode's testing convention (and ours via simctl):
                    // an _XCAppClipURL env var stands in for the real
                    // invocation. Real launches deliver the
                    // NSUserActivity above instead.
                    if model.invocationSlug == nil,
                       let raw = ProcessInfo.processInfo.environment["_XCAppClipURL"],
                       let url = URL(string: raw) {
                        model.handleInvocation(url: url)
                    }
                }
        }
    }
}

@Observable
@MainActor
final class ClipModel {
    enum Phase {
        case loading
        case ready
        case unavailable
    }

    var phase: Phase = .loading
    var fit: ClipFit?
    /// The slug (or outfit id) from the invocation URL — preserved so
    /// the full app can continue exactly here after install.
    var invocationSlug: String?
    /// Creator profile, warmed in the background the moment the fit
    /// loads — the header tap then opens a fully-formed profile with
    /// zero visible loading (clip viewers are all first-timers; a
    /// spinner-y profile reads as broken).
    var preloadedProfile: ClipProfile?

    private var loadTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?

    /// Fetch the profile + warm the first grid thumbnails.
    private func preloadProfile(userId: String) {
        profileTask?.cancel()
        profileTask = Task {
            guard let profile = await ClipDataService.loadProfile(userId: userId) else { return }
            guard !Task.isCancelled else { return }
            self.preloadedProfile = profile
            // First two grid rows' thumbs — enough that the sheet
            // opens looking complete; the rest stream lazily.
            await ClipThumbImage.prefetch(urls: profile.fits.prefix(6).compactMap(\.thumbURL))
        }
    }

    func handleInvocation(url: URL) {
        // yafafits.com/fit/<slug> — last path component is the key.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[parts.count - 2] == "fit" else {
            // Unknown invocation shape — show the newest public state
            // we can't resolve; the overlay still offers the app.
            phase = .unavailable
            return
        }
        let slug = parts[parts.count - 1]
        guard slug != invocationSlug else { return }
        invocationSlug = slug
        load(slug: slug)
    }

    func load(slug: String) {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task {
            if let fit = await ClipDataService.loadFit(slugOrId: slug) {
                guard !Task.isCancelled else { return }
                self.fit = fit
                self.phase = .ready
                // Warm the creator's profile behind the card.
                if preloadedProfile == nil {
                    preloadProfile(userId: fit.userId)
                }
            } else {
                guard !Task.isCancelled else { return }
                self.phase = .unavailable
            }
        }
    }
}

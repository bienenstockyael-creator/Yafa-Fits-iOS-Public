import SwiftUI
import UIKit

/// Mounts an invisible UIView inside a SwiftUI ScrollView, walks up
/// the view hierarchy on first attach to find the enclosing
/// `UIScrollView`, and observes its `contentOffset.y` via KVO. The
/// callback fires on every scroll tick.
///
/// **Prefer this over `GeometryReader` + `PreferenceKey` for any
/// scroll-driven UI in `OutfitGridView` (and similarly-structured
/// views in this codebase).** That SwiftUI pattern silently fails to
/// propagate from a top-level `VStack` depth in this view's
/// hierarchy — the listener only ever sees the preference's default
/// sentinel. Same pattern works elsewhere (per-cell hero frames,
/// `UserProfileView`'s swipe-down) so the issue is layout-specific
/// and not yet root-caused. This observer side-steps it entirely
/// by reading the UIKit scroll view directly.
///
/// Place at the top of the scroll's VStack with
/// `.frame(width: 0, height: 0)` so it costs no layout space.
struct ScrollOffsetObserver: UIViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView()
        // Capture the coordinator weakly so the view → closure →
        // coordinator chain can't keep the coordinator alive past
        // SwiftUI's intended lifecycle.
        view.onAttachedToScroll = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.bind(to: scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: ScrollProbeView, context: Context) {
        // Refresh the callback on rebuilds. No deferred work here —
        // the actual scroll-view attachment is driven by UIView's
        // own `didMoveToWindow` lifecycle, which fires synchronously
        // once the view is in the live hierarchy.
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    /// UIView subclass that fires `onAttachedToScroll` when it joins
    /// a window (and therefore has a reachable superview chain that
    /// includes the enclosing `UIScrollView`). Re-fires on
    /// reattachment so a view that's removed and added back binds
    /// to whatever scroll-view ancestor it currently has.
    final class ScrollProbeView: UIView {
        var onAttachedToScroll: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var candidate: UIView? = superview
            while let current = candidate {
                if let scroll = current as? UIScrollView {
                    onAttachedToScroll?(scroll)
                    return
                }
                candidate = current.superview
            }
        }
    }

    final class Coordinator: NSObject {
        var onScroll: (CGFloat) -> Void
        private var observation: NSKeyValueObservation?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        /// Idempotent in spirit (re-binding to the same scroll view
        /// is harmless) but also handles the swap case — if SwiftUI
        /// remounts us under a different scroll view, the old KVO
        /// observation is torn down before the new one starts.
        func bind(to scrollView: UIScrollView) {
            observation?.invalidate()
            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                self?.onScroll(scroll.contentOffset.y)
            }
        }

        deinit {
            observation?.invalidate()
        }
    }
}

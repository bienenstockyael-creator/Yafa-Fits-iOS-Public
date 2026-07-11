import UIKit

/// Works around an iOS touch-routing wedge after an app switch: touches
/// (including movement) keep reaching window-attached recognizers, but
/// recognizers attached to views inside the tree — UIScrollView pans,
/// cell scrub pans, SwiftUI's hosting-root gesture handling — stop
/// receiving them entirely. Every observable recognizer flag stays
/// healthy; only a view-tree remount (e.g. a tab switch) heals it.
///
/// Detaching and re-attaching a recognizer re-registers it with the
/// window's gesture environment, which is the part a remount rebuilds —
/// without disturbing view state, scroll offsets, or the recognizers'
/// targets and delegates. Run on every return to foreground; on a
/// healthy foreground it is a cheap no-op re-registration.
enum GestureRouteHealer {
    static func healAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                heal(window)
            }
        }
    }

    private static func heal(_ view: UIView) {
        if let recognizers = view.gestureRecognizers, !recognizers.isEmpty {
            // Only idle recognizers: never rip one that is mid-gesture.
            for recognizer in recognizers where recognizer.state == .possible {
                view.removeGestureRecognizer(recognizer)
                view.addGestureRecognizer(recognizer)
            }
        }
        for subview in view.subviews {
            heal(subview)
        }
    }
}

import SwiftUI
import UIKit

// MARK: - Two-finger detection

/// Reports the number of active touches on screen, without interfering with
/// scrolling, taps, or the pinch gesture. Used to disable the ScrollView's
/// scroll the instant a second finger lands, so a pinch can never be read as
/// a scroll. One finger still scrolls normally.
struct TouchCountReporter: UIViewRepresentable {
    let onChange: (Int) -> Void

    func makeUIView(context: Context) -> TouchCountView {
        let view = TouchCountView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TouchCountView, context: Context) {
        uiView.onChange = onChange
    }
}

final class TouchCountView: UIView {
    var onChange: (Int) -> Void = { _ in }
    private weak var recognizer: TouchCountGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window, recognizer == nil {
            let r = TouchCountGestureRecognizer()
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = SimultaneousGestureDelegate.shared
            r.onCountChange = { [weak self] count in self?.onChange(count) }
            window.addGestureRecognizer(r)
            recognizer = r
        } else if window == nil, let r = recognizer {
            r.view?.removeGestureRecognizer(r)
            recognizer = nil
            onChange(0)
        }
    }
}

/// Passive recognizer: it never transitions out of `.possible`, so it
/// observes touches without ever cancelling the scroll / tap / pinch.
final class TouchCountGestureRecognizer: UIGestureRecognizer {
    var onCountChange: (Int) -> Void = { _ in }

    /// Live window-wide touch count, readable SYNCHRONOUSLY from any
    /// UIKit gesture callback. The SwiftUI mirror (`twoFingersDown`
    /// state via `onCountChange`) needs a state-write → re-render →
    /// updateUIView roundtrip before it can disable a competing
    /// recognizer — under main-thread load that roundtrip loses the
    /// race against a beginning pan, and the pinch goes dead. This
    /// static lets `gestureRecognizerShouldBegin` ask "how many
    /// fingers are on the screen RIGHT NOW" with no roundtrip.
    private(set) static var liveTouchCount = 0
    #if DEBUG
    /// TEMP freeze forensics: every touch the WINDOW has ever seen.
    /// Compared against view-level tap counters to locate which layer
    /// eats touches during a freeze. Strip once the freeze is closed.
    private(set) static var totalTouchesBegan = 0
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        #if DEBUG
        Self.totalTouchesBegan += touches.count
        #endif
        report(event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        report(event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        report(event)
    }
    override func reset() {
        super.reset()
        Self.liveTouchCount = 0
        onCountChange(0)
    }

    private func report(_ event: UIEvent) {
        let active = (event.allTouches ?? []).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count
        Self.liveTouchCount = active
        onCountChange(active)
    }
}

final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SimultaneousGestureDelegate()
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}


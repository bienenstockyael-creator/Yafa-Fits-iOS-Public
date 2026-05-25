import SwiftUI
import UIKit

/// Information captured at the end of a horizontal pan. Carousel-style
/// parents use the ratio of `totalTranslation` to `excursionRange` to
/// tell scrubs (low ratio — drag went back and forth) from page swipes
/// (high ratio — drag was mostly one-direction).
struct HorizontalPanRelease {
    /// Signed cumulative translation: final touch X − initial touch X.
    let totalTranslation: CGFloat
    /// Max-positive minus min-negative reached during the drag.
    /// A purely one-direction drag has `|totalTranslation| == range`;
    /// a back-and-forth scrub has `range > |totalTranslation|`.
    let excursionRange: CGFloat

    /// Fraction of the drag that pulled in the net direction. 1.0 =
    /// purely one-direction; 0.0 = perfectly symmetric back-and-forth.
    /// Defined as 1.0 for a zero-range drag (vacuously monotonic; the
    /// distance check upstream filters those out).
    var monotonicityRatio: CGFloat {
        guard excursionRange > 0 else { return 1 }
        return abs(totalTranslation) / excursionRange
    }
}

struct InteractiveTouchSurface: UIViewRepresentable {
    var onTap: (() -> Void)? = nil
    var panEnabled = false
    var onHorizontalPanBegan: (() -> Void)? = nil
    var onHorizontalPanChanged: ((CGFloat) -> Void)? = nil
    var onHorizontalPanEnded: ((HorizontalPanRelease) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTap: onTap,
            onHorizontalPanBegan: onHorizontalPanBegan,
            onHorizontalPanChanged: onHorizontalPanChanged,
            onHorizontalPanEnded: onHorizontalPanEnded
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false

        let panRecognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panRecognizer.delegate = context.coordinator
        panRecognizer.maximumNumberOfTouches = 1
        panRecognizer.cancelsTouchesInView = true
        panRecognizer.isEnabled = panEnabled
        view.addGestureRecognizer(panRecognizer)
        context.coordinator.panRecognizer = panRecognizer

        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tapRecognizer.delegate = context.coordinator
        tapRecognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(tapRecognizer)
        context.coordinator.tapRecognizer = tapRecognizer

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onHorizontalPanBegan = onHorizontalPanBegan
        context.coordinator.onHorizontalPanChanged = onHorizontalPanChanged
        context.coordinator.onHorizontalPanEnded = onHorizontalPanEnded
        context.coordinator.panRecognizer?.isEnabled = panEnabled
        context.coordinator.tapRecognizer?.isEnabled = onTap != nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onHorizontalPanBegan: (() -> Void)?
        var onHorizontalPanChanged: ((CGFloat) -> Void)?
        var onHorizontalPanEnded: ((HorizontalPanRelease) -> Void)?

        weak var panRecognizer: UIPanGestureRecognizer?
        weak var tapRecognizer: UITapGestureRecognizer?

        private var lastTranslationX: CGFloat = 0
        private var totalTranslationX: CGFloat = 0
        private var minTranslationX: CGFloat = 0
        private var maxTranslationX: CGFloat = 0
        private var isPanning = false

        init(
            onTap: (() -> Void)?,
            onHorizontalPanBegan: (() -> Void)?,
            onHorizontalPanChanged: ((CGFloat) -> Void)?,
            onHorizontalPanEnded: ((HorizontalPanRelease) -> Void)?
        ) {
            self.onTap = onTap
            self.onHorizontalPanBegan = onHorizontalPanBegan
            self.onHorizontalPanChanged = onHorizontalPanChanged
            self.onHorizontalPanEnded = onHorizontalPanEnded
        }

        @objc func handleTap() {
            guard !isPanning else { return }
            onTap?()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translationX = recognizer.translation(in: recognizer.view).x

            switch recognizer.state {
            case .began:
                isPanning = true
                lastTranslationX = translationX
                totalTranslationX = translationX
                minTranslationX = translationX
                maxTranslationX = translationX
                onHorizontalPanBegan?()
            case .changed:
                guard isPanning else { return }
                let delta = translationX - lastTranslationX
                lastTranslationX = translationX
                totalTranslationX = translationX
                minTranslationX = min(minTranslationX, translationX)
                maxTranslationX = max(maxTranslationX, translationX)
                onHorizontalPanChanged?(delta)
            case .ended, .cancelled, .failed:
                guard isPanning else {
                    reset()
                    return
                }
                let release = HorizontalPanRelease(
                    totalTranslation: totalTranslationX,
                    excursionRange: maxTranslationX - minTranslationX
                )
                onHorizontalPanEnded?(release)
                reset()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }

            let velocity = panRecognizer.velocity(in: panRecognizer.view)
            return abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 40
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        private func reset() {
            lastTranslationX = 0
            totalTranslationX = 0
            minTranslationX = 0
            maxTranslationX = 0
            isPanning = false
        }
    }
}

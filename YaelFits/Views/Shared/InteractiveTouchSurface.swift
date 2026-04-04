import SwiftUI
import UIKit

struct InteractiveTouchSurface: UIViewRepresentable {
    var onTap: (() -> Void)? = nil
    var panEnabled = false
    var onHorizontalPanBegan: (() -> Void)? = nil
    var onHorizontalPanChanged: ((CGFloat) -> Void)? = nil
    var onHorizontalPanEnded: (() -> Void)? = nil

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
        var onHorizontalPanEnded: (() -> Void)?

        weak var panRecognizer: UIPanGestureRecognizer?
        weak var tapRecognizer: UITapGestureRecognizer?

        private var lastTranslationX: CGFloat = 0
        private var isPanning = false

        init(
            onTap: (() -> Void)?,
            onHorizontalPanBegan: (() -> Void)?,
            onHorizontalPanChanged: ((CGFloat) -> Void)?,
            onHorizontalPanEnded: (() -> Void)?
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
                onHorizontalPanBegan?()
            case .changed:
                guard isPanning else { return }
                let delta = translationX - lastTranslationX
                lastTranslationX = translationX
                onHorizontalPanChanged?(delta)
            case .ended, .cancelled, .failed:
                guard isPanning else {
                    reset()
                    return
                }
                onHorizontalPanEnded?()
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
            isPanning = false
        }
    }
}

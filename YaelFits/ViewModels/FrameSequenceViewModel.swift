import SwiftUI
import Combine

@Observable
class FrameSequenceViewModel {
    let outfit: Outfit
    var currentFrame: Int = 0
    var displayedFrame: Int?
    var displayedImage: UIImage?

    private var continuousFrame: Double = 0
    private var velocity: Double = 0
    private var displayLink: CADisplayLink?
    private var isEntranceActive = false
    private var entranceStartTime: CFTimeInterval = 0
    private var isAutoRotating = false

    init(outfit: Outfit, initialFrame: Int = 0, initialImage: UIImage? = nil) {
        self.outfit = outfit
        let clampedFrame = max(0, min(initialFrame, max(0, outfit.frameCount - 1)))
        currentFrame = clampedFrame
        continuousFrame = Double(clampedFrame)
        displayedFrame = initialImage == nil ? nil : clampedFrame
        displayedImage = initialImage
    }

    deinit {
        stopAnimationLoop()
    }

    // MARK: - Drag Gesture

    func dragBegan() {
        velocity = 0
        isEntranceActive = false
        stopAnimationLoop()
    }

    func dragChanged(delta: CGFloat) {
        let frameDelta = Double(delta) / Double(FrameConfig.pixelsPerFrame)
        continuousFrame += frameDelta
        velocity = frameDelta

        let total = Double(outfit.frameCount)
        continuousFrame = continuousFrame.truncatingRemainder(dividingBy: total)
        if continuousFrame < 0 { continuousFrame += total }

        let newFrame = Int(continuousFrame) % outfit.frameCount
        if newFrame != currentFrame {
            currentFrame = newFrame
            loadCurrentFrame()
            Task {
                await FrameLoader.shared.primeFrames(for: outfit, center: resolvedFrameIndex(newFrame))
            }
        }
    }

    func dragEnded() {
        startInertia()
    }

    // MARK: - Animation

    func startEntrance() {
        velocity = 0
        isAutoRotating = false
        isEntranceActive = true
        continuousFrame = 0
        currentFrame = 0
        loadCurrentFrame()
        entranceStartTime = CACurrentMediaTime()
        startAnimationLoop()
    }

    func startAutoRotate() {
        isAutoRotating = true
        if displayLink == nil { startAnimationLoop() }
    }

    func stopAutoRotate() {
        isAutoRotating = false
        if abs(velocity) < FrameConfig.velocityThreshold {
            stopAnimationLoop()
        }
    }

    func loadFirstFrame() {
        Task {
            let image = await FrameLoader.shared.frame(for: outfit, index: resolvedFrameIndex(0))
            await MainActor.run {
                guard self.currentFrame == 0 else { return }
                self.displayedFrame = 0
                self.displayedImage = image
            }
        }
    }

    func ensureCurrentFrameLoaded() {
        guard displayedImage == nil else { return }
        loadCurrentFrame()
    }

    func setFrame(_ frame: Int, image: UIImage? = nil) {
        let clampedFrame = max(0, min(frame, max(0, outfit.frameCount - 1)))
        velocity = 0
        isEntranceActive = false
        currentFrame = clampedFrame
        continuousFrame = Double(clampedFrame)
        displayedFrame = image == nil ? nil : clampedFrame
        displayedImage = image

        if image == nil {
            loadCurrentFrame(frame: clampedFrame)
        }
    }

    // MARK: - Private

    func loadCurrentFrame(frame: Int? = nil) {
        let requestedFrame = max(0, min(frame ?? currentFrame, max(0, outfit.frameCount - 1)))
        let resolvedFrame = resolvedFrameIndex(requestedFrame)
        Task {
            let image = await FrameLoader.shared.frame(for: outfit, index: resolvedFrame)
            await MainActor.run {
                guard self.currentFrame == requestedFrame else { return }
                self.displayedFrame = requestedFrame
                self.displayedImage = image
            }
        }
    }

    private func startInertia() {
        if displayLink == nil { startAnimationLoop() }
    }

    private func startAnimationLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(tick: { [weak self] in
            self?.tick()
        }), selector: #selector(DisplayLinkTarget.handleTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAnimationLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let total = Double(outfit.frameCount)

        if isEntranceActive {
            let elapsed = CACurrentMediaTime() - entranceStartTime
            let duration = FrameConfig.entranceDurationSeconds
            let progress = min(elapsed / duration, 1.0)
            // Ease-out quadratic
            let eased = 1.0 - (1.0 - progress) * (1.0 - progress)
            continuousFrame = eased * total
            if progress >= 1.0 {
                isEntranceActive = false
                continuousFrame = 0
            }
        } else if abs(velocity) > FrameConfig.velocityThreshold {
            velocity *= FrameConfig.friction
            continuousFrame += velocity
        } else if isAutoRotating {
            continuousFrame += FrameConfig.autoRotateSpeed
        } else {
            velocity = 0
            stopAnimationLoop()
            return
        }

        continuousFrame = continuousFrame.truncatingRemainder(dividingBy: total)
        if continuousFrame < 0 { continuousFrame += total }

        let newFrame = Int(continuousFrame) % outfit.frameCount
        if newFrame != currentFrame {
            currentFrame = newFrame
            loadCurrentFrame()
            Task {
                await FrameLoader.shared.primeFrames(for: outfit, center: resolvedFrameIndex(newFrame))
            }
        }
    }

    private func resolvedFrameIndex(_ logicalFrame: Int) -> Int {
        let clampedFrame = max(0, min(logicalFrame, max(0, outfit.frameCount - 1)))
        guard outfit.rotationReversed else { return clampedFrame }
        return max(0, outfit.frameCount - 1 - clampedFrame)
    }
}

// CADisplayLink requires an @objc target
private class DisplayLinkTarget {
    let tick: () -> Void
    init(tick: @escaping () -> Void) { self.tick = tick }
    @objc func handleTick() { tick() }
}

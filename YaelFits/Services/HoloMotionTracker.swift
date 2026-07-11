import CoreMotion
import Foundation

/// Singleton wrapper around `CMMotionManager` that publishes normalized
/// device tilt for the holographic card shader. Reference-counted so
/// CoreMotion only runs while at least one holo card is on-screen.
///
/// Roll/pitch are clamped + lowpass-smoothed so the shader doesn't
/// jitter from sensor noise; the smoothing also damps fast flicks
/// which would otherwise produce a strobe-y rainbow.
@Observable
@MainActor
final class HoloMotionTracker {
    static let shared = HoloMotionTracker()

    /// Roll in [-1, 1]. -1 = tilted hard left, +1 = hard right.
    private(set) var roll: Double = 0

    /// Pitch in [-1, 1]. -1 = tilted toward user, +1 = away.
    private(set) var pitch: Double = 0

    /// Smoothed attitude in RADIANS, unclamped and unnormalized — for
    /// consumers that calibrate against a captured baseline (the chrome
    /// wordmark) instead of using the absolute gravity-referenced tilt.
    /// Absolute tilt bakes the user's hold angle into the effect: a
    /// phone is always pitched toward the face, so the reflection
    /// starts pre-shifted for everyone. Baseline-relative tilt starts
    /// the effect centered at whatever angle the card was opened.
    private(set) var rollRadians: Double = 0
    private(set) var pitchRadians: Double = 0

    /// False until the first CoreMotion sample lands after `start()` —
    /// baseline capture must wait for a real reading, or it calibrates
    /// against the zero placeholder.
    private(set) var hasSample = false

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "yafa.holo-motion"
        q.qualityOfService = .userInteractive
        return q
    }()
    private var startCount = 0

    /// Hand-tilt range we map to ±1. ~40° in radians; beyond this the
    /// gyro-driven phase saturates rather than running away.
    private static let tiltRange: Double = 0.7

    /// Lowpass alpha — higher = more responsive but jittery; lower =
    /// smoother but laggy. 0.15 lands close to the AE evolution feel.
    private static let smoothingAlpha: Double = 0.15

    private init() {}

    /// Each holo card calls `start()` on appear and `stop()` on
    /// disappear. CoreMotion stays running as long as the count is > 0,
    /// so when no Pro cards are visible we drop the sensor entirely.
    func start() {
        startCount += 1
        guard startCount == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let rawRoll = max(-1, min(1, motion.attitude.roll / Self.tiltRange))
            let rawPitch = max(-1, min(1, motion.attitude.pitch / Self.tiltRange))
            let radRoll = motion.attitude.roll
            let radPitch = motion.attitude.pitch
            Task { @MainActor in
                self.roll = self.roll * (1 - Self.smoothingAlpha) + rawRoll * Self.smoothingAlpha
                self.pitch = self.pitch * (1 - Self.smoothingAlpha) + rawPitch * Self.smoothingAlpha
                if self.hasSample {
                    self.rollRadians = self.rollRadians * (1 - Self.smoothingAlpha) + radRoll * Self.smoothingAlpha
                    self.pitchRadians = self.pitchRadians * (1 - Self.smoothingAlpha) + radPitch * Self.smoothingAlpha
                } else {
                    // Seed the lowpass with the first real reading so a
                    // baseline captured moments later isn't polluted by
                    // the filter converging up from zero.
                    self.rollRadians = radRoll
                    self.pitchRadians = radPitch
                    self.hasSample = true
                }
            }
        }
    }

    func stop() {
        startCount = max(0, startCount - 1)
        if startCount == 0 {
            manager.stopDeviceMotionUpdates()
            hasSample = false
        }
    }
}

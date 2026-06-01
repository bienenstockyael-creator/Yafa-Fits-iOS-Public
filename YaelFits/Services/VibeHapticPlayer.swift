import CoreHaptics
import UIKit

/// Plays a multi-event haptic pattern matched to the vibes
/// wave burst's visual envelope. Uses Core Haptics for fine-
/// grained control: a sharp transient on tap, a continuous
/// haptic that rises and falls with the wave's lifetime, and
/// a soft tail transient as the ripple resolves.
///
/// Falls back to `UIImpactFeedbackGenerator` on devices where
/// Core Haptics isn't supported (or fails to start).
@MainActor
final class VibeHapticPlayer {
    static let shared = VibeHapticPlayer()

    private var engine: CHHapticEngine?
    private var enginePrepared = false

    private init() {
        prepareEngine()
    }

    /// Fire the wave-burst haptic. Idempotent and safe to call
    /// from any tap path. If Core Haptics is unavailable, this
    /// falls back to a single medium UIImpactFeedbackGenerator
    /// transient so the user still feels something.
    func playWaveBurst() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallbackHaptic()
            return
        }
        // If the engine fell into a stopped state (system
        // interruption — phone call, audio session shift, etc.),
        // the `stoppedHandler` set `enginePrepared = false` but
        // `resetHandler` only fires on system resets. Without an
        // explicit restart here, every subsequent vibe would
        // fall back to the basic impact generator — that's why
        // the rich pattern had stopped being felt after a while.
        // Try to start the existing engine before bailing.
        if !enginePrepared {
            startEngine()
        }
        guard enginePrepared, let engine = engine else {
            fallbackHaptic()
            return
        }

        do {
            // Cascade of transient "ring pulses" that follow the
            // visual wave outward. Mirrors the shader's
            // expanding ring crests: pulses start strong + sharp
            // (matching the bright initial wave near the tap),
            // then progressively softer + duller as the wave
            // spreads out and dims. Spacing also widens slightly
            // toward the end — same as the shader's ringFreq
            // going from 0.080 → 0.030 (tight rings early, more
            // spaced apart late).
            //
            // Tuple format: (time, intensity, sharpness).
            // Intensities pushed higher across the board for a
            // stronger overall feel — first pulse at the ceiling
            // (1.0), tail pulses elevated so the late
            // ring-residue is still clearly perceptible.
            let ringPulses: [(TimeInterval, Float, Float)] = [
                (0.00, 1.00, 0.80), // initial tap — at ceiling
                (0.12, 0.92, 0.70),
                (0.26, 0.82, 0.60),
                (0.42, 0.70, 0.50),
                (0.60, 0.58, 0.40),
                (0.80, 0.44, 0.30),
                (1.00, 0.28, 0.20)  // tail — was 0.14, now 2× stronger
            ]
            let pulseEvents = ringPulses.map { (time, intensity, sharpness) in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        .init(parameterID: .hapticIntensity, value: intensity),
                        .init(parameterID: .hapticSharpness, value: sharpness)
                    ],
                    relativeTime: time
                )
            }

            // Sustained rumble underneath the pulses. Duration
            // stretched to 1.10s to match the slowed wave lifetime,
            // so the rumble breathes the full length of the burst.
            let rumble = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.0),
                    .init(parameterID: .hapticSharpness, value: 0.25)
                ],
                relativeTime: 0.02,
                duration: 1.10
            )

            // Rumble intensity envelope — control-point values
            // raised (peak 0.45 → 0.70, intermediate 0.30 → 0.50,
            // tail 0.15 → 0.28) so the sustained bed of vibration
            // under the transient pulses is more present.
            let intensityCurve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0.00, value: 0.0),
                    .init(relativeTime: 0.18, value: 0.70),
                    .init(relativeTime: 0.52, value: 0.50),
                    .init(relativeTime: 0.86, value: 0.28),
                    .init(relativeTime: 1.10, value: 0.0)
                ],
                relativeTime: 0.02
            )

            let pattern = try CHHapticPattern(
                events: pulseEvents + [rumble],
                parameterCurves: [intensityCurve]
            )
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallbackHaptic()
        }
    }

    private func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics
        else { return }
        do {
            let engine = try CHHapticEngine()
            // Auto-restart if the system stops the engine
            // (e.g. after a phone call interrupts).
            engine.stoppedHandler = { [weak self] _ in
                self?.enginePrepared = false
            }
            engine.resetHandler = { [weak self] in
                self?.startEngine()
            }
            try engine.start()
            self.engine = engine
            self.enginePrepared = true
        } catch {
            enginePrepared = false
        }
    }

    private func startEngine() {
        guard let engine = engine else { return }
        do {
            try engine.start()
            enginePrepared = true
        } catch {
            enginePrepared = false
        }
    }

    private func fallbackHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

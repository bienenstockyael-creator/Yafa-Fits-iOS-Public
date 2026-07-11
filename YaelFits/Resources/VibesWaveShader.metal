#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

/// Fluid water-ripple wave function. Returns the wave value
/// at this position for the given distance from the burst
/// origin and the current burst progress.
///
/// Tuned for a slow, continuous, organic feel: lower
/// frequency so rings are wider and fewer-visible at once,
/// smoother distance perturbation so the rings undulate
/// gently, and amplitude modulation that breathes rather
/// than chops the wave into sectors.
static float fluidRingWave(
    float2 position,
    float dist,
    float progress,
    float2 size
) {
    // Distance perturbation: large, low-frequency noise warps
    // the effective distance. Stronger amplitude than before
    // (8% of view height vs 5%) so rings visibly undulate.
    float2 perturbInput = position * 0.0022
                        + float2(progress * 0.45, progress * 0.32);
    float perturb = valueNoise(perturbInput) - 0.5;
    float perturbedDist = dist + perturb * size.y * 0.08;

    // Ring frequency decreases with progress: tight close-
    // together rings at the start of the burst, gradually
    // spreading out as the wave expands. Mimics the way a
    // physical splash sends out a tight cluster of ripples
    // initially that fan apart as they propagate.
    float ringFreq = mix(0.080, 0.030, smoothstep(0.0, 0.6, progress));
    float primary = sin(perturbedDist * ringFreq - progress * 8.5);
    // Secondary at ~1.7× the primary's frequency follows the
    // same expansion curve.
    float secondary = sin(perturbedDist * ringFreq * 1.7 - progress * 11.0) * 0.25;
    float wave = primary + secondary;

    // Gentle global amplitude breathing — slow noise that
    // strengthens the entire wave occasionally. Less sectorial
    // than before (smaller range: 0.8–1.15 instead of 0.65–1.25)
    // so the wave reads as continuous and fluid rather than
    // chopped up by patches.
    float2 ampInput = position * 0.0012
                    + float2(progress * 0.18, -progress * 0.12);
    float ampMod = mix(0.80, 1.15, valueNoise(ampInput));
    wave *= ampMod;

    return wave;
}

static half3 iridescentColor(float t) {
    t = fract(t);
    // De-whitened palette — replaced pure white with a very
    // pale cyan. Without this, wave peaks at the middle of
    // the palette cycle were rendering near-white, washing
    // out the underlying UI. Color still varies through the
    // cycle but stays in the blue family throughout.
    half3 colorA = half3(0.55, 0.78, 1.00); // light blue
    half3 colorB = half3(0.85, 0.95, 1.00); // very pale cyan
    half3 colorC = half3(0.65, 0.88, 1.00); // sky blue
    if (t < 0.5) {
        return mix(colorA, colorB, half(t / 0.5));
    } else {
        return mix(colorB, colorC, half((t - 0.5) / 0.5));
    }
}

/// More saturated cyan/teal palette specifically for the
/// criss-cross streaks. The soft iridescent palette above
/// reads as near-white on light backgrounds; the streaks need
/// punchier color to be visible as distinct light particles.
static half3 streakColor(float t) {
    t = fract(t);
    half3 brightCyan = half3(0.30, 0.90, 1.00);
    half3 lightCyan  = half3(0.70, 1.00, 1.00);
    half3 sky        = half3(0.55, 0.88, 1.00);
    half3 teal       = half3(0.40, 0.95, 0.95);
    if (t < 0.33) {
        return mix(brightCyan, lightCyan, half(t / 0.33));
    } else if (t < 0.66) {
        return mix(lightCyan, sky, half((t - 0.33) / 0.33));
    } else {
        return mix(sky, teal, half((t - 0.66) / 0.34));
    }
}

// MARK: - Distortion shader (layerEffect on the snapshot Image)

/// Distorts a static snapshot of the UI captured at tap time.
/// Used via `.layerEffect` on a SwiftUI `Image(uiImage:)` —
/// because the image is just a bitmap, SwiftUI CAN flatten it
/// (unlike the live view tree with UIViewRepresentables, which
/// is why we're snapshotting in the first place).
///
/// Vertical-only sine displacement, same math as the AE comp:
/// Use For Vertical Displacement: Red, Max Vertical ≈ 2.8% of
/// view height.
[[ stitchable ]] half4 vibeWaveDistort(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float2 tapPoint,
    float progress,
    float intensity
) {
    float2 toFragment = position - tapPoint;
    float dist = length(toFragment);

    // Smooth bias that falls to ~zero just below the tap
    // point. Replaces the previous (0.3 → 1.0) bias paired
    // with a sign-flip at the tap line, which created a
    // visible hard seam where displacement direction reversed.
    // Now: full amplitude above the tap, smoothly fading to
    // zero ~15% below the tap, no sign flip — every pixel
    // displaces in the same direction so there's no
    // discontinuity.
    float yFromTap = toFragment.y / size.y;
    float upwardBias = 1.0 - smoothstep(-0.05, 0.15, yFromTap);

    float waveRadius = progress * size.y * 1.4;
    float bandPosition = waveRadius - dist;
    // WIDER band with soft sqrt falloff — distortion builds up
    // progressively over a larger area instead of passing as
    // a tight pulse. Affects ~55% of view height at peak.
    float bandWidth = size.y * 0.55;
    float bandFalloff = smoothstep(0.0, bandWidth * 0.25, bandPosition)
                     * (1.0 - smoothstep(bandWidth * 0.50, bandWidth, bandPosition));
    bandFalloff = sqrt(bandFalloff);

    float lifetime = sin(progress * 3.14159);
    float amp = lifetime * intensity * upwardBias * bandFalloff;

    // Fast path: outside the wave band (or below the tap, or at
    // the burst's endpoints) the displacement rounds to zero —
    // the pixel samples itself. Skip the 3 noise reads + trig of
    // fluidRingWave entirely. Max skipped offset at this
    // threshold is ~0.06pt: an order of magnitude under a pixel.
    if (amp <= 0.0015) {
        half4 passthrough = layer.sample(position);
        return half4(passthrough.rgb, 1.0h);
    }

    float rings = fluidRingWave(position, dist, progress, size);

    // Subtle displacement — ~2% of view height. Single sign;
    // all pixels shift in the same direction, eliminating the
    // seam at the tap line.
    float verticalOffset = rings * amp * size.y * 0.020;

    float2 samplePos = position - float2(0.0, verticalOffset);
    samplePos = clamp(samplePos, float2(0.0), size);
    half4 sampled = layer.sample(samplePos);

    // Force opaque — the snapshot is fully opaque, but the
    // shader-output alpha gets multiplied by SwiftUI's
    // animation, so we keep it at 1 explicitly.
    return half4(sampled.rgb, 1.0h);
}

// MARK: - Overlay shader (colorEffect)

/// Renders the vibe wave as a STANDALONE overlay layer — no
/// sampling of underlying UI. Avoids the SwiftUI flattening
/// limitation that breaks on UIViewRepresentable wrappers
/// (LightBlurView, LottieAnimationView, etc).
///
/// The shader paints translucent iridescent rings emanating
/// from `tapPoint`. Composited above the live UI via SwiftUI's
/// alpha blending — the underlying app keeps animating
/// independently, the wave just floats over it.
///
/// `currentColor` is ignored (the layer starts as Color.clear);
/// the shader determines its own per-pixel color + alpha.
[[ stitchable ]] half4 vibeWaveOverlay(
    float2 position,
    half4 currentColor,
    float2 size,
    float2 tapPoint,
    float progress,
    float intensity
) {
    (void)currentColor;

    float2 toFragment = position - tapPoint;
    float dist = length(toFragment);

    // Upward bias — waves push mostly above the tap point.
    float upMix = smoothstep(-size.y * 0.5, 0.0, -toFragment.y);
    float upwardBias = mix(0.25, 1.0, upMix);

    // Expanding wave radius.
    float waveRadius = progress * size.y * 1.4;
    float bandPosition = waveRadius - dist;

    // WIDER, more progressively-falling band so the wave
    // colors gradient in/out over a larger area. sqrt curve
    // gives fatter middle + softer tails than linear.
    float bandWidth = size.y * 0.55;
    float bandFalloff = smoothstep(0.0, bandWidth * 0.25, bandPosition)
                     * (1.0 - smoothstep(bandWidth * 0.50, bandWidth, bandPosition));
    bandFalloff = sqrt(bandFalloff);

    // Lifetime envelope.
    float lifetime = sin(progress * 3.14159);

    // Fast path: outside the band the amplitude gate zeroes both
    // ring and halo alphas — the pixel is transparent no matter
    // what the noise says. Bail before the 4 noise reads. The
    // cut only drops output alphas below ~2/255 at the band's
    // outermost smoothstep tail, which is invisible.
    if (lifetime * upwardBias * bandFalloff <= 0.001) {
        return half4(0.0h);
    }

    // Turbulent modulation.
    float turb = valueNoise(position * 0.006 + progress * 1.2);

    // Fluid water-ripple wave (multi-octave + non-circular).
    float rings = fluidRingWave(position, dist, progress, size);

    // Composite amplitude.
    float amp = lifetime * intensity * upwardBias * bandFalloff
              * (0.5 + turb * 0.8);

    // Softer peaks (exponent 2.0 vs 2.5) — wider glowy ring
    // crests rather than sharp lines, so the color reads as a
    // diffuse glow rather than a hard stripe.
    float ringPeak = pow(max(0.0, rings), 2.0);

    // Iridescent color.
    float phase = dist / size.y * 1.2 + progress * 0.4;
    half3 irid = iridescentColor(phase);

    // Ring + halo alphas tuned to keep the wave visible without
    // washing out the UI. Boosted back up after the de-whitened
    // palette change made the lower values read as nearly
    // invisible — the palette change alone was enough to prevent
    // the wash-out, so we don't also need depressed alphas.
    float ringAlpha = ringPeak * amp * 0.95;
    float haloAlpha = bandFalloff * amp * 0.22;
    float pixelAlpha = clamp(ringAlpha + haloAlpha, 0.0, 1.0);

    // Pre-multiplied alpha output (SwiftUI expects this for
    // colorEffect: RGB scaled by alpha).
    half3 outRGB = irid * half(pixelAlpha);
    return half4(outRGB, half(pixelAlpha));
}

// MARK: - Combined glow shader (colorEffect)

/// Merged residue particles + criss-cross streaks. Both layers
/// were previously rendered via separate `.colorEffect` passes
/// with `.plusLighter` (additive) blend — same blend mode and
/// same target (above the snapshot, below nothing), so we can
/// sum them inside ONE fragment shader and save a full GPU
/// dispatch + framebuffer pass per frame.
///
/// Output is premultiplied RGBA; blend mode at the SwiftUI
/// site remains `.plusLighter`, so the additive composition
/// onto the snapshot is identical to running the two shaders
/// stacked.
///
/// Early-out: if BOTH the particle lifetime envelope AND the
/// wave-band gate are zero, skip all the noise math and return
/// transparent.
[[ stitchable ]] half4 vibeWaveGlow(
    float2 position,
    half4 currentColor,
    float2 size,
    float2 tapPoint,
    float progress,
    float intensity
) {
    (void)currentColor;

    float2 toFragment = position - tapPoint;
    float dist = length(toFragment);

    // Particle phase envelope (was in vibeWaveParticles).
    float particleLife = smoothstep(0.15, 0.35, progress)
                      * (1.0 - smoothstep(0.85, 1.0, progress));

    // Wave band gate (was in vibeWaveStreaks).
    float waveRadius = progress * size.y * 1.4;
    float bandPosition = waveRadius - dist;
    float bandWidth = size.y * 0.55;
    float bandFalloff = smoothstep(0.0, bandWidth * 0.25, bandPosition)
                     * (1.0 - smoothstep(bandWidth * 0.50, bandWidth, bandPosition));
    bandFalloff = sqrt(bandFalloff);

    // Hard bail when nothing contributes. Skips ~all noise calls
    // for pixels outside both regions (most of the screen during
    // the start + end of the burst).
    if (particleLife <= 0.001 && bandFalloff <= 0.001) {
        return half4(0.0h);
    }

    half3 result = half3(0.0h);

    // ---- Residue particles (was vibeWaveParticles) ----
    if (particleLife > 0.001) {
        for (int i = 0; i < 2; i++) {
            float side = (i == 0) ? -1.0 : 1.0;
            float xOffset = side * size.x * 0.08;
            float blobX = tapPoint.x + xOffset;

            float travel = progress * (1.2 - float(i) * 0.15);
            float blobY = tapPoint.y - travel * size.y;

            float2 blobCenter = float2(blobX, blobY);

            float2 noiseInput = position * 0.0035
                              + float2(float(i) * 100.0, progress * 1.2);
            float noiseVal = valueNoise(noiseInput);
            float swayX = (noiseVal - 0.5) * size.x * 0.55;

            float2 distorted = position - float2(swayX, 0.0);
            float blobDist = length(distorted - blobCenter);

            float radius = size.x * 0.55;
            float falloff = exp(-pow(blobDist / radius, 1.5));

            float phase = float(i) * 0.35 + progress * 0.5
                        + noiseVal * 0.2;
            half3 blobColor = iridescentColor(phase);

            result += blobColor * half(falloff * particleLife * 0.22);
        }
        result *= half(intensity);
    }

    // ---- Criss-cross streaks (was vibeWaveStreaks) ----
    if (bandFalloff > 0.001) {
        // Strong upward bias — reference shows streaks
        // concentrated above the burst, not all around it.
        float upMix = smoothstep(-size.y * 0.7, size.y * 0.1, -toFragment.y);
        float upwardBias = mix(0.05, 1.0, upMix);

        // PRIMARY streak pass — original frequencies (0.006/0.022),
        // wider streaks. Active for most of the burst.
        float2 hCart = position * float2(0.006, 0.022);
        hCart.y -= progress * 0.7;
        float hN1 = valueNoise(hCart);
        float hN2 = valueNoise(hCart * 2.1 + 13.4) * 0.5;
        float hStreaks = hN1 * 0.7 + hN2 * 0.3;

        // Vertical streak field (mirror anisotropy).
        float2 vCart = position * float2(0.022, 0.006);
        vCart.x += progress * 0.6;
        float vN1 = valueNoise(vCart);
        float vN2 = valueNoise(vCart * 2.1 + 7.9) * 0.5;
        float vStreaks = vN1 * 0.7 + vN2 * 0.3;

        float streakField = max(hStreaks, vStreaks);

        // Gap modulator + sparsity (original values).
        float2 gapCart = position * float2(0.015, 0.015)
                      + float2(progress * 0.9, progress * 0.7);
        float gapMask = smoothstep(0.28, 0.78, valueNoise(gapCart));

        float combined = streakField * gapMask;

        float2 sparseInput = position * 0.0022
                           + float2(progress * 0.10, -progress * 0.08);
        float sparsity = mix(0.45, 1.0, smoothstep(0.25, 0.85, valueNoise(sparseInput)));

        // Original core + halo (medium-thick streaks).
        float core = smoothstep(0.18, 0.55, combined);
        float halo = smoothstep(0.05, 0.45, combined) * 0.7;
        float streak = core + halo;

        // Primary life envelope: peaks mid-wave, fades by end.
        float life = smoothstep(0.05, 0.25, progress)
                  * (1.0 - smoothstep(0.85, 1.0, progress));

        float phase = (position.y / size.y) * 0.5
                    + progress * 0.4
                    + streakField * 0.3;
        half3 color = streakColor(phase);

        float brightness = streak * bandFalloff * upwardBias
                         * sparsity * life * intensity * 0.85;
        brightness = clamp(brightness, 0.0, 0.80);

        result += color * half(brightness);
    }

    // ---- SECONDARY streak pass — TRAILS the primary in space.
    // Uses a slower-expanding band (radius 1.0 × size.y vs the
    // primary's 1.4 × size.y), so at any moment its annulus is
    // ~70% of the primary's radius — i.e., closer to the burst
    // origin. As the primary band sweeps outward, the secondary
    // band follows BEHIND it spatially.
    //
    // Lives in its own block (outside the primary's `bandFalloff
    // > 0.001` check) because the secondary band can be active
    // at pixel positions where the primary band has already
    // moved past — those are exactly the "trail" pixels.
    //
    // Gated by progress >= 0.45 so early frames skip the extra
    // noise reads. ~6 valueNoise calls per fragment for the
    // second half of the burst — well within GPU budget.
    if (progress >= 0.45) {
        // Secondary band — same shape as primary but slower
        // expansion, so it always trails behind in space.
        float waveRadius2 = progress * size.y * 1.0;
        float bandPosition2 = waveRadius2 - dist;
        float bandWidth2 = size.y * 0.50;
        float bandFalloff2 = smoothstep(0.0, bandWidth2 * 0.25, bandPosition2)
                         * (1.0 - smoothstep(bandWidth2 * 0.50, bandWidth2, bandPosition2));
        bandFalloff2 = sqrt(bandFalloff2);

        if (bandFalloff2 > 0.001) {
            // Upward bias (same shape as primary).
            float upMix2 = smoothstep(-size.y * 0.7, size.y * 0.1, -toFragment.y);
            float upwardBias2 = mix(0.05, 1.0, upMix2);

            // Bigger streak features (0.028 / 0.082, small-but-
            // visible patches). Time-shift drastically reduced
            // (0.5/0.45 → 0.12/0.10) — at high spatial frequencies
            // even small time shifts produce rapid noise-field
            // changes that read as flicker. The spatial trail
            // (band sweeping outward) already provides motion;
            // the noise-field motion was redundant and jittery.
            //
            // Also dropped the secondary noise octave (hN2, vN2)
            // — at this frequency the secondary octave was
            // contributing more flicker than detail, and the
            // blurry halo blends out individual feature details
            // anyway. Saves ~2 noise calls per fragment in the
            // late half of the burst.
            float2 hCart2 = position * float2(0.028, 0.082);
            hCart2.y -= progress * 0.12;
            float hStreaks2 = valueNoise(hCart2);

            float2 vCart2 = position * float2(0.082, 0.028);
            vCart2.x += progress * 0.10;
            float vStreaks2 = valueNoise(vCart2);

            float streakField2 = max(hStreaks2, vStreaks2);

            // Even sparser gap — only the top ~15% of noise values
            // pass. Time-shift cut from (1.1, 0.85) to (0.25, 0.20)
            // so the gap pattern barely drifts during the burst —
            // each cluster sits in place rather than flickering on
            // and off as the noise field shifts.
            float2 gapCart2 = position * float2(0.020, 0.020)
                          + float2(progress * 0.25, progress * 0.20);
            float gapMask2 = smoothstep(0.78, 0.97, valueNoise(gapCart2));

            // Much deeper sparsity floor (0.25 → 0.08) so quiet
            // regions go almost fully dark — large stretches of
            // empty trail with occasional bright cluster pockets.
            float2 sparseInput2 = position * 0.0030
                               + float2(progress * 0.15, -progress * 0.10);
            float sparsity2 = mix(0.08, 1.0, smoothstep(0.30, 0.85, valueNoise(sparseInput2)));

            float combined2 = streakField2 * gapMask2;

            // Maximally blurry — almost no core, just a wide soft
            // glow. Each "streak" is now essentially a diffuse
            // halo patch with no defined center, so the trail
            // reads as soft luminous fog rather than discrete
            // shapes.
            float core2 = smoothstep(0.52, 0.70, combined2) * 0.10;
            float halo2 = smoothstep(0.00, 0.72, combined2) * 1.20;
            float streak2 = core2 + halo2;

            // Life envelope — fade window much wider (0.72 → 0.95,
            // 23% = ~240ms at the 1.05s wave lifetime) so the
            // secondary smoothly transitions to invisible.
            // Crucially, the fade ENDS at progress 0.95, not 1.0,
            // so there's a 5% "fully invisible" buffer before the
            // shader actually clears at 1.0 — eliminates any
            // perceived cut at the cleanup moment.
            float life2 = smoothstep(0.45, 0.65, progress)
                       * (1.0 - smoothstep(0.72, 0.95, progress));

            float phase2 = (position.y / size.y) * 0.7
                         + progress * 0.6
                         + streakField2 * 0.4;
            half3 color2 = streakColor(phase2);

            float brightness2 = streak2 * bandFalloff2 * upwardBias2
                              * sparsity2 * life2 * intensity * 0.65;
            brightness2 = clamp(brightness2, 0.0, 0.65);

            result += color2 * half(brightness2);
        }
    }

    // Premultiplied output. Alpha from max channel so the
    // additive `.plusLighter` blend at the SwiftUI site
    // ignores dark areas correctly.
    float lum = float(max(max(result.r, result.g), result.b));
    half alpha = half(clamp(lum, 0.0, 1.0));
    return half4(result, alpha);
}

// Holographic card overlay — procedural Metal shader for the iridescent
// edge shimmer on Pro feed cards. The shader runs as a `.colorEffect`
// on a white-filled rounded rectangle, then `.blendMode(.multiply)`
// composites the result over the card's frosted backdrop.
//
// Output shape:
//   - Interior pixels return exactly 1.0, so multiply blend leaves the
//     underlying appCard frosted backdrop unchanged → pro card interior
//     reads identical to non-pro cards in the feed.
//   - Edge pixels mix in an iridescent palette (3 sin waves at 120°
//     phase) modulated by a turbulent envelope, so the perimeter shows
//     chromatic shimmer.
//
// Tilt response: roll + pitch shift the color-sample UV with a depth-
// aware factor (edges parallax more than center) for a Pokemon-style
// holo feel. A fresnel-like rim term boosts mix intensity at the
// perimeter — natural depth cue.
//
// Usage from SwiftUI:
//
//   RoundedRectangle(cornerRadius: r, style: .continuous)
//       .fill(.white)
//       .colorEffect(
//           ShaderLibrary.holoCard(
//               .float(time),
//               .float(canvasW),
//               .float(canvasH),
//               .float(roll),       // -1...1 from HoloMotionTracker
//               .float(pitch),      // -1...1 from HoloMotionTracker
//               .float(cornerRadius)
//           )
//       )
//       .blendMode(.multiply)

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float TWO_PI = 6.28318530718;

// Two-octave smooth pseudo-noise. Stand-in for AE Turbulent Displace
// at low resolution (Size 187 in AE → low frequency / large blobs).
// Returns a 2D vector so we can drive both palette phase and the
// "effect" layer's displacement from the same field.
static float2 turbulent(float2 uv, float t) {
    float2 a = float2(
        sin(uv.x * 5.3 + t * 0.6) * cos(uv.y * 4.1 + t * 0.45),
        cos(uv.x * 3.7 + t * 0.55) * sin(uv.y * 6.3 + t * 0.65)
    );
    float2 b = float2(
        sin(uv.x * 9.0 + t * 1.1) * cos(uv.y * 8.0 + t * 0.95),
        cos(uv.x * 7.5 + t * 1.25) * sin(uv.y * 10.2 + t * 0.85)
    );
    return a * 0.65 + b * 0.35;
}

// Cheap hash for the 5% noise effect on the "effect" layer.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Signed distance to a rounded rectangle centered at origin. Negative
// inside, positive outside. `b` is the half-size; `r` is the corner
// radius. Used to compute the Refraction inner-glow mask.
static float sdRoundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Iridescent palette — 3 sin waves at 120° phase offsets, cycling
// through pink → magenta → blue → cyan → green. Channel range
// [0.80, 1.00] (~20% swing) — moderate saturation; the chromatic
// reaches deep into the card so it doesn't need to scream at peak.
static half3 iridescent(float t) {
    half3 c;
    c.r = half(0.90 + 0.10 * sin(t * TWO_PI + 0.0));
    c.g = half(0.90 + 0.10 * sin(t * TWO_PI + TWO_PI / 3.0));
    c.b = half(0.90 + 0.10 * sin(t * TWO_PI + 2.0 * TWO_PI / 3.0));
    return c;
}

[[ stitchable ]] half4 holoCard(
    float2 position,
    half4 source,
    float time,
    float canvasW,
    float canvasH,
    float roll,
    float pitch,
    float cornerRadius
) {
    if (source.a < 0.001) return source;

    float2 centered = position - float2(canvasW * 0.5, canvasH * 0.5);
    float2 cardHalf = float2(canvasW * 0.5, canvasH * 0.5);
    float2 uv = position / float2(canvasW, canvasH);

    // === Single turbulence + modulator ================================
    // turbLow drives both the SDF boundary warp (so the chromatic edge
    // band has irregular fat/thin spots) and the color-sample warp
    // (so the iridescent phase smears along the edge in a way that's
    // consistent with the boundary deformation).
    float2 turbLow = turbulent(uv * 1.6, time * 0.3);
    float modulatorRaw = turbulent(uv * 2.4, time * 0.18).x;

    // === SDF-based edge band ==========================================
    // innerSize is large (22% of minDim) so the chromatic gradient
    // reaches DEEP into the card — colors don't stop at a perimeter
    // band, they fade gradually all the way toward the middle.
    float innerSize = 0.22 * min(canvasW, canvasH);
    float boundaryWarp = innerSize * 0.30;
    float2 sdfQuery = centered + turbLow * boundaryWarp;
    float sdf = sdRoundRect(sdfQuery, cardHalf, cornerRadius);
    float edgeMask = clamp(1.0 + sdf / innerSize, 0.0, 1.0);
    edgeMask = edgeMask * edgeMask * (3.0 - 2.0 * edgeMask);

    // Soft brightness envelope — gentler variation so the chromatic
    // reads as a continuous gradient across the card rather than
    // patches. Hotspot reuses modulatorRaw (instead of running a
    // second turbulent() call) — saves 8 sin/cos ops per pixel per
    // frame with no perceptible visual change.
    float edgeMod = 0.50 + 0.50 * (0.5 + 0.5 * modulatorRaw);
    float hotspot = max(0.0, modulatorRaw - 0.2) * 1.3;
    float chromaticMask = edgeMask * edgeMod * (1.0 + hotspot * 0.3);

    // === Iridescent palette — depth-aware parallax ==================
    // Two things sell dimensionality through the chromatic itself,
    // not strokes:
    //
    //   1. tiltMag varies with distance from center. Pixels at the
    //      edges parallax-shift MORE than pixels at the center, so as
    //      you tilt the device the rainbow "scrolls faster" near the
    //      perimeter — the visual signature of a curved surface
    //      (Pokemon TCG Live's holo trick).
    //
    //   2. fresnel-like rim. Chromatic intensity is boosted at the
    //      perimeter where a real curved/glossy surface would catch
    //      grazing light. Reads as depth via brightness gradient.
    float2 fromCenter = uv - 0.5;
    float r = length(fromCenter);                       // 0 at center, ~0.7 at corners
    float depthFactor = 0.25 + r * 1.2;                 // ~0.25 center, ~1.1 corners
    float2 tiltOffset = float2(-roll, -pitch) * depthFactor;
    float2 colorSampleUV = uv + tiltOffset + turbLow * 0.45 * edgeMask;
    float colorPhase =
          colorSampleUV.x * 2.0
        + colorSampleUV.y * 2.8
        + time * 0.08;
    half3 chromatic = iridescent(colorPhase);

    // Fresnel rim — strengthen the chromatic mix at the edges so the
    // perimeter reads as the "lit" curve of the card surface. Mix
    // factor is kept low (0.30 base) for a subtle shine — the
    // iridescent palette itself still hits full saturation when it
    // appears, but it's mixed in lightly so the overall effect feels
    // like a faint sheen rather than a dominant color wash.
    float fresnel = clamp(r * 2.0, 0.0, 1.0);
    fresnel = fresnel * fresnel;
    float chromaticGain = 0.30 * (1.0 + fresnel * 0.5);
    half3 colorsLayer = mix(half3(1.0), chromatic, half(chromaticMask) * half(chromaticGain));

    // === Card tint ====================================================
    // Match the cool off-white the rest of the feed's cards land on —
    // groupedBackground ≈ (0.926, 0.941, 0.965) blurred through the
    // .systemThinMaterialLight + 48% white cardFill. Driving the
    // effect layer + halo through this tint instead of pure white
    // keeps the pro card's interior consistent with non-pro cards.
    constexpr half3 cardTint = half3(0.926, 0.941, 0.965);

    // === Effect layer ================================================
    // Interior is EXACTLY 1.0 (no wave, no noise) so the multiply
    // blend is a true identity on the appCard frosted backdrop —
    // pro card interior color matches non-pro cards bit for bit.
    // Only the edge band blends toward cardTint, which gives the
    // chromatic mix something to read against.
    half3 effectLayer = half3(1.0);
    effectLayer = mix(effectLayer, cardTint * half(0.93), half(edgeMask) * 0.30);

    // === Halo removed =================================================
    // No center bloom — the bright "white reflection" was making the
    // pro card read as whiter than the non-pro cards. Without it, the
    // shader output stays at near-1.0 in the interior so the multiply
    // blend leaves the appCard frosted base unchanged. Pro card
    // interior color = non-pro card interior color exactly.
    half halo = half(0.0);

    // === Compose ======================================================
    // Halo is plain white so the interior addition stays at 1.0 (and
    // the multiply blend leaves the appCard base unchanged). cardTint
    // is no longer in the halo path because the interior must match
    // non-pro cards exactly; tinted halo would shift the interior off
    // from the rest of the feed.
    half3 composite = effectLayer * colorsLayer;
    composite = composite + half3(halo) * (1.0 - half(edgeMask) * 0.5);
    composite = clamp(composite, half3(0.0), half3(1.0));

    return half4(composite, source.a);
}

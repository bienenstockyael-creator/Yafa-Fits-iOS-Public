// Colorama gradient generator — generates the AE-style colorama gradient
// procedurally per pixel, with turbulent displace baked in. Used as a
// `.colorEffect` on a Color.black source view; the source's own colour
// is ignored (we synthesize the gradient based on `position` + uniforms).
// Result is then masked by the letter shape on the SwiftUI side.
//
// Pipeline reproduced from the AE recipe:
//   1. Vertical white → black gradient (built from `position.y / canvasH`)
//   2. Colorama hue mapping → custom blue/grey palette (4-stop ramp)
//   3. Animated input phase → `time` shifts the white peak vertically
//   4. Turbulent displace → low-frequency sin/cos perturbs `y_norm` so
//      the colour bands wave organically instead of running flat across
//   5. Time displacement (faked) → per-column phase offset based on
//      horizontal position, so different columns show the gradient at
//      slightly different "moments" of the animation cycle. AE's true
//      time-displacement needs a frame buffer; this is a static stand-in
//      that produces a similar staggered-edge feel.
//
// Usage from SwiftUI:
//
//   Color.black
//       .colorEffect(
//           ShaderLibrary.coloramaGradient(
//               .float(time),
//               .float(canvasW),
//               .float(canvasH)
//           )
//       )

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float CYCLE_SECONDS = 6.0;
constant float TWO_PI = 6.28318530718;

// How many full palette cycles fit inside one canvas height. >1 means
// multiple white/blue bands stack vertically within the visible card,
// so when the text only spans part of the canvas (short month
// abbreviations like "feb"), it still sees the full blue↔white range
// instead of just the centre slice.
constant float VERTICAL_CYCLES = 2.4;

// Layered sin/cos noise that approximates AE's Turbulent Displace.
// `p` is `phase * TWO_PI` — i.e. it sweeps cleanly from 0 to 2π every
// CYCLE_SECONDS and back to 0. Each sin/cos uses an integer multiplier
// of `p` so all terms wrap to identical values when phase wraps,
// producing a perfectly seamless temporal loop.
static float turbulent(float2 uv, float p) {
    float a = sin(uv.x * 7.5 + p * 1.0) * cos(uv.y * 5.5 + p * 1.0);
    float b = sin(uv.x * 13.0 + p * 2.0) * cos(uv.y * 11.0 + p * 1.0);
    return a * 0.6 + b * 0.4;
}

[[ stitchable ]] half4 coloramaGradient(
    float2 position,
    half4 source,
    float time,
    float canvasW,
    float canvasH
) {
    if (source.a < 0.001) return source;

    float y_norm = position.y / canvasH;
    float x_norm = position.x / canvasW;

    float phase = fract(time / CYCLE_SECONDS);
    float p = phase * TWO_PI;
    float wobble = turbulent(float2(x_norm, y_norm), p) * 0.40;
    float column_phase_offset =
        sin(x_norm * 14.0 + p * 1.0) * 0.18 +
        cos(x_norm * 9.0  - p * 1.0) * 0.13;
    float gradient_t = fract(y_norm * VERTICAL_CYCLES + wobble + phase + column_phase_offset);
    float dist = abs(gradient_t - 0.5) * 2.0;

    half3 white      = half3(1.00, 1.00, 1.00);
    half3 lightBlue  = half3(0.55, 0.70, 1.00);
    half3 brightBlue = half3(0.18, 0.30, 1.00);
    half3 darkBlue   = half3(0.05, 0.10, 0.55);

    half3 mapped;
    if (dist < 0.30) {
        mapped = mix(white, lightBlue, half(dist / 0.30));
    } else if (dist < 0.65) {
        mapped = mix(lightBlue, brightBlue, half((dist - 0.30) / 0.35));
    } else {
        mapped = mix(brightBlue, darkBlue, half((dist - 0.65) / 0.35));
    }
    return half4(mapped, source.a);
}

// AE Displacement Map equivalent. Applied as `.layerEffect` to a
// slightly blurred copy of the letter shapes — the layer's alpha
// (soft at edges, full inside) drives a vertical displacement of the
// gradient sample. Inside-letter pixels pull the gradient down,
// outside-letter pixels pull it up, and the blurred edge transition
// produces the wavy "stretched into the letter shape" look.
// =============================================================
// Per-variant entry points
// =============================================================
// SwiftUI's `Shader.Argument` bridge for stitchable `.layerEffect`
// shaders rejects `float3`, `float4`, AND `.color(_)` uniforms — they
// fail with "unsupported struct type" at the Metal stitching layer.
// The only reliable way to ship per-variant colour palettes is to
// hardcode them inside one shader function per variant.
//
// Adding a new colorama palette = ~10 lines here:
//   1. Copy one of the entry points below
//   2. Rename it (e.g. `coloramaDisplacedFoo`)
//   3. Swap its 4 `half3(...)` values for the new palette
//   4. Add a matching `case N: ShaderLibrary.coloramaDisplacedFoo(...)`
//      branch in `coloramaDisplacedShader(...)` in
//      `ShareCardComposer.swift`
//
// Internal helper that does all the displacement + gradient math.
// Each entry point below just supplies its 4-stop palette and calls
// this. (Internal Metal funcs are NOT stitchable, so they can take
// whatever args we want — including the 4 `half3` palette stops.)
static half4 coloramaDisplaceCore(
    float2 position,
    half a,
    float time,
    float canvasW,
    float canvasH,
    half3 c0, half3 c1, half3 c2, half3 c3
) {
    if (float(a) < 0.001) return half4(0);

    float x_norm = position.x / canvasW;
    float y_norm = position.y / canvasH;

    float disp = (float(a) - 0.5) * 2.0;
    float disp_amount = 0.30;
    y_norm += disp * disp_amount;

    float phase = fract(time / CYCLE_SECONDS);
    float p = phase * TWO_PI;
    float wobble = turbulent(float2(x_norm, y_norm), p) * 0.40;
    float column_phase_offset =
        sin(x_norm * 14.0 + p * 1.0) * 0.18 +
        cos(x_norm * 9.0  - p * 1.0) * 0.13;
    float gradient_t = fract(y_norm * VERTICAL_CYCLES + wobble + phase + column_phase_offset);
    float dist = abs(gradient_t - 0.5) * 2.0;

    half3 mapped;
    if (dist < 0.30) {
        mapped = mix(c0, c1, half(dist / 0.30));
    } else if (dist < 0.65) {
        mapped = mix(c1, c2, half((dist - 0.30) / 0.35));
    } else {
        mapped = mix(c2, c3, half((dist - 0.65) / 0.35));
    }
    return half4(mapped * a, a);
}

// Default — original blue/grey palette.
[[ stitchable ]] half4 coloramaDisplacedDefault(
    float2 position,
    SwiftUI::Layer layer,
    float time,
    float canvasW,
    float canvasH
) {
    return coloramaDisplaceCore(
        position, layer.sample(position).a, time, canvasW, canvasH,
        half3(1.00, 1.00, 1.00),
        half3(0.55, 0.70, 1.00),
        half3(0.18, 0.30, 1.00),
        half3(0.05, 0.10, 0.55)
    );
}

// Pink — white → light pink → hot pink → burgundy.
[[ stitchable ]] half4 coloramaDisplacedPink(
    float2 position,
    SwiftUI::Layer layer,
    float time,
    float canvasW,
    float canvasH
) {
    return coloramaDisplaceCore(
        position, layer.sample(position).a, time, canvasW, canvasH,
        half3(1.000, 1.000, 1.000),
        half3(0.961, 0.863, 0.898), // #F5DCE5 light pink
        half3(0.910, 0.243, 0.486), // #E83E7C hot pink
        half3(0.431, 0.067, 0.220)  // #6E1138 burgundy
    );
}

// Sage — white → light blue → sage → forest green.
[[ stitchable ]] half4 coloramaDisplacedSage(
    float2 position,
    SwiftUI::Layer layer,
    float time,
    float canvasW,
    float canvasH
) {
    return coloramaDisplaceCore(
        position, layer.sample(position).a, time, canvasW, canvasH,
        half3(1.000, 1.000, 1.000),
        half3(0.722, 0.863, 0.961), // #B8DCF5 light blue
        half3(0.510, 0.776, 0.431), // #82C66E sage
        half3(0.114, 0.239, 0.102)  // #1D3D1A forest
    );
}

// Sunset — white → warm orange → mid blue → deep navy.
[[ stitchable ]] half4 coloramaDisplacedSunset(
    float2 position,
    SwiftUI::Layer layer,
    float time,
    float canvasW,
    float canvasH
) {
    return coloramaDisplaceCore(
        position, layer.sample(position).a, time, canvasW, canvasH,
        half3(1.000, 1.000, 1.000),
        half3(0.961, 0.737, 0.451), // #F5BC73
        half3(0.282, 0.471, 0.722), // #4878B8
        half3(0.055, 0.133, 0.251)  // #0E2240
    );
}

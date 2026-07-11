// Live chrome reflection for the "add me on yafa" wordmark on the share
// card. Runs as a `.colorEffect` over a baked NORMAL MAP of the letterforms
// (share-chrome-normal.png: rgb = surface normal *0.5+0.5, a = coverage).
//
// Why a shader and not a baked image: chrome reads as chrome because it is a
// MIRROR whose reflection MOVES as you tilt it. A frozen baked image can't do
// that — it looks like a flat sticker. Here, each pixel reflects a procedural
// chrome environment (bright sky -> sharp dark horizon -> ground, plus a hot
// spot), and the reflection is shifted by the device's roll/pitch every frame,
// so the metal genuinely catches and sweeps light as the phone turns.
//
// Usage from SwiftUI:
//
//   Image(uiImage: normalMap)
//       .resizable().aspectRatio(contentMode: .fit)
//       .colorEffect(ShaderLibrary.chromeReflect(
//           .float(roll), .float(pitch), .float(time)))   // roll/pitch -1...1

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Vertical chrome environment: what the metal reflects when its reflected
// ray points at vertical level `y` (roughly -1 down ... +1 up). The signature
// of chrome is the SHARP near-black horizon band splitting a bright cool sky
// from a darker warmer ground.
static float3 chromeEnv(float y, float x) {
    // BRIGHT-SILVER chrome gradient: real chrome is mostly light — thin,
    // SHARP dark lines and hot glints on a silver body, never big dark
    // masses (wide darks read as gunmetal/tarnish, not mirror polish).
    // Cool silver-blue sky above, a crisp steel horizon LINE, warm champagne
    // bounce below: the cool/warm split still makes a tube sweep
    // blue-silver -> gold-silver as you tilt.
    const float3 skyTop      = float3(0.97, 0.99, 1.00); // high sky, near white
    const float3 skyBlue     = float3(0.62, 0.74, 0.94); // silver-blue, desaturated
    const float3 horizonD    = float3(0.30, 0.34, 0.44); // steel line, NOT near-black
    const float3 groundWarm  = float3(0.72, 0.66, 0.56); // light warm under horizon
    const float3 groundBright= float3(1.00, 0.94, 0.82); // bright champagne bounce

    float3 sky    = mix(skyBlue, skyTop, smoothstep(0.06, 0.6, y));
    float3 ground = mix(groundWarm, groundBright, smoothstep(-0.1, -0.6, y));
    float3 env    = y >= 0.0 ? sky : ground;

    // THIN crisp horizon line straddling y = 0 — the signature dark stripe
    // of chrome, kept narrow so it draws a line across the letters instead
    // of flooding them dark.
    float band = smoothstep(0.055, 0.0, abs(y));
    env = mix(env, horizonD, band);

    // Faint vertical streaks (distant reflected verticals) for busy realism.
    float streak = 0.5 + 0.5 * sin(x * 9.0);
    env *= (0.96 + 0.04 * streak);
    return env;
}

[[ stitchable ]] half4 chromeReflect(
    float2 position,
    half4 color,
    float roll,
    float pitch,
    float time
) {
    half a = color.a;
    if (a < 0.003h) return half4(0.0h, 0.0h, 0.0h, 0.0h);

    // Un-premultiply, then decode the surface normal.
    float3 enc = float3(color.rgb / a);
    float3 N = normalize(enc * 2.0 - 1.0);

    // Reflect the head-on view direction (0,0,1) about the normal.
    float ndv = N.z;
    float2 R = float2(2.0 * ndv * N.x, 2.0 * ndv * N.y);

    // Tilt shifts the reflection so it SWEEPS as the phone turns — the core
    // chrome illusion. roll/pitch arrive BASELINE-CALIBRATED (delta from the
    // attitude at card-open, ±1 over ~a wrist turn), so the reflection is
    // guaranteed centered on the letters at rest for any hold angle. That's
    // what buys the high gain here: a small deliberate tilt drives the
    // horizon clear across the letterforms — the old absolute-tilt feed had
    // to run timid gain or the hold angle shoved everything into the white
    // sky. A tiny idle drift keeps it alive when the phone is still.
    float rx = R.x + roll * 1.60 + sin(time * 0.5) * 0.04;
    float ry = R.y + pitch * 1.60 + cos(time * 0.4) * 0.04;

    float3 env = chromeEnv(clamp(ry, -1.5, 1.5), rx);

    // Moving hot spot (sparkle) — tight so it glints rather than washing
    // white. Counter-travels against the tilt (negative gain) so it sweeps
    // ACROSS the letters as the environment slides the other way — the
    // two opposing motions are what sell the mirror.
    float2 sun = float2(0.20 - roll * 0.9, 0.40 - pitch * 0.9);
    float hot = smoothstep(0.22, 0.0, distance(float2(rx, ry), sun));
    env += float3(hot) * 1.0;

    // Crisp contour: a THIN steel edge where the surface grazes away from
    // the viewer — enough to draw the letterform against the white card,
    // shallow enough that the face of the metal stays bright silver.
    float rim = smoothstep(0.20, 0.46, N.z);            // 0 at edge -> 1 facing us
    env *= mix(0.52, 1.0, rim);                         // pencil edge, not shadow

    // Grazing-angle sparkle: real chrome flares white at its edges when it
    // catches the sky (Fresnel). Only where the reflected ray points up, so
    // the bottom edge keeps its dark line and the top edge ignites.
    float fresnel = 1.0 - rim;
    env += float3(0.9, 0.95, 1.0) * fresnel * smoothstep(0.05, 0.7, ry) * 0.55;

    // S-curve for metallic punch.
    env = (env - 0.5) * 1.30 + 0.5;
    // High floor: no tilt angle ever drives the chrome past dark steel —
    // dark masses read as tarnish, and thin lines don't need help.
    env = max(env, float3(0.30));
    env = clamp(env, 0.0, 1.0);

    return half4(half3(env), a);
}

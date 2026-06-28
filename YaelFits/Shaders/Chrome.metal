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
    // MID-TONE chrome gradient: steel-blue sky on top, a WIDE near-black
    // horizon band, then a warm tan floor bounce below. Kept mostly darker
    // than the white share card (with only small bright glints added later)
    // so the metal stays visible instead of washing out — and the cool/warm
    // split makes a tube sweep blue-silver -> gold-silver as you tilt.
    const float3 skyTop      = float3(0.95, 0.98, 1.00); // high sky, bright
    const float3 skyBlue     = float3(0.30, 0.50, 0.85); // steel blue
    const float3 horizonD    = float3(0.16, 0.20, 0.30); // horizon: dark but NOT black
    const float3 groundWarm  = float3(0.50, 0.44, 0.36); // mid warm under horizon
    const float3 groundBright= float3(1.00, 0.92, 0.78); // bright warm floor bounce

    float3 sky    = mix(skyBlue, skyTop, smoothstep(0.06, 0.6, y));
    float3 ground = mix(groundWarm, groundBright, smoothstep(-0.1, -0.6, y));
    float3 env    = y >= 0.0 ? sky : ground;

    // Crisp dark horizon band straddling y = 0 (gives each tube a dark
    // reflection core that reads even over a white background).
    float band = smoothstep(0.14, 0.0, abs(y));
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
    // chrome illusion. Gain is deliberately LOW (0.35): a phone is held
    // pitched toward the face, and a high gain would shove the whole
    // reflection up into the white sky at rest (the "it's just white" bug).
    // Low gain keeps the chrome centered on the letters at any hold angle,
    // with tilt nudging it for liveliness. A tiny idle drift keeps it alive.
    float rx = R.x + roll * 0.85 + sin(time * 0.5) * 0.03;
    float ry = R.y + pitch * 0.85 + cos(time * 0.4) * 0.03;

    float3 env = chromeEnv(clamp(ry, -1.5, 1.5), rx);

    // Moving hot spot (sparkle) — tight so it glints rather than washing white.
    float2 sun = float2(0.20 + roll * 0.7, 0.40 + pitch * 0.7);
    float hot = smoothstep(0.22, 0.0, distance(float2(rx, ry), sun));
    env += float3(hot) * 1.0;

    // Crisp dark contour: the grazing rim (normal facing away from viewer)
    // goes near-black so the metal pops against the light card.
    float rim = smoothstep(0.26, 0.58, N.z);            // 0 at edge -> 1 facing us
    env *= mix(0.30, 1.0, rim);                         // softer (not black) edges

    // S-curve for metallic punch.
    env = (env - 0.5) * 1.30 + 0.5;
    // Hard floor so no tilt angle ever drives the chrome near-black.
    env = max(env, float3(0.16));
    env = clamp(env, 0.0, 1.0);

    return half4(half3(env), a);
}

import SwiftUI

/// Full-screen overlay that paints the vibe wave effect on top
/// of the live UI. Two stacked components per burst:
///
///   1. A static `Image` snapshot of the UI taken at tap time,
///      with the `vibeWaveDistort` shader applied via
///      `.layerEffect` (the shader CAN sample an Image since
///      it's a bitmap — unlike the live view tree which has
///      UIViewRepresentables that break flattening).
///
///   2. A transparent `Rectangle` with the `vibeWaveOverlay`
///      shader applied via `.colorEffect`, drawing iridescent
///      rings ON TOP of the distorted snapshot.
///
/// The snapshot covers the live UI during the burst (the live
/// UI keeps updating beneath, the user just can't see it for
/// ~1.5s) and fades out near the end of the lifetime to
/// reveal the current live state.
///
/// `allowsHitTesting(false)` so the overlay never intercepts
/// taps — users can still interact with the live UI underneath.
struct VibesWaveOverlay: View {
    @Environment(VibesEffectHost.self) private var host

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let burst = host.waveShader {
                    // Cap at 60 Hz — on ProMotion devices the
                    // default `.animation` runs at 120 Hz, which
                    // doubles all shader work for no perceptible
                    // gain on a 1-second burst.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
                        let elapsed = ctx.date.timeIntervalSince(burst.startDate)
                        let progress = min(
                            max(elapsed / VibesEffectHost.waveShaderLifetime, 0),
                            1
                        )

                        ZStack {
                            // 1. Distorted snapshot — the actual
                            //    "UI bending." Fades out in the
                            //    last 20% so the live UI
                            //    re-emerges underneath.
                            //
                            //    maxSampleOffset trimmed from
                            //    120pt to 24pt. Actual peak
                            //    displacement is `size.y * 0.020`
                            //    ≈ 17pt; 24 gives a small margin
                            //    and lets Metal allocate a
                            //    tighter sampling buffer.
                            if let snapshot = burst.snapshot {
                                Image(uiImage: snapshot)
                                    .resizable()
                                    .layerEffect(
                                        ShaderLibrary.vibeWaveDistort(
                                            .float2(geo.size),
                                            .float2(burst.tapPoint),
                                            .float(Float(progress)),
                                            .float(1.0)
                                        ),
                                        maxSampleOffset: CGSize(width: 0, height: 24)
                                    )
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .opacity(snapshotOpacity(progress))
                            }

                            // 2. Iridescent ring overlay on top
                            //    of the distorted snapshot.
                            //    Kept as a separate pass because
                            //    it uses normal alpha blend (not
                            //    additive); merging into the glow
                            //    layer would change how rings
                            //    composite onto the snapshot.
                            Rectangle()
                                .fill(Color.black.opacity(0.001))
                                .colorEffect(
                                    ShaderLibrary.vibeWaveOverlay(
                                        .float2(geo.size),
                                        .float2(burst.tapPoint),
                                        .float(Float(progress)),
                                        .float(1.0)
                                    )
                                )
                                .frame(width: geo.size.width, height: geo.size.height)

                            // 3. Combined glow layer (residue
                            //    orbs + criss-cross streaks
                            //    summed inside one shader).
                            //    Renders on top of the ring
                            //    overlay because both contribute
                            //    additively — putting them last
                            //    matches the original z-order
                            //    where streaks sat above the
                            //    rings.
                            Rectangle()
                                .fill(Color.black.opacity(0.001))
                                .colorEffect(
                                    ShaderLibrary.vibeWaveGlow(
                                        .float2(geo.size),
                                        .float2(burst.tapPoint),
                                        .float(Float(progress)),
                                        .float(1.0)
                                    )
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                                .blendMode(.plusLighter)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Snapshot stays fully opaque until the wave displacement
    /// has essentially decayed to zero, then crossfades to the
    /// live UI in the last sliver of the burst.
    ///
    /// The distort shader scales displacement by `sin(progress * π)`,
    /// so at progress 0.95 amplitude is ~0.16 of peak; at 1.0 it
    /// hits zero. Fading earlier (the previous 0.75 cutoff) made
    /// the snapshot translucent while the still-displaced snapshot
    /// and the undisplaced live UI underneath were both visible,
    /// which read as a "double image" / two-layer reveal at the
    /// top of the screen where the wave amplitude is highest.
    private func snapshotOpacity(_ progress: Double) -> Double {
        if progress < 0.95 { return 1.0 }
        let fade = (progress - 0.95) / 0.05
        return max(0, 1.0 - fade)
    }
}

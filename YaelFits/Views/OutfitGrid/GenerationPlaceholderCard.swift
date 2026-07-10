import SwiftUI

/// The card that occupies an outfit cell in the archive while a
/// generation is in flight. Sized to match `OutfitCardView`'s
/// 168pt height so the grid layout doesn't reflow when the
/// placeholder is later swapped (via matchedGeometry, step 7) for
/// the real outfit.
///
/// Visual: once the Bria cutout exists, the user's 2D temporary
/// self shows in the cell with the looping sparkles overlaid on
/// top ("your fit is here, magic still happening to it"). Before
/// the cutout lands it's the original translucent slot + sparkle
/// field + cute phase text.
struct GenerationPlaceholderCard: View {
    let job: PipelineJob
    let phase: GenerationPhase
    let onTap: () -> Void

    /// Use the compact (calendar-sized) variant. The grid uses the
    /// full-size version so it matches `OutfitCardView`'s height
    /// (matchedGeometry morph).
    var compact: Bool = false
    /// Full-size cell height — scales with the archive's pinch zoom
    /// so the placeholder stays row-aligned with the outfit cells.
    var height: CGFloat = 168

    /// Decoded 2D still. Cached in state — decoding a multi-MB PNG
    /// in `body` would run on every grid render.
    @State private var stillImage: UIImage?

    private var cardHeight: CGFloat { compact ? 100 : height }
    private var sparkleSize: CGFloat { compact ? 130 : 200 }

    var body: some View {
        ZStack {
            if let stillImage {
                Image(uiImage: stillImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: cardHeight)
                    .frame(maxWidth: .infinity)
            }

            // Sparkle field sits ON TOP of the still — the "something
            // is cooking" signal. No fill / border / shadow so the
            // magic reads as ambient, not as a UI card on the grid.
            GenerationStarField(starSize: sparkleSize, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)

            if stillImage == nil {
                Text(phase.pillText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: job.cutoutImage?.count ?? 0) {
            guard let data = job.cutoutImage else {
                stillImage = nil
                return
            }
            // Decode off the main thread; a fork-stage cutout PNG can
            // be several MB.
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            stillImage = decoded
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generation in progress: \(phase.pillText)")
    }
}

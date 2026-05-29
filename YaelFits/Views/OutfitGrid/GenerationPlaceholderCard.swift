import SwiftUI

/// The blank-slot card that occupies an outfit cell in the archive
/// while a generation is in flight. Sized to match `OutfitCardView`'s
/// 168pt height so the grid layout doesn't reflow when the
/// placeholder is later swapped (via matchedGeometry, step 7) for
/// the real outfit.
///
/// Visual: translucent card body + cute phase text in the center +
/// looping Lottie sparkles scattered around / through the card so it
/// reads as "magic happening here, not just a loading skeleton."
struct GenerationPlaceholderCard: View {
    let job: PipelineJob
    let phase: GenerationPhase
    let onTap: () -> Void

    /// Use the compact (calendar-sized) variant. The grid uses the
    /// full-size 168pt version so it matches `OutfitCardView`'s
    /// height (matchedGeometry morph).
    var compact: Bool = false

    private var cardHeight: CGFloat { compact ? 100 : 168 }
    private var sparkleSize: CGFloat { compact ? 130 : 200 }

    var body: some View {
        ZStack {
            // No fill / border / shadow — placeholder is just a
            // white slot. The sparkle field + cute text do all the
            // visual work; the slot itself blends into the page
            // background so the "magic happening here" reads as
            // ambient, not as a UI card on top of the grid.
            GenerationStarField(starSize: sparkleSize, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)

            Text(phase.pillText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generation in progress: \(phase.pillText)")
    }
}

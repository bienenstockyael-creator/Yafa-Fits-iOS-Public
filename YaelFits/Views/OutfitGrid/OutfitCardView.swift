import SwiftUI

struct OutfitCardView: View {
    let outfit: Outfit
    /// Cell height — scales with the archive's pinch-zoom density.
    var height: CGFloat = 168
    /// False while two fingers are down (pinch in progress) so the
    /// scrub gesture can't steal a finger from the magnify.
    var scrubEnabled: Bool = true
    /// Whether to preload the full 242-frame spin sequence on appear.
    /// The grid passes false at dense zoom levels — 16+ small cells
    /// each decoding a full sequence was a main-thread freeze.
    var preloadFullSequence: Bool = true
    var eagerLoad: Bool = false
    var playEntranceSequence: Bool = false
    var entranceSequenceActive: Bool = false
    var entranceSequenceDelay: Double = 0
    var syncFrameIndex: Int? = nil
    var syncImage: UIImage? = nil
    var onTap: ((Int, UIImage?) -> Void)? = nil
    var onHorizontalDragChange: ((Bool) -> Void)? = nil
    var onFrameChange: ((Int) -> Void)? = nil

    private var isRotatable: Bool { outfit.frameCount > 1 }

    var body: some View {
        RotatableOutfitImage(
            outfit: outfit,
            height: height,
            draggable: isRotatable && scrubEnabled,
            eagerLoad: eagerLoad,
            playEntranceSequence: playEntranceSequence && isRotatable,
            entranceSequenceActive: entranceSequenceActive,
            entranceSequenceDelay: entranceSequenceDelay,
            preloadFullSequenceOnAppear: preloadFullSequence,
            // Archive grid cell: a scrub must not cancel SwiftUI touch
            // delivery, or a pinch whose first finger it stole can
            // never engage the grid's magnify.
            scrubPanCancelsTouches: false,
            syncFrameIndex: syncFrameIndex,
            syncImage: syncImage,
            onTapStateCapture: onTap,
            onHorizontalDragChange: onHorizontalDragChange,
            onFrameChange: onFrameChange
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .outfit3DBadge(active: isRotatable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(outfit.fullDateLabel)
    }
}

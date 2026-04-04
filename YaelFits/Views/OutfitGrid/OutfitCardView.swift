import SwiftUI

struct OutfitCardView: View {
    let outfit: Outfit
    var eagerLoad: Bool = false
    var playEntranceSequence: Bool = false
    var entranceSequenceActive: Bool = false
    var entranceSequenceDelay: Double = 0
    var syncFrameIndex: Int? = nil
    var syncImage: UIImage? = nil
    var onTap: ((Int, UIImage?) -> Void)? = nil
    var onHorizontalDragChange: ((Bool) -> Void)? = nil
    var onFrameChange: ((Int) -> Void)? = nil

    var body: some View {
        RotatableOutfitImage(
            outfit: outfit,
            height: 168,
            draggable: true,
            eagerLoad: eagerLoad,
            playEntranceSequence: playEntranceSequence,
            entranceSequenceActive: entranceSequenceActive,
            entranceSequenceDelay: entranceSequenceDelay,
            preloadFullSequenceOnAppear: true,
            syncFrameIndex: syncFrameIndex,
            syncImage: syncImage,
            onTapStateCapture: onTap,
            onHorizontalDragChange: onHorizontalDragChange,
            onFrameChange: onFrameChange
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(outfit.fullDateLabel)
    }
}

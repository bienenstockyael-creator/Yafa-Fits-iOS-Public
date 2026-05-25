import SwiftUI
import UIKit

/// Shared scaffolding for the grid-cell → carousel hero transition.
/// Used by both `OutfitGridView` (profile-home) and `UserProfileView`
/// (other-user profile) so the open-from-cell animation is identical
/// across both surfaces.

struct HeroTransition {
    let outfit: Outfit
    let frameIndex: Int
    let image: UIImage?
}

/// Lightweight image view used as the "ghost" cell that animates from
/// the source grid frame into the carousel target frame during a hero
/// transition. Loads asynchronously if no initial image is supplied.
struct HeroOutfitImageView: View {
    let outfit: Outfit
    let frameIndex: Int
    let initialImage: UIImage?
    @State private var image: UIImage?

    init(outfit: Outfit, frameIndex: Int, initialImage: UIImage?) {
        self.outfit = outfit
        self.frameIndex = frameIndex
        self.initialImage = initialImage

        if let initialImage {
            _image = State(initialValue: initialImage)
        } else {
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: "\(outfit.id)-\(frameIndex)") {
            guard initialImage == nil else { return }
            image = await FrameLoader.shared.frame(for: outfit, index: frameIndex)
        }
    }
}

/// Preference key that bubbles each outfit cell's `.global` frame up
/// to the enclosing grid view, so taps know where to start the hero
/// transition from. Both grid surfaces reduce by last-write-wins.
struct ListOutfitFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Bounds-checked subscript used in the carousel orchestration so a
/// stale `carouselIndex` after a deletion / refresh doesn't crash on
/// out-of-range access. Promoted out of OutfitGridView so both grid
/// surfaces can share the same helper.
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

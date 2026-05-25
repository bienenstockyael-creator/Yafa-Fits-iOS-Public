import SwiftUI

/// 3D-outfit visual identifier: a small, subtle grey rotation icon
/// pinned to the top-right of any thumbnail or card whose underlying
/// outfit has more than one frame. 2D outfits omit it so users learn
/// at a glance which fits rotate.
///
/// `inset` shorthand applies the same padding to both top and trailing;
/// the overload with separate `topInset` / `trailingInset` is for
/// cells (calendar) where the badge needs to vertically align with a
/// date row rather than sit inside the image bounds.

struct Outfit3DBadgeModifier: ViewModifier {
    var active: Bool
    var topInset: CGFloat
    var trailingInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if active {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppPalette.textFaint.opacity(0.55))
                    .padding(.top, topInset)
                    .padding(.trailing, trailingInset)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func outfit3DBadge(active: Bool, inset: CGFloat = 8) -> some View {
        modifier(Outfit3DBadgeModifier(active: active, topInset: inset, trailingInset: inset))
    }

    func outfit3DBadge(active: Bool, topInset: CGFloat, trailingInset: CGFloat) -> some View {
        modifier(Outfit3DBadgeModifier(active: active, topInset: topInset, trailingInset: trailingInset))
    }
}

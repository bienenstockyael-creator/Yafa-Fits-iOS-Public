import CoreGraphics
import UIKit

/// Single source of truth for the geometry shared by the
/// generation pill / chip / card / chin views. Previously these
/// values were duplicated across `GenerationExpandedCard`,
/// `GenerationPillStack`, `GenerationChipPill`, and `RootView`'s
/// safe-area inset — a tweak in one place silently broke the
/// pill ↔ card morph hand-off in another.
enum GenerationLayout {
    // MARK: Pill / chip

    static let pillWidth: CGFloat = 200
    static let pillHeight: CGFloat = 52
    static let pillVerticalSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 26

    // MARK: Card

    /// Card height for non-`.done` phases (in-progress + chin).
    static let cardHeight: CGFloat = 440
    static let doneCardHeight: CGFloat = 320

    // MARK: Chin

    /// How far the chin backing extends UP behind the main card.
    /// Must be > 2× `cornerRadius` so the chin's rounded top
    /// corners sit fully inside the main card's straight middle
    /// — at exactly 26pt the chin's top corners curve outward
    /// exactly where the main card's bottom corners curve inward,
    /// leaving a visible seam.
    static let chinOverlap: CGFloat = 70

    static let chinVisibleReview: CGFloat = 218
    static let chinVisibleDecision: CGFloat = 174

    // MARK: Tab bar
    //
    // App-controlled. Matches the safe-area-inset VStack layout
    // in `RootView` — if the tab bar dimensions change there,
    // update here.

    static let tabBarHeight: CGFloat = 60
    static let tabBarBottomPadding: CGFloat = 8
    static let chipToTabBarGap: CGFloat = 8

    /// Vertical distance from the bottom of the screen up to the
    /// TOP of the chip slot.
    static func chipSlotInsetFromBottom(bottomSafeInset: CGFloat) -> CGFloat {
        pillHeight + chipToTabBarGap + tabBarInsetFromBottom(bottomSafeInset: bottomSafeInset)
    }

    /// Vertical distance from the bottom of the screen up to the
    /// TOP of the tab bar.
    static func tabBarInsetFromBottom(bottomSafeInset: CGFloat) -> CGFloat {
        tabBarHeight + tabBarBottomPadding + bottomSafeInset
    }

    /// Actual bottom safe-area inset of the active window. Used by
    /// the card morph math because a GeometryReader inside
    /// `.ignoresSafeArea()` reports zeros for safe-area insets
    /// (the view has "ignored" them) — and we need the real value
    /// so the pill morph target lands at the same Y as the real
    /// chip, which sits inside the safe area.
    @MainActor
    static var keyWindowBottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets
            .bottom ?? 0
    }

    /// Same for the top safe-area inset (status bar + dynamic
    /// island on modern iPhones; status bar height on older).
    @MainActor
    static var keyWindowTopSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets
            .top ?? 0
    }
}

import SwiftUI

/// Grid ↔ calendar segmented toggle. Both `OutfitGridView` and
/// `CalendarMonthView` render this in their section header so users
/// can flip between layouts from inside the profile-home page itself
/// instead of from a fixed top-bar toggle.
///
/// `onToggle` only fires when the user taps the *inactive* half — the
/// active half is a no-op so we don't restart the matchedGeometry
/// transition by re-selecting the current view.
struct ViewModeTogglePill: View {
    let isCalendarActive: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            option(glyph: .grid, isSelected: !isCalendarActive) {
                if isCalendarActive { onToggle() }
            }
            option(glyph: .calendar, isSelected: isCalendarActive) {
                if !isCalendarActive { onToggle() }
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(
            Capsule().fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
        )
        .overlay(
            Capsule().stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8)
        )
        .animation(.easeInOut(duration: 0.18), value: isCalendarActive)
    }

    private func option(glyph: AppIconGlyph, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            AppIcon(glyph: glyph, size: 12, color: isSelected ? AppPalette.textPrimary : AppPalette.textFaint)
                .frame(width: 40, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

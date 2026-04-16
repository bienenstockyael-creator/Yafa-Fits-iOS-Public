import SwiftUI

struct TagPill: View {
    let tag: String
    var isActive: Bool = false

    var body: some View {
        Text(tag.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(isActive ? AppPalette.pageBackground : AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .frame(height: 36)
            .background(isActive ? AppPalette.textPrimary : Color.clear, in: Capsule())
            .appCapsule(shadowRadius: 0, shadowY: 0)
    }
}

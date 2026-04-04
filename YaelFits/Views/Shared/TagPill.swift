import SwiftUI

struct TagPill: View {
    let tag: String

    var body: some View {
        Text(tag.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .padding(.vertical, 7)
            .appCapsule(shadowRadius: 0, shadowY: 0)
    }
}

import SwiftUI

struct TagPill: View {
    let tag: String
    var onTap: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let onTap {
            Button(action: onTap) {
                pillLabel
            }
            .buttonStyle(.plain)
        } else {
            pillLabel
        }
    }

    private var pillLabel: some View {
        Text(tag.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .frame(height: 36)
            .appCapsule(shadowRadius: 0, shadowY: 0)
    }
}

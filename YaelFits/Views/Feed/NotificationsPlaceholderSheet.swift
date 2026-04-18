import SwiftUI

struct NotificationsPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: LayoutMetrics.large) {
                Spacer()
                Image(systemName: "bell.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(AppPalette.textFaint)
                Text("No notifications yet")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                Text("Likes and comments from others will show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textFaint)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
        }
    }
}

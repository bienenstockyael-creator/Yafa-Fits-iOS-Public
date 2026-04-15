import SwiftUI

struct AvatarView: View {
    let url: String?
    let initial: String
    var size: CGFloat = 40
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .appCircle(shadowRadius: shadowRadius, shadowY: shadowY)
    }

    private var fallback: some View {
        ZStack {
            Color.clear
            Text(initial)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
        }
    }
}

import SwiftUI
import UIKit

struct LightBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - Glassmorphism modifiers

private struct AppCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AppPalette.cardFill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppCapsuleModifier: ViewModifier {
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Capsule())
                    .overlay(Capsule().fill(AppPalette.cardFill))
            }
            .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppCircleModifier: ViewModifier {
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Circle())
                    .overlay(Circle().fill(AppPalette.cardFill))
            }
            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppRoundedRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AppPalette.cardFill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

extension View {
    func appCard(
        cornerRadius: CGFloat = LayoutMetrics.cardCornerRadius,
        shadowRadius: CGFloat = 18,
        shadowY: CGFloat = 10
    ) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appCapsule(
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppCapsuleModifier(shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appCircle(
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppCircleModifier(shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appRoundedRect(
        cornerRadius: CGFloat,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppRoundedRectModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }
}

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

enum FrameConfig {
    static let dimensions = CGSize(width: 323, height: 550)
    static let framesPerOutfit = 242
    static let pixelsPerFrame: CGFloat = 1.5
    static let friction: Double = 0.985
    static let autoRotateSpeed: Double = 0.6
    static let entranceDurationSeconds: Double = 2.2
    static let velocityThreshold: Double = 0.3
}

enum AppConfig {
    static let siteBaseURL = URL(string: "https://yael-fits.vercel.app")!
    static let remoteBaseURL = siteBaseURL.appendingPathComponent("outfits", isDirectory: true)
    static let outfitsDataURL = siteBaseURL.appendingPathComponent("data/outfits.json")
    static let publicFeedDataURL = siteBaseURL.appendingPathComponent("data/public-feed.json")
    static let publicOnlyOutfitIDs: Set<String> = [
        "outfit-46-public",
        "outfit-53-public",
        "outfit-64-public",
        "outfit-65-public",
    ]
    static let excludedOutfitIDs: Set<String> = ["outfit-27"]
    static let excludedOutfitNumbers: Set<Int> = [27]
    static let cacheLimitBytes = 100 * 1024 * 1024 // 100MB
    static let cacheLimitCount = 500
    static let loaderFadeDuration: Double = 0.6
    static let listEntranceDelayAfterLoader: Double = 0.08
    static let pollIntervalSeconds: TimeInterval = 8
    static let falQueueBaseURL = URL(string: "https://queue.fal.run/")!
    static let falModelPath = "fal-ai/kling-video/v2.5-turbo/pro/image-to-video"
    static let falBackgroundRemovalModelPath = "fal-ai/bria/background/remove"
}

enum UploadConfig {
    static let defaultPrompt = "A smooth full 360 degrees circular camera orbit around the subject, moving anti clockwise (from right to left) at constant speed. The subject remains perfectly still and frozen in time."
    static let falVideoDuration = "10"
    static let compositionDimensions = CGSize(
        width: FrameConfig.dimensions.width * 2,
        height: FrameConfig.dimensions.height * 2
    )
    static let extractedFrameCount = FrameConfig.framesPerOutfit - 1
    static let falPollingIntervalSeconds: TimeInterval = 3
}

enum LayoutMetrics {
    static let touchTarget: CGFloat = 44
    static let xxxSmall: CGFloat = 4
    static let xxSmall: CGFloat = 8
    static let xSmall: CGFloat = 12
    static let small: CGFloat = 16
    static let medium: CGFloat = 20
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
    static let screenPadding: CGFloat = 20
    static let listTopInset: CGFloat = 76
    static let carouselTopInset: CGFloat = 76
    static let calendarTopInset: CGFloat = 94
    static let feedTopInset: CGFloat = 92
    static let uploadTopInset: CGFloat = 92
    static let bottomOverlayInset: CGFloat = 120
    static let floatingControlsInset: CGFloat = 176
    static let compactCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 24
}

enum AppPalette {
    static let pageBackground = Color.white
    static let groupedBackground = Color(red: 236 / 255, green: 240 / 255, blue: 246 / 255)
    static let cardFill = Color.white.opacity(0.48)
    static let cardBorder = Color.white.opacity(0.92)
    static let cardShadow = Color.black.opacity(0.08)
    static let uploadGlow = Color(red: 0.57, green: 0.79, blue: 1.0)
    static let textStrong = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)   // gray-900
    static let textPrimary = Color(red: 31 / 255, green: 41 / 255, blue: 55 / 255)  // gray-800
    static let textSecondary = Color(red: 75 / 255, green: 85 / 255, blue: 99 / 255) // gray-600
    static let textMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)  // gray-500
    static let textFaint = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)  // gray-400
    static let iconPrimary = textMuted
    static let iconActive = textPrimary
    static let iconFaint = textFaint
    static let glassForeground = iconPrimary
    static let glassMutedForeground = textMuted
    static let glassFaintForeground = textFaint
}

enum AppIconGlyph {
    case grid
    case calendar
    case plusCircle
    case globe
    case heart
    case comment
    case trash
    case bookmark
    case chevronLeft
    case chevronRight
    case xmark
    case camera
    case image
    case video
    case check
    case circleCheck
    case circleAlert
    case sun
    case cloud
    case wind
    case snowflake
    case thermometer
}

struct AppIcon: View {
    let glyph: AppIconGlyph
    var size: CGFloat = 24
    var color: Color = AppPalette.iconPrimary
    var filled = false
    var strokeWidth: CGFloat = 2

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let lineWidth = min(rect.width, rect.height) * (strokeWidth / 24)
            let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            if filled, let fillPath = fillPath(in: rect) {
                context.fill(fillPath, with: .color(color))
            }

            for path in strokePaths(in: rect) {
                context.stroke(path, with: .color(color), style: strokeStyle)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func strokePaths(in rect: CGRect) -> [Path] {
        switch glyph {
        case .grid:
            return [
                roundedRectPath(x: 3, y: 3, width: 18, height: 18, radius: 2, in: rect),
                linePath(from: (3, 9), to: (21, 9), in: rect),
                linePath(from: (3, 15), to: (21, 15), in: rect),
                linePath(from: (9, 3), to: (9, 21), in: rect),
                linePath(from: (15, 3), to: (15, 21), in: rect),
            ]

        case .calendar:
            return [
                linePath(from: (8, 2), to: (8, 6), in: rect),
                linePath(from: (16, 2), to: (16, 6), in: rect),
                roundedRectPath(x: 3, y: 4, width: 18, height: 18, radius: 2, in: rect),
                linePath(from: (3, 10), to: (21, 10), in: rect),
            ]

        case .plusCircle:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                linePath(from: (8, 12), to: (16, 12), in: rect),
                linePath(from: (12, 8), to: (12, 16), in: rect),
            ]

        case .globe:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                ellipsePath(x: 8, y: 2, width: 8, height: 20, in: rect),
                linePath(from: (2, 12), to: (22, 12), in: rect),
            ]

        case .heart:
            return [heartPath(in: rect)]

        case .comment:
            return [
                roundedRectPath(x: 4, y: 5, width: 16, height: 12, radius: 4, in: rect),
                polylinePath(points: [(10, 17), (8.5, 20), (13, 17)], in: rect),
            ]

        case .trash:
            return [
                roundedRectPath(x: 7, y: 8, width: 10, height: 12, radius: 2, in: rect),
                linePath(from: (5, 8), to: (19, 8), in: rect),
                linePath(from: (9.5, 5), to: (14.5, 5), in: rect),
                linePath(from: (10.5, 11), to: (10.5, 17), in: rect),
                linePath(from: (13.5, 11), to: (13.5, 17), in: rect),
                linePath(from: (8.5, 5), to: (7, 8), in: rect),
                linePath(from: (15.5, 5), to: (17, 8), in: rect),
            ]

        case .bookmark:
            return [bookmarkPath(in: rect)]

        case .chevronLeft:
            return [polylinePath(points: [(15, 18), (9, 12), (15, 6)], in: rect)]

        case .chevronRight:
            return [polylinePath(points: [(9, 18), (15, 12), (9, 6)], in: rect)]

        case .xmark:
            return [
                linePath(from: (18, 6), to: (6, 18), in: rect),
                linePath(from: (6, 6), to: (18, 18), in: rect),
            ]

        case .camera:
            return [
                roundedRectPath(x: 2, y: 7, width: 20, height: 13, radius: 2, in: rect),
                circlePath(cx: 12, cy: 13, r: 3, in: rect),
                polylinePath(points: [(8, 7), (9.4, 4.9), (14.6, 4.9), (16, 7)], in: rect),
            ]

        case .image:
            return [
                roundedRectPath(x: 3, y: 3, width: 18, height: 18, radius: 2, in: rect),
                circlePath(cx: 9, cy: 9, r: 2, in: rect),
                polylinePath(points: [(21, 15), (17.6, 11.6), (15.2, 14), (6, 21)], in: rect),
            ]

        case .video:
            return [
                roundedRectPath(x: 2, y: 6, width: 14, height: 12, radius: 2, in: rect),
                polygonPath(points: [(16, 10.5), (21.5, 7.5), (21.5, 16.5), (16, 13)], in: rect),
            ]

        case .check:
            return [polylinePath(points: [(20, 6), (9, 17), (4, 12)], in: rect)]

        case .circleCheck:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                polylinePath(points: [(17.5, 9), (10.7, 15.8), (6.5, 11.6)], in: rect),
            ]

        case .circleAlert:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                linePath(from: (12, 8), to: (12, 12), in: rect),
                linePath(from: (12, 16.15), to: (12.01, 16.15), in: rect),
            ]

        case .sun:
            return [
                circlePath(cx: 12, cy: 12, r: 4, in: rect),
                linePath(from: (12, 2), to: (12, 4), in: rect),
                linePath(from: (12, 20), to: (12, 22), in: rect),
                linePath(from: (2, 12), to: (4, 12), in: rect),
                linePath(from: (20, 12), to: (22, 12), in: rect),
                linePath(from: (4.93, 4.93), to: (6.34, 6.34), in: rect),
                linePath(from: (17.66, 17.66), to: (19.07, 19.07), in: rect),
                linePath(from: (4.93, 19.07), to: (6.34, 17.66), in: rect),
                linePath(from: (17.66, 6.34), to: (19.07, 4.93), in: rect),
            ]

        case .cloud:
            return [cloudPath(in: rect)]

        case .wind:
            return [windTopPath(in: rect), windMiddlePath(in: rect), windBottomPath(in: rect)]

        case .snowflake:
            return [
                linePath(from: (12, 3), to: (12, 21), in: rect),
                linePath(from: (4.2, 7.2), to: (19.8, 16.8), in: rect),
                linePath(from: (19.8, 7.2), to: (4.2, 16.8), in: rect),
            ]

        case .thermometer:
            return [thermometerPath(in: rect)]
        }
    }

    private func fillPath(in rect: CGRect) -> Path? {
        switch glyph {
        case .heart:
            return heartPath(in: rect)
        case .bookmark:
            return bookmarkPath(in: rect)
        default:
            return nil
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * (x / 24),
            y: rect.minY + rect.height * (y / 24)
        )
    }

    private func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * (x / 24),
            y: rect.minY + rect.height * (y / 24),
            width: rect.width * (width / 24),
            height: rect.height * (height / 24)
        )
    }

    private func linePath(from start: (CGFloat, CGFloat), to end: (CGFloat, CGFloat), in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(start.0, start.1, in: rect))
        path.addLine(to: point(end.0, end.1, in: rect))
        return path
    }

    private func polylinePath(points: [(CGFloat, CGFloat)], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.0, first.1, in: rect))
        for next in points.dropFirst() {
            path.addLine(to: point(next.0, next.1, in: rect))
        }
        return path
    }

    private func polygonPath(points: [(CGFloat, CGFloat)], in rect: CGRect) -> Path {
        var path = polylinePath(points: points, in: rect)
        path.closeSubpath()
        return path
    }

    private func roundedRectPath(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        radius: CGFloat,
        in rect: CGRect
    ) -> Path {
        let scaled = scaledRect(x: x, y: y, width: width, height: height, in: rect)
        let scaledRadius = min(scaled.width, scaled.height) * (radius / min(width, height))
        return Path(
            roundedRect: scaled,
            cornerSize: CGSize(width: scaledRadius, height: scaledRadius),
            style: .continuous
        )
    }

    private func circlePath(cx: CGFloat, cy: CGFloat, r: CGFloat, in rect: CGRect) -> Path {
        Path(ellipseIn: scaledRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2, in: rect))
    }

    private func ellipsePath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in rect: CGRect) -> Path {
        Path(ellipseIn: scaledRect(x: x, y: y, width: width, height: height, in: rect))
    }

    private func heartPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(12, 20.7, in: rect))
        path.addCurve(
            to: point(2.4, 9.7, in: rect),
            control1: point(6.4, 17.1, in: rect),
            control2: point(2.1, 14.3, in: rect)
        )
        path.addCurve(
            to: point(7.8, 5.2, in: rect),
            control1: point(2.6, 6.6, in: rect),
            control2: point(5.4, 4.5, in: rect)
        )
        path.addCurve(
            to: point(12, 7.2, in: rect),
            control1: point(9.4, 5.2, in: rect),
            control2: point(10.8, 6.1, in: rect)
        )
        path.addCurve(
            to: point(16.2, 5.2, in: rect),
            control1: point(13.2, 6.1, in: rect),
            control2: point(14.6, 5.2, in: rect)
        )
        path.addCurve(
            to: point(21.6, 9.7, in: rect),
            control1: point(18.6, 4.5, in: rect),
            control2: point(21.4, 6.6, in: rect)
        )
        path.addCurve(
            to: point(12, 20.7, in: rect),
            control1: point(21.9, 14.3, in: rect),
            control2: point(17.6, 17.1, in: rect)
        )
        path.closeSubpath()
        return path
    }

    private func bookmarkPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(7, 3, in: rect))
        path.addQuadCurve(to: point(5, 5, in: rect), control: point(5, 3, in: rect))
        path.addLine(to: point(5, 20, in: rect))
        path.addLine(to: point(12, 16.2, in: rect))
        path.addLine(to: point(19, 20, in: rect))
        path.addLine(to: point(19, 5, in: rect))
        path.addQuadCurve(to: point(17, 3, in: rect), control: point(19, 3, in: rect))
        path.closeSubpath()
        return path
    }

    private func cloudPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(17.5, 19, in: rect))
        path.addCurve(
            to: point(9, 19, in: rect),
            control1: point(14.8, 19, in: rect),
            control2: point(11.8, 19, in: rect)
        )
        path.addCurve(
            to: point(4.4, 14.2, in: rect),
            control1: point(6.2, 19, in: rect),
            control2: point(4.4, 17.2, in: rect)
        )
        path.addCurve(
            to: point(9.2, 9, in: rect),
            control1: point(4.4, 11.4, in: rect),
            control2: point(6.6, 9, in: rect)
        )
        path.addCurve(
            to: point(15.7, 10, in: rect),
            control1: point(11.7, 9, in: rect),
            control2: point(13.9, 8.8, in: rect)
        )
        path.addCurve(
            to: point(17.5, 10, in: rect),
            control1: point(16.3, 10, in: rect),
            control2: point(16.9, 10, in: rect)
        )
        path.addCurve(
            to: point(20.6, 14.5, in: rect),
            control1: point(19.8, 10, in: rect),
            control2: point(20.9, 12, in: rect)
        )
        path.addCurve(
            to: point(17.5, 19, in: rect),
            control1: point(20.6, 17.1, in: rect),
            control2: point(19.4, 19, in: rect)
        )
        return path
    }

    private func windTopPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(2, 8, in: rect))
        path.addCurve(
            to: point(17.5, 8, in: rect),
            control1: point(7, 8, in: rect),
            control2: point(14, 8, in: rect)
        )
        path.addCurve(
            to: point(19.5, 10, in: rect),
            control1: point(18.9, 8, in: rect),
            control2: point(20, 8.8, in: rect)
        )
        path.addCurve(
            to: point(17.5, 12, in: rect),
            control1: point(20, 11.2, in: rect),
            control2: point(18.9, 12, in: rect)
        )
        return path
    }

    private func windMiddlePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(2, 12, in: rect))
        path.addCurve(
            to: point(20.5, 12, in: rect),
            control1: point(7, 12, in: rect),
            control2: point(16.8, 12, in: rect)
        )
        path.addCurve(
            to: point(22, 13.5, in: rect),
            control1: point(21.3, 12, in: rect),
            control2: point(22, 12.6, in: rect)
        )
        path.addCurve(
            to: point(20.5, 15, in: rect),
            control1: point(22, 14.4, in: rect),
            control2: point(21.3, 15, in: rect)
        )
        return path
    }

    private func windBottomPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(2, 16, in: rect))
        path.addCurve(
            to: point(12.8, 16, in: rect),
            control1: point(5.5, 16, in: rect),
            control2: point(10.4, 16, in: rect)
        )
        path.addCurve(
            to: point(14, 17.8, in: rect),
            control1: point(13.6, 16, in: rect),
            control2: point(14.2, 16.8, in: rect)
        )
        path.addCurve(
            to: point(12.8, 19.6, in: rect),
            control1: point(14.2, 18.8, in: rect),
            control2: point(13.6, 19.6, in: rect)
        )
        return path
    }

    private func thermometerPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(12, 20, in: rect))
        path.addCurve(
            to: point(8, 16, in: rect),
            control1: point(9.8, 20, in: rect),
            control2: point(8, 18.2, in: rect)
        )
        path.addCurve(
            to: point(10, 12.8, in: rect),
            control1: point(8, 14.7, in: rect),
            control2: point(8.8, 13.7, in: rect)
        )
        path.addLine(to: point(10, 4.2, in: rect))
        path.addCurve(
            to: point(12, 2, in: rect),
            control1: point(10, 3, in: rect),
            control2: point(10.9, 2, in: rect)
        )
        path.addCurve(
            to: point(14, 4.2, in: rect),
            control1: point(13.1, 2, in: rect),
            control2: point(14, 3, in: rect)
        )
        path.addLine(to: point(14, 12.8, in: rect))
        path.addCurve(
            to: point(16, 16, in: rect),
            control1: point(15.2, 13.7, in: rect),
            control2: point(16, 14.7, in: rect)
        )
        path.addCurve(
            to: point(12, 20, in: rect),
            control1: point(16, 18.2, in: rect),
            control2: point(14.2, 20, in: rect)
        )
        return path
    }
}

struct LightBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

private struct AppCardModifier: ViewModifier {
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

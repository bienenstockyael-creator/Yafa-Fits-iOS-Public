import Foundation
import SwiftUI

// MARK: - App Configuration

enum FrameConfig {
    // Frame size doubled from 323x550 to 646x1100 — experiment for visible
    // sharpness without changing Kling input resolution.
    static let dimensions = CGSize(width: 646, height: 1100)
    static let framesPerOutfit = 242
    static let pixelsPerFrame: CGFloat = 1.5
    static let friction: Double = 0.985
    static let autoRotateSpeed: Double = 0.6
    static let entranceDurationSeconds: Double = 2.2
    static let velocityThreshold: Double = 0.3
}

enum AppConfig {
    static let siteBaseURL = URL(string: "https://yael-fits.vercel.app")!
    /// The account that owns the bundled archive outfits.
    static let archiveOwnerUserId = "31c9f3fd-e672-43f2-954a-0b141640e76f"
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
    static let cacheLimitBytes = 100 * 1024 * 1024
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
    // Kling input canvas — pinned to the original 646x1100 size. Bumping FrameConfig.dimensions
    // would otherwise push the Kling input to 1292x2200, which we don't want (slower, larger,
    // potentially over Kling input limits). Frames now match composition resolution 1:1.
    static let compositionDimensions = CGSize(width: 646, height: 1100)
    static let extractedFrameCount = FrameConfig.framesPerOutfit - 1
    static let falPollingIntervalSeconds: TimeInterval = 3
}

// MARK: - Relative Time

enum RelativeTime {
    static func label(from date: Date?) -> String {
        guard let date else { return "" }
        let components = Calendar.current.dateComponents([.minute, .hour, .day], from: date, to: Date())
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0

        if days > 7 {
            return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        } else if days > 0 {
            return "\(days)D AGO"
        } else if hours > 0 {
            return "\(hours)H AGO"
        } else if minutes > 0 {
            return "\(minutes)M AGO"
        } else {
            return "JUST NOW"
        }
    }

    static func short(from date: Date?) -> String {
        guard let date else { return "" }
        let components = Calendar.current.dateComponents([.minute, .hour, .day], from: date, to: Date())
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0

        if days > 7 {
            return date.formatted(.dateTime.month(.abbreviated).day())
        } else if days > 0 {
            return "\(days)d"
        } else if hours > 0 {
            return "\(hours)h"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "now"
        }
    }
}

// MARK: - Layout

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
    static let compactCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 24

    private static var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 47
    }

    private static var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 34
    }

    static var topBarHeight: CGFloat { safeTop + touchTarget }
    static var tabBarHeight: CGFloat { 58 + safeBottom }

    private static var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.bounds.height ?? 852
    }

    static var listTopInset: CGFloat { topBarHeight - screenHeight * 0.065 }
    static var carouselTopInset: CGFloat { topBarHeight }
    static var calendarTopInset: CGFloat { topBarHeight - screenHeight * 0.018 }
    static var feedTopInset: CGFloat { topBarHeight - screenHeight * 0.045 }
    static var uploadTopInset: CGFloat { topBarHeight - screenHeight * 0.044 }
}

// MARK: - Colors

enum AppPalette {
    static let pageBackground = Color.white
    static let groupedBackground = Color(red: 236 / 255, green: 240 / 255, blue: 246 / 255)
    static let cardFill = Color.white.opacity(0.48)
    static let cardBorder = Color.white.opacity(0.92)
    static let cardShadow = Color.black.opacity(0.08)
    static let uploadGlow = Color(red: 0.0, green: 0.8, blue: 0.75)
    static let textStrong = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)
    static let textPrimary = Color(red: 31 / 255, green: 41 / 255, blue: 55 / 255)
    static let textSecondary = Color(red: 75 / 255, green: 85 / 255, blue: 99 / 255)
    static let textMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let textFaint = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
    static let iconPrimary = textMuted
    static let iconActive = textPrimary
    static let iconFaint = textFaint
    static let glassForeground = iconPrimary
    static let glassMutedForeground = textMuted
    static let glassFaintForeground = textFaint
}

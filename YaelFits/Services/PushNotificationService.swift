import UIKit
import SwiftUI
import UserNotifications

// MARK: - In-app notice pill

/// Foreground notifications don't use the system banner — iOS can't style
/// it. Instead `willPresent` suppresses it and routes the content here,
/// and RootView overlays a small Yafa-styled pill at the top of the screen.
@Observable
@MainActor
final class InAppNoticeCenter {
    static let shared = InAppNoticeCenter()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let kind: String?
        let title: String
    }

    private(set) var current: Notice?
    private var dismissTask: Task<Void, Never>?

    func show(kind: String?, title: String) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            current = Notice(kind: kind, title: title)
        }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { current = nil }
    }
}

/// The pill itself — compact capsule, app-styled, kind-matched icon.
/// Vibes use the SAME gradient flame as the profile chip and the
/// particle burst, so the notification reads as "a vibe arrived".
struct InAppNoticePill: View {
    let notice: InAppNoticeCenter.Notice

    var body: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            icon
            Text(notice.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, LayoutMetrics.xSmall)
        .padding(.vertical, 8)
        .appCapsule(shadowRadius: 8, shadowY: 2)
        .onTapGesture { InAppNoticeCenter.shared.dismiss() }
    }

    @ViewBuilder
    private var icon: some View {
        switch notice.kind {
        case "vibe":
            GradientFlameIcon(size: 15, stroked: true)
        case "like":
            AppIcon(glyph: .heart, size: 14, color: AppPalette.iconPrimary, filled: true)
        case "comment":
            AppIcon(glyph: .comment, size: 14, color: AppPalette.iconPrimary)
        case "follow":
            AppIcon(glyph: .person, size: 14, color: AppPalette.iconPrimary)
        default:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.iconPrimary)
        }
    }
}

// MARK: - App Delegate (token registration hook)

final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Without a delegate, iOS suppresses ALL notification banners while
        // the app is foregrounded — a like arriving mid-session showed
        // nothing. Present social pushes as banners in-app too.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // In-app: suppress the (unstylable) system banner and show the
        // Yafa pill instead. Backgrounded/locked delivery is untouched.
        let content = notification.request.content
        let kind = content.userInfo["kind"] as? String
        await InAppNoticeCenter.shared.show(kind: kind, title: content.title)
        return []
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        print("[APNs] Registered device token: \(tokenString.prefix(20))...")
        #endif
        Task {
            await PushNotificationCoordinator.shared.didReceiveToken(tokenString)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[APNs] Failed to register: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - Coordinator

actor PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    private var userId: UUID?
    private var pendingToken: String?

    func setUserId(_ userId: UUID?) async {
        self.userId = userId
        if let token = pendingToken, let userId {
            await upsertToken(token, userId: userId)
            pendingToken = nil
        }
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        // Check current status — if previously denied, skip (user must enable in Settings)
        let settings = await center.notificationSettings()
        #if DEBUG
        print("[APNs] Current notification status: \(settings.authorizationStatus.rawValue)")
        #endif

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            #if DEBUG
            print("[APNs] Permission granted: \(granted)")
            #endif
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break // already granted
        default:
            #if DEBUG
            print("[APNs] Permission denied — user must enable in Settings")
            #endif
            return
        }

        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didReceiveToken(_ token: String) async {
        if let userId {
            await upsertToken(token, userId: userId)
        } else {
            pendingToken = token
        }
    }

    // MARK: - Private

    private struct TokenRow: Encodable {
        let token: String
        let user_id: String
        let platform: String
        let environment: String
        let bundle_identifier: String
    }

    private func upsertToken(_ token: String, userId: UUID) async {
        // Paid developer account + aps-environment:production entitlement means
        // iOS emits production tokens even in debug builds. Server falls back to
        // the dev APNs endpoint automatically if production returns BadDeviceToken.
        let environment = "production"

        let row = TokenRow(
            token: token,
            user_id: userId.uuidString,
            platform: "ios",
            environment: environment,
            bundle_identifier: Bundle.main.bundleIdentifier ?? "com.yafa.Yafa"
        )
        do {
            try await supabase
                .from("device_push_tokens")
                .upsert(row)
                .execute()
            #if DEBUG
            print("[APNs] Token upserted for env: \(environment)")
            #endif
        } catch {
            #if DEBUG
            print("[APNs] Token upsert failed: \(error)")
            #endif
        }
    }
}

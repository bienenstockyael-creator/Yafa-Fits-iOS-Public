import UIKit
import UserNotifications

// MARK: - App Delegate (token registration hook)

final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
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

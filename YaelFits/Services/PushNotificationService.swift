import UIKit
import UserNotifications

// MARK: - App Delegate (token registration hook)

final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[APNs] Registered device token: \(tokenString.prefix(20))...")
        Task {
            await PushNotificationCoordinator.shared.didReceiveToken(tokenString)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] Failed to register: \(error.localizedDescription)")
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
        print("[APNs] Current notification status: \(settings.authorizationStatus.rawValue)")

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            print("[APNs] Permission granted: \(granted)")
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break // already granted
        default:
            print("[APNs] Permission denied — user must enable in Settings")
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
        // Use development for debug builds, production for release/TestFlight
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif

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
            print("[APNs] Token upserted for env: \(environment)")
        } catch {
            print("[APNs] Token upsert failed: \(error)")
        }
    }
}

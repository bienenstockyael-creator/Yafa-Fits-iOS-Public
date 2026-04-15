import UIKit
import UserNotifications

// MARK: - App Delegate (token registration hook)

final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await PushNotificationCoordinator.shared.didReceiveToken(tokenString)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silently ignore — push is best-effort
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
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
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
        let row = TokenRow(
            token: token,
            user_id: userId.uuidString,
            platform: "ios",
            environment: "development",
            bundle_identifier: Bundle.main.bundleIdentifier ?? "com.yafa.Yafa"
        )
        _ = try? await supabase
            .from("device_push_tokens")
            .upsert(row)
            .execute()
    }
}

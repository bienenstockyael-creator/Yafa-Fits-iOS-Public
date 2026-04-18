import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var showProfileSetup = false

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isLoading {
                    ZStack {
                        Color.white.ignoresSafeArea()
                        ProgressView()
                    }
                } else if authManager.isAuthenticated {
                    RootView()
                        .environment(outfitStore)
                        .task(id: authManager.userId) {
                            if let userId = authManager.userId {
                                outfitStore.userId = userId
                                outfitStore.isLoading = true
                                async let social: Void = outfitStore.loadSocialData(userId: userId)
                                async let data: Void = outfitStore.loadData()
                                _ = await (social, data)
                                outfitStore.restorePersistedPendingReviewIfNeeded()
                                await outfitStore.checkForServerCompletedJob(userId: userId)
                                // Show profile setup for new users with no display name
                                if outfitStore.currentProfile?.displayName == nil {
                                    await MainActor.run { showProfileSetup = true }
                                }
                            }
                        }
                        .sheet(isPresented: $showProfileSetup) {
                            if let userId = authManager.userId {
                                ProfileSetupSheet(userId: userId) {
                                    showProfileSetup = false
                                }
                                .presentationDetents([.large])
                                .presentationDragIndicator(.hidden)
                                .presentationBackground(AppPalette.pageBackground)
                                .presentationCornerRadius(20)
                            }
                        }
                } else {
                    AuthView()
                }
            }
            .environment(authManager)
            .task(id: authManager.userId) {
                await PushNotificationCoordinator.shared.setUserId(authManager.userId)
            }
            .task {
                await authManager.initialize()
            }
        }
    }

    private func requestNotificationPermission() async {
        await PushNotificationCoordinator.shared.requestAuthorization()
    }
}

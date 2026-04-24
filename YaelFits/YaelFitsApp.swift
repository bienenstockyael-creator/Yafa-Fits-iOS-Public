import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var showProfileSetup = false
    @Environment(\.scenePhase) private var scenePhase

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
                                await outfitStore.refreshUnreadNotificationCount()
                                // Show profile setup for new users with no display name
                                let needsSetup = outfitStore.currentProfile?.username == nil || (outfitStore.currentProfile?.username ?? "").isEmpty
                                if needsSetup {
                                    await MainActor.run { showProfileSetup = true }
                                }
                            }
                        }
                        .sheet(isPresented: $showProfileSetup) {
                            if let userId = authManager.userId {
                                ProfileSetupSheet(
                                    userId: userId,
                                    existingDisplayName: outfitStore.currentProfile?.displayName
                                ) {
                                    showProfileSetup = false
                                    Task { await outfitStore.loadSocialData(userId: userId) }
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, authManager.isAuthenticated {
                    Task { await outfitStore.refreshOutfits() }
                }
            }
        }
    }

    private func requestNotificationPermission() async {
        await PushNotificationCoordinator.shared.requestAuthorization()
    }
}

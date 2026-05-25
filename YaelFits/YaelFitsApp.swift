import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var showOnboarding = false
    // Pre-auth WelcomeTourView is parked while it gets redesigned. The
    // file lives at Views/Auth/WelcomeTourView.swift; to re-enable, restore
    // the `@AppStorage("hasSeenWelcomeTour")` declaration and the branch
    // below that gated on it. The stored UserDefaults value is preserved.
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
                    ZStack {
                        RootView()
                            .environment(outfitStore)
                            .task(id: authManager.userId) {
                                if let userId = authManager.userId {
                                    outfitStore.beginSession(for: userId)
                                    async let social: Void = outfitStore.loadSocialData(userId: userId)
                                    async let data: Void = outfitStore.loadData()
                                    _ = await (social, data)
                                    outfitStore.restorePersistedPendingReviewIfNeeded()
                                    await outfitStore.checkForServerCompletedJob(userId: userId)
                                    await outfitStore.refreshUnreadNotificationCount()
                                    let needsSetup = outfitStore.currentProfile?.username == nil || (outfitStore.currentProfile?.username ?? "").isEmpty
                                    if needsSetup {
                                        await MainActor.run {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                showOnboarding = true
                                            }
                                        }
                                    }
                                } else {
                                    outfitStore.resetForSignedOutState()
                                    await MainActor.run { showOnboarding = false }
                                }
                            }

                        if showOnboarding, let userId = authManager.userId {
                            OnboardingView(
                                userId: userId,
                                existingDisplayName: outfitStore.currentProfile?.displayName
                            ) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showOnboarding = false
                                }
                                Task { await outfitStore.loadSocialData(userId: userId) }
                            }
                            .transition(.opacity)
                        }
                    }
                } else {
                    AuthView()
                        .transition(.opacity)
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

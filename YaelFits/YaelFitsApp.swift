import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var showOnboarding = false
    /// First-time pre-auth feature tour — shown once before AuthView,
    /// then never again. Skippable. Persisted via AppStorage so it
    /// survives reinstalls only if the user's UserDefaults survive
    /// (which they don't on a fresh install — perfect for "show on
    /// first launch").
    @AppStorage("hasSeenWelcomeTour") private var hasSeenWelcomeTour = false
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
                } else if !hasSeenWelcomeTour {
                    WelcomeTourView {
                        // hasSeenWelcomeTour is set inside the view via
                        // AppStorage; this closure just exists in case we
                        // need a side-effect on completion later.
                    }
                    .transition(.opacity)
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

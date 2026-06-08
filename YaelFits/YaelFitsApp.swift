import Lottie
import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var vibesEffectHost = VibesEffectHost()
    @State private var vibesIncomingManager = VibesIncomingManager()
    @State private var showOnboarding = false
    // Pre-auth WelcomeTourView is parked while it gets redesigned. The
    // file lives at Views/Auth/WelcomeTourView.swift; to re-enable, restore
    // the `@AppStorage("hasSeenWelcomeTour")` declaration and the branch
    // below that gated on it. The stored UserDefaults value is preserved.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
            // Main UI wrapped in the vibes wave-shader modifier
            // — when `host.waveShader` is non-nil, the entire
            // app distorts + glows via Metal. Idle case is a
            // straight pass-through with zero cost.
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
                                    await outfitStore.checkForServerCompletedJob(userId: userId)
                                    await outfitStore.refreshUnreadNotificationCount()
                                    // Two triggers for showing onboarding:
                                    //   1. `is_onboarded == false` — the
                                    //      canonical signal post-2026-06-08
                                    //      migration. New users default to
                                    //      false, finishing the flow flips
                                    //      to true.
                                    //   2. Missing username — defensive
                                    //      fallback for any user whose row
                                    //      somehow got created without the
                                    //      handle (legacy bug, manual DB
                                    //      edit, etc).
                                    let profile = outfitStore.currentProfile
                                    let needsSetup =
                                        profile?.isOnboarded == false
                                        || (profile?.username ?? "").isEmpty
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
                            OnboardingFlow {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showOnboarding = false
                                }
                                Task { await outfitStore.loadSocialData(userId: userId) }
                            }
                            .environment(outfitStore)
                            .transition(.opacity)
                        }
                    }
                } else {
                    AuthView()
                        .transition(.opacity)
                }
            }

            // Vibes wave overlay — paints iridescent rings as
            // its own transparent layer on top of the UI. NOT a
            // layerEffect on the content (that breaks on
            // UIViewRepresentables like LightBlurView and
            // LottieAnimationView, which the feed uses heavily).
            VibesWaveOverlay()

            // Hero icon morph layer — renders the tapped vibe
            // button's flame morph (outline → gradient → filled
            // with a scale bloom) above the wave-shader snapshot.
            // Without this above-snapshot layer the morph happens
            // INSIDE the button but is hidden by the snapshot,
            // resulting in "outline → suddenly filled" with no
            // visible morph.
            VibesMorphLayer()

            // Vibes particle layer — exploding fire-burst flames
            // render ABOVE the entire wave effect AND the morph
            // icon. Sibling of the main content inside the ZStack
            // — NOT an overlay modifier, since `.environment(...)`
            // after `.overlay {...}` doesn't reliably propagate
            // into the overlay's children. Input-transparent so it
            // never steals taps from the UI below.
            VibesParticleLayer()

            // Generic vibe-banner layer for short notices like
            // "Out of vibes — refreshes Monday". Anchored at the
            // top, never steals taps.
            VibesBannerLayer()

            // Incoming-vibe toast sits above the particle layer
            // so the "{user} vibed your fit" banner can't be
            // covered by a burst that fires simultaneously.
            IncomingVibeToast()

            // First-vibe explainer modal — shown once per device
            // when the user gives their first vibe. Sits at the
            // very top of the view tree so its backdrop covers
            // the burst + wave + toast layers underneath.
            VibesFirstUseModal()

            // NOTE: The profile credit-chip InfoExplainerModal is
            // NOT mounted here at root — it must be inside the
            // Settings sheet's view hierarchy to render above the
            // sheet (SwiftUI sheets present in a separate
            // hosting context, so root-level overlays sit BELOW
            // the sheet, not above). It's mounted inside
            // `ProfileView` as an `.overlay`, which ensures it
            // sits in the same window as the sheet content.

            }
            .environment(authManager)
            .environment(vibesEffectHost)
            .environment(vibesIncomingManager)
            .task(id: authManager.userId) {
                await PushNotificationCoordinator.shared.setUserId(authManager.userId)
                if let userId = authManager.userId {
                    vibesIncomingManager.start(for: userId)
                } else {
                    vibesIncomingManager.stop()
                }
            }
            .task {
                await authManager.initialize()
            }
            .task {
                prewarmLottieAnimations()
            }
            .task {
                // Watch the StoreKit transaction queue for
                // purchases that landed mid-session-kill (e.g.
                // Ask-to-Buy approvals that arrived after the
                // app was backgrounded, or App Store retries of
                // a transaction we never marked finished
                // because the validate-apple-receipt Edge
                // Function was unreachable last time). Each
                // verified update gets routed through the same
                // server-validate-then-finish path the live
                // purchase flow uses.
                await CreditPurchaseService.shared.startTransactionListener { verified in
                    do {
                        _ = try await CreditPurchaseService.shared
                            .validateAndCredit(verified)
                        await CreditPurchaseService.shared
                            .finishTransaction(verified.transaction)
                    } catch {
                        // Silent — the transaction stays in the
                        // queue, listener will retry on next
                        // launch. Surfacing UI here would be
                        // intrusive since the user isn't
                        // actively in a purchase flow.
                    }
                }
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

    /// Parses the heaviest bundled Lottie JSONs on a background
    /// queue at app launch and stuffs them into Lottie's internal
    /// animation cache. Without this, `DiscoBall.json` (1.8 MB) and
    /// its sparkle overlay would be parsed on the main thread the
    /// first time `FriendsButtonView` mounts on the empty-friends
    /// hero — synchronous JSON parse of that size visibly blocks
    /// the SwiftUI render loop. New users with no follows are the
    /// only audience that hits the empty hero; pre-warming here
    /// makes their first-launch friends-feed appearance snappy.
    /// For users with follows this is wasted work — but it runs on
    /// a `.utility` Task.detached, so it never competes with
    /// user-facing rendering.
    private func prewarmLottieAnimations() {
        Task.detached(priority: .utility) {
            _ = LottieAnimation.named("DiscoBall")
            _ = LottieAnimation.named("disco-ball-sparkles")
        }
    }
}

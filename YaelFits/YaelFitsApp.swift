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
    // The user id we've finished resolving onboarding status for.
    // The gating cover below stays up until this matches the current
    // session, so RootView never flashes before we know whether to
    // present onboarding (and it can't go stale across sign-out → a
    // new sign-in re-gates because the ids no longer match).
    @State private var resolvedForUserId: UUID?
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
                                guard let userId = authManager.userId else {
                                    outfitStore.resetForSignedOutState()
                                    await MainActor.run {
                                        showOnboarding = false
                                        resolvedForUserId = nil
                                    }
                                    return
                                }

                                outfitStore.beginSession(for: userId)

                                // Resolve onboarding BEFORE the heavy
                                // outfit/feed loads. loadSocialData applies
                                // this device's cached profile on the main
                                // actor before it returns, so currentProfile
                                // is populated the moment we read it here.
                                // Deciding now — instead of after the full
                                // data load — is what removes the flicker:
                                // the gating cover below stays up until
                                // `resolvedForUserId` matches, so a new user
                                // lands straight on the onboarding sheet with
                                // no flash of the empty profile behind it.
                                await outfitStore.loadSocialData(userId: userId)

                                // Onboarding decision. Prefer the cached
                                // profile (instant), but on a CACHE MISS
                                // (nil) fetch the authoritative profile from
                                // the server before deciding. A nil profile
                                // would otherwise make the "missing username"
                                // check true and FALSE-trigger onboarding for
                                // an already-onboarded user signing in on a
                                // fresh device / after a reinstall / after an
                                // account switch. The gating cover stays up
                                // for the brief fetch.
                                var profile = outfitStore.currentProfile
                                if profile == nil {
                                    profile = try? await SocialService.getProfile(userId: userId)
                                    if let fetched = profile {
                                        await MainActor.run {
                                            outfitStore.currentProfile = fetched
                                        }
                                    }
                                }

                                // Two triggers for showing onboarding:
                                //   1. `is_onboarded == false` — canonical
                                //      signal (new users default to false;
                                //      finishing the flow flips it true).
                                //   2. Missing username — defensive fallback.
                                // Only ever shown for a profile we actually
                                // have: a still-nil profile (cache miss +
                                // failed fetch) must NOT trigger onboarding.
                                let needsSetup = profile.map {
                                    $0.isOnboarded == false || ($0.username ?? "").isEmpty
                                } ?? false
                                await MainActor.run {
                                    showOnboarding = needsSetup
                                    resolvedForUserId = userId
                                }

                                // Remaining loads run after the onboarding
                                // decision so they never hold the cover up.
                                await outfitStore.loadData()
                                await outfitStore.checkForServerCompletedJob(userId: userId)
                                await outfitStore.refreshUnreadNotificationCount()
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

                        // Gating cover — hides RootView until we've resolved
                        // onboarding status for the current session. Without
                        // it, RootView renders the instant the session
                        // authenticates and the profile flashes for the
                        // duration of the resolve. Reuses the app-launch
                        // loading look so it hands off seamlessly from the
                        // `isLoading` spinner above.
                        if resolvedForUserId != authManager.userId {
                            ZStack {
                                Color.white.ignoresSafeArea()
                                ProgressView()
                            }
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

            // One-time "what's new" explainer for the save-products features
            // (Safari share + Chrome extension). Shown once per device, only to
            // signed-in users who are past onboarding.
            WhatsNewModal(active: authManager.isAuthenticated
                && resolvedForUserId == authManager.userId
                && !showOnboarding)

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
            .onAppear {
                // App-wide tap-outside-to-dismiss-keyboard (every window/sheet).
                GlobalKeyboardDismiss.shared.start()
            }
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

// MARK: - What's New (save-products) modal

/// One-time announcement of the two ways to save products into the closet —
/// the iOS Safari Share extension and the desktop Chrome extension. Shown once
/// per device (UserDefaults-gated), the first time a signed-in, past-onboarding
/// user re-enters the app after this update.
struct WhatsNewModal: View {
    /// Owner gates WHEN it's allowed to appear (authed + not onboarding).
    let active: Bool

    @State private var isVisible = false
    @State private var showGetExtension = false

    private let seenKey = "whatsnew_save_features_seen_v1"

    var body: some View {
        ZStack {
            if isVisible {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .transition(.opacity)

                card
                    .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isVisible)
        .onAppear { maybeShow() }
        .onChange(of: active) { _, _ in maybeShow() }
        .sheet(isPresented: $showGetExtension) {
            GetExtensionSheet()
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
    }

    private var card: some View {
        VStack(spacing: LayoutMetrics.medium) {
            // Raw header icon (matches the app's other modals — no circle).
            Image(systemName: "bag.badge.plus")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.top, LayoutMetrics.small)

            VStack(spacing: LayoutMetrics.small) {
                Text("Save products as you shop")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                    .multilineTextAlignment(.center)
                Text("Add anything you love straight to your closet — from your phone or your computer.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                infoRow(
                    icon: "square.and.arrow.up",
                    title: "On your phone",
                    body: "In Safari, tap Share → Yafa to save any product to your wishlist."
                )
                infoRow(
                    icon: "puzzlepiece.fill",
                    title: "On your computer",
                    body: "Add the Yafa Chrome extension to save while you browse."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)

            // Primary CTA matches the app convention (single GOT IT capsule).
            Button(action: dismiss) {
                Text("GOT IT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.top, LayoutMetrics.xSmall)

            // Quiet secondary link to the desktop setup sheet.
            Button {
                markSeen()
                withAnimation { isVisible = false }
                showGetExtension = true
            } label: {
                Text("Set up the Chrome extension")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .buttonStyle(SolidPressButtonStyle())
        }
        .padding(.horizontal, LayoutMetrics.large)
        .padding(.vertical, LayoutMetrics.large)
        .appCard(cornerRadius: 24, shadowRadius: 28, shadowY: 12)
        .padding(.horizontal, LayoutMetrics.medium)
    }

    private func infoRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .frame(width: 30, height: 30)
                .background(Circle().fill(AppPalette.cardFill))
                .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func maybeShow() {
        guard active, !isVisible,
              !UserDefaults.standard.bool(forKey: seenKey)
        else { return }
        Task { @MainActor in
            // Brief delay so it doesn't collide with launch / onboarding hand-off.
            try? await Task.sleep(for: .seconds(0.7))
            guard active, !UserDefaults.standard.bool(forKey: seenKey) else { return }
            markSeen()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { isVisible = true }
        }
    }

    private func dismiss() {
        markSeen()
        withAnimation { isVisible = false }
    }

    private func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}

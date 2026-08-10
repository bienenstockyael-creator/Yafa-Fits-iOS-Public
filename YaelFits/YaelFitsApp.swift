import Lottie
import Sentry
import SwiftUI
import UIKit
import UserNotifications

@main
struct YaelFitsApp: App {
    init() {
        // Crash + performance monitoring. DSN is an ingest address,
        // not a secret. Debug builds report to the "debug"
        // environment so dev noise never pollutes production alerts.
        SentrySDK.start { options in
            options.dsn = "https://b61a97449a79315a93e6e148be0b68ca@o4511879960788992.ingest.us.sentry.io/4511879964983296"
            options.tracesSampleRate = 0.2
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
        }
        #if DEBUG
        // Verification hook: SENTRY_TEST_EVENT=1 fires a test event so
        // the pipeline can be confirmed from the command line.
        if ProcessInfo.processInfo.environment["SENTRY_TEST_EVENT"] == "1" {
            SentrySDK.capture(message: "Yafa Sentry pipeline test — ignore me")
        }
        #endif
    }

    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushAppDelegate
    @State private var outfitStore = OutfitStore()
    @State private var authManager = AuthManager()
    @State private var vibesEffectHost = VibesEffectHost()
    @State private var vibesIncomingManager = VibesIncomingManager()
    @State private var showOnboarding = false
    // Held true when the signed-in user hasn't redeemed an access code (and
    // wasn't grandfathered). The access-code gate renders on top of everything
    // until they redeem, then the normal onboarding/app flow shows beneath it.
    @State private var showAccessGate = false
    /// Profile opened via a yafa://u/<username> deep link (the web
    /// invite card's "already on Yafa" path).
    @State private var deepLinkProfile: Profile?
    // The user id we've finished resolving onboarding status for.
    // The gating cover below stays up until this matches the current
    // session, so RootView never flashes before we know whether to
    // present onboarding (and it can't go stale across sign-out → a
    // new sign-in re-gates because the ids no longer match).
    @State private var resolvedForUserId: UUID?
    /// Clip → app handoff (App Group). Non-nil means this install (or
    /// launch) came through the App Clip: the signed-out flow opens
    /// with the recognition screen and AuthView carries the
    /// pre-checked Follow row.
    @State private var clipHandoff: ClipHandoff? = ClipHandoffStore.load()
    @State private var clipRecognitionDismissed = false
    @Environment(\.scenePhase) private var scenePhase

    /// Executes the clip-install follow consent once the user is
    /// fully in (existing users: right after resolve; new users:
    /// after onboarding). Idempotent and consuming: intent + handoff
    /// are cleared regardless, so the flow can never replay.
    private func consumeClipFollowIntent(userId: UUID, isNewUser: Bool) async {
        defer {
            ClipFollowIntent.clear()
            ClipHandoffStore.clear()
            Task { @MainActor in clipHandoff = nil }
        }
        guard let creatorIdString = ClipFollowIntent.creatorId(),
              let creatorId = UUID(uuidString: creatorIdString),
              creatorId != userId
        else { return }

        try? await SocialService.follow(followerId: userId, followingId: creatorId)
        await MainActor.run {
            outfitStore.followingIds.insert(creatorId)
        }
        if isNewUser {
            // The creator follow must NOT skip Find Your People —
            // the feed honors this one-shot flag on first entry.
            ClipDiscoveryPending.mark()
        }
        Analytics.log("clip_install_follow_executed", properties: [
            "creator_id": .string(creatorIdString),
            "new_user": .bool(isNewUser),
        ])
    }

    /// Sim auto-drive: COMPOSER_PREVIEW_OUTFIT=<public outfit id>
    /// opens the share composer directly on that outfit, no auth —
    /// share-template visual verification from simctl. Env vars only
    /// exist on scheme/simctl launches, so this is inert in release.
    #if DEBUG
    private static let composerPreviewOutfitId =
        ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_OUTFIT"]
    #else
    private static let composerPreviewOutfitId: String? = nil
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
            // Main UI wrapped in the vibes wave-shader modifier
            // — when `host.waveShader` is non-nil, the entire
            // app distorts + glows via Metal. Idle case is a
            // straight pass-through with zero cost.
            Group {
                if let composerPreviewOutfitId = Self.composerPreviewOutfitId {
                    ComposerPreviewHost(outfitId: composerPreviewOutfitId)
                        .environment(outfitStore)
                } else if authManager.isLoading {
                    ZStack {
                        Color.white.ignoresSafeArea()
                        ProgressView()
                    }
                } else if authManager.isAuthenticated {
                    ZStack {
                        RootView()
                            .environment(outfitStore)
                            .onAppear {
                                // Background product-thumbnail polish
                                // outlives any sheet — it needs the
                                // store to refresh outfits in place.
                                ProductThumbnailPolisher.shared.store = outfitStore
                            }
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

                                // Retry product-thumbnail polishes
                                // that died with a previous session.
                                ProductThumbnailPolisher.shared.healIfNeeded(userId: userId)

                                // Re-upload 2D frames whose bucket
                                // upload silently failed — repairs
                                // blank feed cards published by
                                // pre-1.2.3 builds.
                                TwoDOutfitService.healMissingRemoteFrames(userId: userId)

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
                                // Access gate: hold gated users (no redeemed
                                // code, not grandfathered) at the code screen.
                                // Fail OPEN on an unresolved profile so a fetch
                                // hiccup never locks out a legit user.
                                let gated = profile.map { $0.hasAccess == false } ?? false
                                await MainActor.run {
                                    showAccessGate = gated
                                    showOnboarding = needsSetup
                                    resolvedForUserId = userId
                                }
                                // Tag crash reports with the user's
                                // id (uuid only, no PII) so incidents
                                // are traceable to affected accounts.
                                let sentryUser = User(userId: userId.uuidString)
                                SentrySDK.setUser(sentryUser)

                                // Clip attribution: users who don't
                                // need onboarding (existing accounts
                                // signing in via a clip handoff)
                                // consume the pending follow here;
                                // new users consume it after
                                // onboarding completes.
                                if !needsSetup && !gated {
                                    await consumeClipFollowIntent(userId: userId, isNewUser: false)
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
                                Task {
                                    // Execute the clip-install follow
                                    // BEFORE loadSocialData so the
                                    // relationship is reflected in the
                                    // first social snapshot.
                                    await consumeClipFollowIntent(userId: userId, isNewUser: true)
                                    await outfitStore.loadSocialData(userId: userId)
                                }
                            }
                            .environment(outfitStore)
                            .transition(.opacity)
                        }

                        // Access-code gate — rendered ABOVE onboarding so it
                        // covers the whole app until the user redeems a valid
                        // one-time code. Grandfathered/redeemed users never see
                        // it (resolved as `has_access == true`). On success we
                        // flip the flag and the layer below (onboarding or the
                        // app) shows through.
                        if showAccessGate {
                            AccessCodeGate(
                                creator: clipHandoff,
                                onRedeemed: {
                                    outfitStore.currentProfile?.hasAccess = true
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showAccessGate = false
                                    }
                                },
                                onSignOut: {
                                    Task { try? await authManager.signOut() }
                                }
                            )
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
                    if let handoff = clipHandoff, !clipRecognitionDismissed {
                        ClipRecognitionView(handoff: handoff) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                clipRecognitionDismissed = true
                            }
                        }
                        .transition(.opacity)
                    } else {
                        AuthView(clipCreator: clipHandoff)
                            .transition(.opacity)
                    }
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
            .onOpenURL { url in
                // yafa://u/<username> — the invite card doubles as a
                // profile card for people who already have the app.
                guard url.scheme == "yafa" else { return }
                let parts = url.host.map { [$0] + url.pathComponents.filter { $0 != "/" } } ?? []
                guard parts.count >= 2, parts[0] == "u" else { return }
                let username = parts[1]
                Task { @MainActor in
                    if let profile = try? await SocialService.getProfile(username: username) {
                        deepLinkProfile = profile
                    }
                }
            }
            .fullScreenCover(item: $deepLinkProfile) { profile in
                UserProfileView(userId: profile.id, onDismiss: { deepLinkProfile = nil })
                    .environment(outfitStore)
                    // Clear container — same rule as every profile
                    // cover in the app (default is opaque black).
                    .presentationBackground(.clear)
            }
            .onAppear {
                // App-wide tap-outside-to-dismiss-keyboard (every window/sheet).
                GlobalKeyboardDismiss.shared.start()
                // Paint the bare window in the app's page color. A
                // fullScreenCover presented from inside a sheet unloads
                // the sheet's view behind it, exposing the raw UIWindow
                // during the cover's dismissal — which is BLACK by
                // default (the "black flash" when closing a profile
                // opened from Find Your People / follow lists). App-
                // colored, the same exposure reads as part of the
                // slide animation.
                DispatchQueue.main.async {
                    for scene in UIApplication.shared.connectedScenes {
                        guard let windowScene = scene as? UIWindowScene else { continue }
                        for window in windowScene.windows {
                            window.backgroundColor = UIColor(AppPalette.pageBackground)
                        }
                    }
                }
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
                Text("Add anything you love straight to your closet from your phone or your computer.")
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

            // Primary CTA — get the Chrome extension (the #1 action).
            Button {
                markSeen()
                withAnimation { isVisible = false }
                showGetExtension = true
            } label: {
                Text("GET THE CHROME EXTENSION")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.top, LayoutMetrics.xSmall)

            // Quiet dismiss.
            Button(action: dismiss) {
                Text("Got it")
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppPalette.textStrong)
                .frame(width: 26, height: 26)
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

    private var alreadySeen: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    private func maybeShow() {
        guard active, !isVisible, !alreadySeen else { return }
        Task { @MainActor in
            // Brief delay so it doesn't collide with launch / onboarding hand-off.
            try? await Task.sleep(for: .seconds(0.7))
            guard active, !isVisible, !alreadySeen else { return }
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

// MARK: - Access-code gate

/// Full-screen gate shown to signed-in users who haven't redeemed a one-time
/// access code (and weren't grandfathered). Lets the user enter a code or sign
/// out. On a successful redeem it calls `onRedeemed`; the parent flips the
/// `has_access` flag and dismisses this layer.
///
/// Visual language matches the onboarding flow + welcome screen: grouped
/// background, the plain Yafa logo up top (same treatment as `AuthView`), a
/// large centered inline prompt for the code, and the same capsule primary
/// button used for Continue/Skip in `OnboardingFlow`.
private struct AccessCodeGate: View {
    /// Clip handoff, when this install came via a shared fit —
    /// personalizes the gate ("@x is on Yafa — ask them for a code")
    /// while keeping it honest: a code is still required.
    var creator: ClipHandoff? = nil
    let onRedeemed: () -> Void
    let onSignOut: () -> Void

    @State private var code = ""
    @State private var isRedeeming = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRedeem: Bool { !trimmed.isEmpty }

    /// Plain figure mark (logo.png) — same asset + treatment the welcome
    /// screen uses. NOT the "MADE ON YAFA" wordmark.
    private static let logo: UIImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }()

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: LayoutMetrics.large) {
                    // Brand logo — welcome/auth-screen treatment.
                    Group {
                        if let logo = Self.logo {
                            Image(uiImage: logo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 48)
                                .colorMultiply(.black)
                                .opacity(0.82)
                        } else {
                            Text("YAFA")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .tracking(3)
                                .foregroundStyle(AppPalette.textPrimary.opacity(0.82))
                        }
                    }

                    if let creator {
                        HStack(spacing: LayoutMetrics.xSmall) {
                            AvatarView(
                                url: creator.creatorAvatarURL,
                                initial: String(creator.creatorUsername.prefix(1)).uppercased(),
                                size: 36,
                                shadowRadius: 2,
                                shadowY: 1
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text("@\(creator.creatorUsername) is on Yafa")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppPalette.textStrong)
                                Text("Ask them for an invite code to get in.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppPalette.textFaint)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, LayoutMetrics.small)
                        .padding(.vertical, LayoutMetrics.xSmall)
                        .appCard(cornerRadius: 16, shadowRadius: 4, shadowY: 2)
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                        .padding(.bottom, LayoutMetrics.medium)
                    }

                    // Centered inline prompt — same composition as an
                    // onboarding step's text entry.
                    VStack(spacing: LayoutMetrics.small) {
                        TextField(
                            "",
                            text: $code,
                            prompt: Text("Enter your access code")
                                .foregroundColor(AppPalette.textMuted.opacity(0.55))
                        )
                        // Codes are mono everywhere else in the app —
                        // the field should look like what it holds.
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.textStrong)
                        .multilineTextAlignment(.center)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onChange(of: code) { _, newValue in
                            // Auto-insert the hyphen for new-format
                            // codes (YAFA-XXXX): the dash lives behind
                            // the symbols keyboard, so typing YAFA7K2M
                            // becomes YAFA-7K2M as you go. Old-format
                            // codes and edits elsewhere are untouched
                            // (server-side redemption is forgiving
                            // regardless).
                            let up = newValue.uppercased()
                            if up.count >= 5, up.hasPrefix("YAFA"),
                               up.count <= 9,
                               !up.contains("-"),
                               up.dropFirst(4).allSatisfy({ $0.isLetter || $0.isNumber }) {
                                code = "YAFA-" + up.dropFirst(4)
                            } else if up != newValue {
                                code = up
                            }
                        }
                        .onSubmit { Task { await redeem() } }
                        .onChange(of: code) { _, _ in errorMessage = nil }
                        .padding(.horizontal, LayoutMetrics.large)

                        // Hint line — reserved height keeps the layout
                        // stable as the message swaps (mirrors the
                        // username-availability hint in onboarding).
                        Group {
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.8))
                            } else {
                                Text("Yafa is invite-only for now.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppPalette.textMuted)
                            }
                        }
                        .frame(height: 16)
                    }
                }

                Spacer(minLength: 0)

                // Primary button — identical to the onboarding Continue/Skip.
                Button {
                    Task { await redeem() }
                } label: {
                    Group {
                        if isRedeeming {
                            ProgressView().tint(AppPalette.textMuted)
                        } else {
                            Text("REDEEM")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.5)
                                .foregroundStyle(canRedeem ? AppPalette.textPrimary : AppPalette.textFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .appCapsule(
                        shadowRadius: canRedeem ? 6 : 0,
                        shadowY: canRedeem ? 3 : 0
                    )
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(!canRedeem || isRedeeming)
                .padding(.horizontal, LayoutMetrics.screenPadding)

                Button("Sign out", action: onSignOut)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.top, LayoutMetrics.medium)
                    .padding(.bottom, LayoutMetrics.xLarge)
            }
        }
        .dynamicTypeSize(.large ... .accessibility1)
        .onAppear {
            // Invite handoff: the web invite card copies the code to the
            // clipboard; if a YAFA-XXXX code is still there, pre-fill it.
            // Fill only — the user still taps REDEEM — and pattern-gated
            // so unrelated clipboard content is never touched. (iOS shows
            // its paste-permission prompt here; that's the expected trade
            // for the install-gap handoff, and only fires when the
            // clipboard actually has text.)
            if code.isEmpty, UIPasteboard.general.hasStrings,
               let paste = UIPasteboard.general.string?
                   .trimmingCharacters(in: .whitespacesAndNewlines)
                   .uppercased(),
               paste.range(of: #"^YAFA-[A-Z2-9]{4}$"#, options: .regularExpression) != nil {
                code = paste
            }
            // Small delay so the keyboard doesn't fight the layer transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                fieldFocused = true
            }
        }
    }

    @MainActor
    private func redeem() async {
        let value = trimmed
        guard !value.isEmpty, !isRedeeming else { return }
        fieldFocused = false
        isRedeeming = true
        errorMessage = nil
        defer { isRedeeming = false }

        do {
            let status = try await SocialService.redeemAccessCode(value)
            switch status {
            case "ok":
                Analytics.log("gate_redeemed")
                onRedeemed()
            case "already_used":
                withAnimation { errorMessage = "That code has already been used." }
            default: // "invalid"
                withAnimation { errorMessage = "That code isn't valid. Check it and try again." }
            }
        } catch {
            withAnimation { errorMessage = "Couldn't reach Yafa. Try again." }
        }
    }
}

#Preview("Access code gate") {
    AccessCodeGate(onRedeemed: {}, onSignOut: {})
}

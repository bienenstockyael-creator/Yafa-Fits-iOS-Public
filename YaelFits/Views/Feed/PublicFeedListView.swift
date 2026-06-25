import SwiftUI

struct PublicFeedListView: View {
    @Environment(OutfitStore.self) private var store
    @State private var showDiscover = false
    @State private var hasRefreshedFeed = false
    @State private var hasScrolled = false
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]
    @State private var myLikedOutfitIds: Set<String> = []
    /// Vibe state for the cards. Counts are per-outfit, vibed
    /// set tracks which outfits the current user has already
    /// vibed, and remainingThisWeek is the shared quota binding
    /// every card writes through.
    @State private var vibeCounts: [String: Int] = [:]
    @State private var vibedOutfitIds: Set<String> = []
    @State private var vibesRemainingThisWeek: Int = 3
    @State private var showsNotifications = false
    @State private var pendingScrollPostId: String?
    @State private var selectedDiscoveryProfile: Profile?
    /// Two-Bool state machine so the discovery decision is bulletproof
    /// against re-renders. `hasEvaluatedEntry` flips true the first
    /// time `.onAppear` fires for this tab visit; `discoveryLocked`
    /// captures whether the user came in with zero follows at that
    /// moment. Once locked, in-session follows do NOT flip the view
    /// out from under the user. Reset on tab leave.
    @State private var hasEvaluatedEntry = false
    @State private var discoveryLocked = false
    /// Belt-and-suspenders: flips true the moment `EmptyFollowingView`
    /// has ever been rendered in this tab visit. Even if some other
    /// state race tried to flip `discoveryLocked` off (or skipped
    /// `.onAppear` entirely), this flag keeps the discovery surface
    /// pinned for the rest of the session.
    @State private var everShownDiscovery = false
    /// Contacts pre-permission popup state. The alert appears
    /// when the user taps "Find your people" — we ask in our own
    /// voice first, then trigger iOS's system permission alert
    /// only if they tap "Share Contacts."
    @State private var showContactsPrompt = false
    /// Profiles matched from the user's contact list, passed to
    /// the hero to repopulate its floating avatars. `nil` means
    /// "no contacts shared yet" (or no matches found, in which
    /// case the existing suggestion fetch is preserved).
    @State private var contactMatches: [Profile]? = nil
    /// Flipped true the first time the user is shown the
    /// contacts pre-permission popup in this session — whether
    /// they end up sharing, denying, or dismissing. After that,
    /// tapping "Find your people" opens the search sheet
    /// directly. Don't pester them with the same prompt.
    @State private var hasShownContactsPrompt = false
    /// True while we're requesting permission, reading contacts
    /// off the device, and asking the backend to match them.
    /// Overlays the Jaffa-style loader so the user has feedback
    /// during the gap between tapping Allow and the avatars
    /// repopulating.
    @State private var isResolvingContacts = false
    /// True when we should present the post-grant phone capture
    /// sheet — i.e. user just granted contacts permission and
    /// their own profile has no phone hash yet, so we ask them
    /// to add one (so contacts of theirs find them in reverse).
    @State private var showPhoneCapturePrompt = false

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1: Background
            AppPalette.groupedBackground.ignoresSafeArea()

            // Layer 2: Header — same z-ordering as the friends
            // feed (cards at zIndex 2 sit ABOVE the header at
            // zIndex 1). The content scrolls visually over the
            // logo position when the user scrolls down.
            feedHeader
                .zIndex(1)

            // Layer 3: Cards (above header)
            Group {
                // Lock the discovery surface for the duration of this
                // tab visit. Three independent guards in order: an
                // ever-shown flag (set the first time EmptyFollowingView
                // appears, immune to any state race), the explicit
                // .onAppear snapshot, and the live `isEmpty` fallback
                // for the very first body call before .onAppear fires.
                let showsDiscovery = everShownDiscovery
                    || (hasEvaluatedEntry ? discoveryLocked : store.followingIds.isEmpty)
                if showsDiscovery {
                    // No outer top padding — the scroll content
                    // extends behind the floating header (same as
                    // `feedList`). Internal top padding inside
                    // `EmptyFollowingView` keeps the hero visible
                    // below the header on first paint.
                    EmptyFollowingView(
                        onFindFriendsTap: {
                            if hasShownContactsPrompt {
                                Analytics.log("find_your_people_tapped_post_prompt")
                                showDiscover = true
                            } else {
                                hasShownContactsPrompt = true
                                showContactsPrompt = true
                                Analytics.log("contacts_prompt_shown")
                            }
                        },
                        onProfileTap: { selectedDiscoveryProfile = $0 },
                        seedProfiles: contactMatches
                    )
                    .onAppear { everShownDiscovery = true }
                } else if store.feedPosts.isEmpty {
                    emptyState
                } else {
                    feedList
                }
            }
            .zIndex(2)

            // Layer 4: Floating notification (top right, fades out on scroll)
            VStack {
                HStack {
                    Spacer()
                    floatingNotificationButton
                        .opacity(hasScrolled ? 0 : 1)
                        .scaleEffect(hasScrolled ? 0.3 : 1, anchor: .center)
                        .animation(.easeOut(duration: 0.12), value: hasScrolled)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, 12)
                Spacer()
            }
            .allowsHitTesting(!hasScrolled)
            .zIndex(3)

            // Contacts-resolving overlay. Sits above the hero so
            // the user has visible feedback during the iOS
            // permission alert + contact enumeration + backend
            // match round-trip. Dimmed background blocks input
            // until the request finishes.
            if isResolvingContacts {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    UploadLoaderView(size: 160)
                }
                .transition(.opacity)
                .zIndex(4)
            }

            // Layer 5: Floating search (bottom right, fades in on scroll)
            if !store.feedPosts.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        floatingSearchButton
                            .opacity(hasScrolled ? 1 : 0)
                            .scaleEffect(hasScrolled ? 1 : 0.3, anchor: .center)
                            .animation(.easeOut(duration: 0.12), value: hasScrolled)
                    }
                    .padding(.horizontal, 28)
                    // 16 (vs. favorites' 28) compensates for PFLV's nested layout chain.
                    .padding(.bottom, 16)
                }
                .allowsHitTesting(hasScrolled)
                .zIndex(4)
            }
        }
        .task {
            guard !hasRefreshedFeed else { return }
            hasRefreshedFeed = true
            await store.refreshFeed()
            await loadCounts()
            await loadVibes()
        }
        .onAppear {
            // Capture once per tab visit so live `followingIds`
            // changes mid-session don't reshape the screen.
            if !hasEvaluatedEntry {
                discoveryLocked = store.followingIds.isEmpty
                hasEvaluatedEntry = true
            }
        }
        .onChange(of: store.currentView) { _, newView in
            // Re-arm the per-visit evaluation guard so the next
            // `.onAppear` re-checks `followingIds.isEmpty` for a
            // first-load scenario. We intentionally do NOT reset
            // `everShownDiscovery` — once the user has landed on
            // the discovery surface in this app session, it stays
            // their feed for the whole session. No auto-transition
            // to the friends feed after they follow someone, even
            // across tab cycles. Clears only on app restart.
            if newView != .feed {
                hasEvaluatedEntry = false
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverView()
                .environment(store)
        }
        .alert("Find your friends on Yafa", isPresented: $showContactsPrompt) {
            Button("Share Contacts") {
                Analytics.log("contacts_prompt_share_tapped")
                Task { await handleContactsAccess() }
            }
            Button("Not now", role: .cancel) {
                Analytics.log("contacts_prompt_not_now_tapped")
                showDiscover = true
            }
        } message: {
            Text("We'll match your contacts to people who are already on Yafa so you can follow them.")
        }
        .sheet(isPresented: $showPhoneCapturePrompt) {
            PhoneCapturePromptView(
                onSubmit: { e164 in await savePhoneHash(e164) },
                onSkip: { Analytics.log("phone_capture_skipped") }
            )
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
            .roundedSheetBackground()
        }
        .fullScreenCover(item: $selectedDiscoveryProfile) { profile in
            UserProfileView(
                userId: profile.id,
                onDismiss: { selectedDiscoveryProfile = nil }
            )
            .environment(store)
        }
    }

    /// Feed posts excluding authors this user has blocked.
    private var visibleFeedPosts: [FeedPost] {
        store.feedPosts.filter { post in
            guard let authorId = post.authorId else { return true }
            return !store.blockedUserIds.contains(authorId)
        }
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.large) {
                Color.clear.frame(height: 0).id("feedTop")
                searchBar
                    .padding(.top, LayoutMetrics.feedTopInset)

                ForEach(visibleFeedPosts) { post in
                    FeedPostCard(
                        post: post,
                        likeCount: likeCounts[post.outfitId] ?? 0,
                        commentCount: commentCounts[post.outfitId] ?? 0,
                        isInitiallyLiked: myLikedOutfitIds.contains(post.outfitId),
                        onCommentCountChanged: { newCount in
                            commentCounts[post.outfitId] = newCount
                        },
                        onCartOpen: {
                            pendingScrollPostId = post.id
                        },
                        vibeCountInitial: vibeCounts[post.outfitId] ?? 0,
                        isVibedByMeInitial: vibedOutfitIds.contains(post.outfitId),
                        vibesRemainingThisWeek: $vibesRemainingThisWeek
                    )
                    .id(post.id)
                    .onPreferenceChange(CartBottomKey.self) { bottomY in
                        guard let bottomY, pendingScrollPostId == post.id else { return }
                        pendingScrollPostId = nil
                        let screenHeight = UIScreen.main.bounds.height
                        let tabBarTop = screenHeight - LayoutMetrics.tabBarHeight - LayoutMetrics.screenPadding
                        if bottomY > tabBarTop {
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                                proxy.scrollTo("cartBottom-\(post.id)", anchor: .init(x: 0.5, y: 0.88))
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .animation(.easeOut(duration: 0.3), value: store.feedPosts.count)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.screenPadding)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .named("feedScroll")).minY) { _, newY in
                            let scrolled = newY < -20
                            if scrolled != hasScrolled {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    hasScrolled = scrolled
                                }
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: "feedScroll")
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .contentMargins(.top, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable {
            await store.refreshFeed()
        }
        .onChange(of: store.feedScrollToTopTrigger) { _, _ in
            withAnimation { proxy.scrollTo("feedTop", anchor: .top) }
            Task {
                hasRefreshedFeed = false
                await store.refreshFeed()
                await loadCounts()
                await loadVibes()
            }
        }
        } // ScrollViewReader
    }

    private var searchBar: some View {
        Button {
            showDiscover = true
        } label: {
            HStack(spacing: LayoutMetrics.xxSmall) {
                AppIcon(glyph: .search, size: 14, color: AppPalette.textFaint)
                Text("Find your people")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        }
        .buttonStyle(SolidPressButtonStyle())
        .opacity(hasScrolled ? 0 : 1)
    }

    private var feedHeader: some View {
        HStack {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                store.selectedOutfitId = nil
                store.currentView = .list
            } label: {
                Group {
                    if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
                       let data = try? Data(contentsOf: logoURL),
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 34)
                            .colorMultiply(.black)
                            .opacity(0.82)
                    } else {
                        Text("YAFA")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textPrimary.opacity(0.82))
                    }
                }
            }
            .frame(minHeight: 44)
            .buttonStyle(SolidPressButtonStyle())

            Spacer()
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    private var floatingNotificationButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showsNotifications = true
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon(glyph: .bell, size: 16, color: AppPalette.iconPrimary)
                    .frame(width: 48, height: 48)
                    .appCircle()

                if store.unreadNotificationCount > 0 {
                    Text("\(store.unreadNotificationCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.uploadGlow.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .fill(Color.white.opacity(0.96))
                                )
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .shadow(color: AppPalette.uploadGlow.opacity(0.2), radius: 3, y: 1)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(SolidPressButtonStyle())
        .sheet(isPresented: $showsNotifications) {
            NotificationsPlaceholderSheet()
                .environment(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
    }

    private var floatingSearchButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showDiscover = true
        } label: {
            AppIcon(glyph: .search, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle(shadowRadius: 12, shadowY: 6)
        }
        .buttonStyle(SolidPressButtonStyle())
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.medium) {
            Spacer()

            VStack(spacing: LayoutMetrics.small) {
                AppIcon(glyph: .globe, size: 32, color: AppPalette.textMuted)

                Text("Your feed is empty")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                Text("Follow people to see their outfits here")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }

            Button {
                showDiscover = true
            } label: {
                HStack(spacing: 6) {
                    AppIcon(glyph: .search, size: 14, color: AppPalette.textPrimary)
                    Text("FIND YOUR PEOPLE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
                .frame(height: 48)
                .padding(.horizontal, 28)
                .appCapsule(shadowRadius: 8, shadowY: 4)
            }
            .buttonStyle(SolidPressButtonStyle())

            Spacer()
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    /// Drives the "Share Contacts" path of the pre-permission
    /// popup. Triggers the iOS system permission alert, fetches
    /// contacts on grant, asks the backend which ones are Yafa
    /// users, and stashes the matches in `contactMatches` —
    /// which the hero observes via `.onChange(of: seedProfiles)`
    /// and uses to repopulate its floating avatars.
    ///
    /// Fallbacks at every failure step land on the existing
    /// `DiscoverView` sheet so the user always reaches a way to
    /// find people, even if contacts are denied or no matches
    /// are found.
    private func handleContactsAccess() async {
        await MainActor.run { isResolvingContacts = true }

        let result = await ContactsService.requestAccess()
        guard result == .granted else {
            Analytics.log(
                "contacts_permission_denied",
                properties: ["reason": .string(String(describing: result))]
            )
            await MainActor.run {
                isResolvingContacts = false
                showDiscover = true
            }
            return
        }
        Analytics.log("contacts_permission_granted")

        let contacts: [ContactsService.DeviceContact]
        do {
            contacts = try await ContactsService.fetchAllContacts()
        } catch {
            Analytics.log("contacts_fetch_failed")
            await MainActor.run {
                isResolvingContacts = false
                showDiscover = true
            }
            return
        }

        let matches: [Profile]
        do {
            matches = try await ContactsService.findMatchingProfiles(from: contacts)
            Analytics.log(
                "contacts_match_completed",
                properties: [
                    "contact_count": .int(contacts.count),
                    "match_count": .int(matches.count),
                ]
            )
        } catch {
            Analytics.log(
                "contacts_match_failed",
                properties: ["contact_count": .int(contacts.count)]
            )
            matches = []
        }

        await MainActor.run {
            isResolvingContacts = false

            let needsPhone = store.currentProfile?.phoneIsSet != true

            if !matches.isEmpty {
                contactMatches = matches
            }

            // Sheet priority: phone capture wins over discover
            // (SwiftUI only presents one sheet at a time). User
            // can find more people by tapping "Find your people"
            // again — that goes straight to DiscoverView from
            // here on, since `hasShownContactsPrompt` is true.
            if needsPhone {
                Analytics.log("phone_capture_shown")
                showPhoneCapturePrompt = true
            } else if matches.isEmpty {
                showDiscover = true
            }
        }
    }

    /// Hashes the user-provided phone number and saves it on
    /// their profile so contact-matching by other users can
    /// find them. Called from the PhoneCapturePromptView's
    /// submit action.
    private func savePhoneHash(_ e164: String) async {
        guard let userId = store.userId else { return }
        let hash = PhoneNumber.sha256(e164)
        do {
            try await SocialService.updatePhoneHash(userId: userId, hash: hash)
            await MainActor.run {
                store.currentProfile?.phoneE164Hash = hash
                store.currentProfile?.phoneIsSet = true
            }
            Analytics.log("phone_capture_saved")
        } catch {
            Analytics.log("phone_capture_save_failed")
        }
    }

    /// Batch-load vibe state for the feed: per-outfit counts,
    /// which outfits the current user has already vibed, and
    /// the user's remaining quota for this ISO week. Runs in
    /// parallel — three independent reads.
    private func loadVibes() async {
        let outfitIds = store.feedPosts.map(\.outfitId)
        guard let userId = store.userId else { return }

        async let countsTask = VibesService.vibeCounts(outfitIds: outfitIds)
        async let vibedTask = VibesService.vibedOutfitIds(currentUserId: userId)
        async let remainingTask = VibesService.remainingThisWeek()

        let counts = await countsTask
        let vibed = await vibedTask
        let remaining = await remainingTask

        await MainActor.run {
            vibeCounts = counts
            vibedOutfitIds = vibed
            vibesRemainingThisWeek = remaining
        }
    }

    private func loadCounts() async {
        let outfitIds = store.feedPosts.map(\.outfitId)
        guard !outfitIds.isEmpty, let userId = store.userId else { return }

        async let likesTask = try? SocialService.getLikeCounts(outfitIds: outfitIds)
        async let commentsTask = try? SocialService.getCommentCounts(outfitIds: outfitIds)
        async let myLikesTask = try? SocialService.getLikedOutfitIds(userId: userId)

        let likes = await likesTask ?? [:]
        let comments = await commentsTask ?? [:]
        let myLikes = await myLikesTask ?? []

        await MainActor.run {
            likeCounts = likes
            commentCounts = comments
            myLikedOutfitIds = myLikes
        }
    }
}

struct FeedPostCard: View {
    let post: FeedPost
    var likeCount: Int
    var commentCount: Int
    var isInitiallyLiked: Bool
    var onCommentCountChanged: ((Int) -> Void)?
    var onCartOpen: (() -> Void)?
    /// When set, the card renders in "overlay" mode: a close button
    /// replaces the in-header weather pill (top-right of the header)
    /// and the weather pill, if any, floats at the top center of the
    /// card instead. Used by the profile-grid floating overlay.
    var onClose: (() -> Void)? = nil
    /// Suppress the Pro-specific chrome (frosty blue rim overlay, blue
    /// shadow, holo shader) while keeping the PRO badge in the header.
    /// Used by the profile-grid floating overlay so Pro users still
    /// look "Pro" but don't get the double-stroke from the rim
    /// overlapping appCard's gray border.
    var hideProChrome: Bool = false
    /// When true, renders a compact Follow / Following pill in the
    /// card header so users can follow without leaving the feed.
    /// Used by the empty-following Community section.
    var showFollowAction: Bool = false
    /// Initial vibe count + whether the current user vibed this
    /// outfit. Loaded in batch by the feed list and passed in
    /// as initial values; local state overrides after the user
    /// taps so the UI updates optimistically.
    var vibeCountInitial: Int = 0
    var isVibedByMeInitial: Bool = false
    /// User's remaining-this-week vibe quota. Shared across all
    /// cards in the feed via a Binding to the parent list.
    var vibesRemainingThisWeek: Binding<Int>?
    @Environment(OutfitStore.self) private var store
    @State private var showComments = false
    @State private var showUserProfile = false
    @State private var showLikers = false
    @State private var likeToggled = false
    @State private var localLikeAdjustment: Int = 0
    @State private var localCommentCount: Int?
    @State private var cartOpen = false
    @State private var fetchedOutfit: Outfit?
    @State private var localVibeCount: Int? = nil
    @State private var localIsVibedByMe: Bool? = nil
    @State private var showVibers = false
    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: BlockCandidate?

    // Use local store first, then prefetch cache, then per-card fetch
    private var outfit: Outfit? {
        store.outfitById[post.outfitId] ?? store.feedOutfitCache[post.outfitId] ?? fetchedOutfit
    }

    /// Pro-chrome elements (holo, frosty rim, blue shadow, gyro tilt)
    /// gate on this. PRO badge in the header still uses
    /// `post.isAuthorPro` directly, so identity stays intact when
    /// `hideProChrome` is set.
    private var showsProChrome: Bool {
        post.isAuthorPro == true && !hideProChrome
    }

    @State private var cardVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            cardHeader

            if let outfit {
                outfitContent(outfit)
            }

            if metadataLabels.isEmpty == false {
                metadataRow
            }

            if let caption = outfit?.caption ?? post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cardActions
        }
        .padding(LayoutMetrics.medium)
        .holoCard(active: showsProChrome)
        .appCard()
        .overlay {
            if showsProChrome {
                // Frosty blue rim — slightly thicker plain stroke instead
                // of stroke+blur. The blur was forcing an offscreen pass
                // per card; this version is visually nearly identical
                // and avoids the extra render target.
                RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                    .stroke(Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.45), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: showsProChrome ? Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.45) : .clear,
            radius: 14,
            y: 0
        )
        .proCardTilt(active: showsProChrome)
        .opacity(cardVisible ? 1 : 0)
        .scaleEffect(cardVisible ? 1 : 0.96)
        .onChange(of: outfit) { _, newOutfit in
            guard newOutfit != nil, !cardVisible else { return }
            withAnimation(.easeOut(duration: 0.3)) { cardVisible = true }
        }
        .onAppear {
            // Animate the fade-in even when outfit is already
            // resolved at appear time (i.e., cache hit). Previously
            // this set `cardVisible = true` without `withAnimation`,
            // which meant cache-hit cards snapped on while
            // cache-miss cards (where `.onChange(of: outfit)` fires
            // later) faded in. That asymmetry was visible on the
            // community section of the empty-following feed, where
            // outfits are typically pre-cached — cards there
            // popped in without the friends-feed fade. Animating
            // both paths makes the entry consistent.
            guard outfit != nil, !cardVisible else { return }
            withAnimation(.easeOut(duration: 0.3)) { cardVisible = true }
        }
        .sheet(isPresented: $showLikers) {
            LikersSheet(outfitId: post.outfitId)
        }
        .sheet(isPresented: $showVibers) {
            VibersListSheet(source: .outfit(post.outfitId))
                .environment(store)
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
        .sheet(isPresented: $showComments, onDismiss: {
            Task {
                let counts = try? await SocialService.getCommentCounts(outfitIds: [post.outfitId])
                let newCount = counts?[post.outfitId] ?? displayCommentCount
                await MainActor.run {
                    localCommentCount = newCount
                }
                onCommentCountChanged?(newCount)
            }
        }) {
            CommentsSheet(outfitId: post.outfitId)
                .environment(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .roundedSheetBackground()
        }
        .task(id: post.outfitId) {
            // If outfit isn't in local store (another user's outfit), fetch from Supabase
            guard store.outfitById[post.outfitId] == nil else { return }
            if let remote = await ContentSource.getPublicOutfit(id: post.outfitId) {
                await MainActor.run { fetchedOutfit = remote }
            }
        }
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.985)
                .opacity(phase.isIdentity ? 1 : 0.96)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            Button {
                if post.authorId != nil { showUserProfile = true }
            } label: {
                HStack(spacing: LayoutMetrics.xSmall) {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(post.authorName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)
                            if post.isAuthorPro == true {
                                Text("PRO")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .tracking(1)
                                    .foregroundStyle(AppPalette.pageBackground)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(AppPalette.textSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        Text(timestampLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
            }
            .buttonStyle(SolidPressButtonStyle())
            .fullScreenCover(isPresented: $showUserProfile) {
                if let authorId = post.authorId {
                    UserProfileView(userId: authorId, onDismiss: { showUserProfile = false })
                        .environment(store)
                }
            }

            Spacer()

            if showFollowAction,
               let authorId = post.authorId,
               authorId != store.userId {
                inlineFollowPill(authorId: authorId)
            }

            // In overlay mode the weather sits right next to the X
            // (right side). In feed mode there's no X — weather hugs
            // the right by itself. The community section suppresses
            // weather entirely so the follow pill stands alone as the
            // primary action on each card.
            if !showFollowAction,
               let weather = outfit?.weather,
               weather.condition.isEmpty == false {
                WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(AppPalette.cardFill)
                        )
                        .overlay(
                            Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                        )
                }
                .buttonStyle(SolidPressButtonStyle())
            }

            if let authorId = post.authorId, authorId != store.userId {
                Menu {
                    Button {
                        reportTarget = ReportTarget(
                            contentType: "outfit",
                            reportedUserId: authorId,
                            reportedOutfitId: post.outfitId,
                            displayName: post.authorName
                        )
                    } label: { Label("Report post", systemImage: "flag") }
                    Button(role: .destructive) {
                        blockCandidate = BlockCandidate(userId: authorId, name: post.authorName)
                    } label: { Label("Block \(post.authorName)", systemImage: "hand.raised") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
                .environment(store)
        }
        .confirmationDialog(
            blockCandidate.map { "Block \($0.name)?" } ?? "Block user?",
            isPresented: Binding(
                get: { blockCandidate != nil },
                set: { if !$0 { blockCandidate = nil } }
            ),
            presenting: blockCandidate
        ) { candidate in
            Button("Block", role: .destructive) { store.blockUser(candidate.userId) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("You won't see \(candidate.name)'s posts or comments anymore.")
        }
    }

    private var profileAvatar: some View {
        AvatarView(
            url: post.avatarUrl,
            initial: String(post.authorName.prefix(1)).uppercased()
        )
    }

    /// Compact follow toggle. Becomes a muted "FOLLOWING" capsule
    /// once tapped so users can still un-follow without leaving the
    /// feed — matches the casing of the profile-sheet follow button.
    private func inlineFollowPill(authorId: UUID) -> some View {
        let isFollowing = store.followingIds.contains(authorId)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.18)) {
                store.toggleFollow(authorId)
            }
        } label: {
            Text(isFollowing ? "FOLLOWING" : "FOLLOW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(isFollowing ? AppPalette.textMuted : AppPalette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .appCapsule(shadowRadius: 2, shadowY: 1)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func outfitContent(_ outfit: Outfit) -> some View {
        let isRotatable = outfit.frameCount > 1
        return RotatableOutfitImage(
            outfit: outfit,
            height: 292,
            draggable: isRotatable,
            preloadFullSequenceOnAppear: isRotatable
        )
        .frame(maxWidth: .infinity)
    }

    private var is3DOutfit: Bool {
        (outfit?.frameCount ?? 0) > 1
    }

    private var metadataLabels: [String] {
        [
            post.height.map { "Height \($0)" },
            post.size.map { "Size \($0)" },
        ]
        .compactMap { $0 }
    }

    private var metadataRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LayoutMetrics.xxSmall) {
                ForEach(metadataLabels, id: \.self) { label in
                    metadataChip(label)
                }
            }
        }
    }

    private func metadataChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .padding(.vertical, 7)
            .appCapsule(shadowRadius: 0, shadowY: 0)
    }

    private var displayLiked: Bool {
        likeToggled ? !isInitiallyLiked : isInitiallyLiked
    }

    private var displayLikeCount: Int {
        max(0, likeCount + localLikeAdjustment)
    }

    private var displayCommentCount: Int {
        localCommentCount ?? commentCount
    }

    private var vibeCountBinding: Binding<Int> {
        Binding(
            get: { localVibeCount ?? vibeCountInitial },
            set: { localVibeCount = $0 }
        )
    }

    private var isVibedByMeBinding: Binding<Bool> {
        Binding(
            get: { localIsVibedByMe ?? isVibedByMeInitial },
            set: { localIsVibedByMe = $0 }
        )
    }

    /// Bridge for the case where the host doesn't provide a
    /// shared quota binding (e.g. preview / profile-grid
    /// overlay). Falls back to a local @State that's never
    /// shared — quota will desync from the rest of the app but
    /// the card still functions.
    @State private var fallbackVibesRemaining: Int = 3
    private var vibesRemainingBinding: Binding<Int> {
        vibesRemainingThisWeek ?? $fallbackVibesRemaining
    }

    private var hasProducts: Bool {
        outfit?.products?.isEmpty == false
    }

    /// True when the current user authored this post — used to
    /// hide the vibe button on your own outfits (you can't
    /// vibe yourself; the server blocks it via the RPC's
    /// `self_vibe` error, but no button = no confusion).
    private var isOwnPost: Bool {
        guard let myId = store.userId,
              let authorId = post.authorId else { return false }
        return myId == authorId
    }

    private var vibeButtonInline: some View {
        VibeButton(
            outfitId: post.outfitId,
            vibeCount: vibeCountBinding,
            isVibedByMe: isVibedByMeBinding,
            remainingThisWeek: vibesRemainingBinding
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    if vibeCountBinding.wrappedValue > 0 {
                        showVibers = true
                    }
                }
        )
    }

    private var cardActions: some View {
        VStack(spacing: 0) {
            HStack(spacing: LayoutMetrics.xxSmall) {
                actionButton(
                    icon: .heart,
                    count: displayLikeCount,
                    filled: displayLiked,
                    isActive: displayLiked,
                    longPressAction: displayLikeCount > 0 ? { showLikers = true } : nil
                ) {
                    guard let userId = store.userId else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        let wasLiked = displayLiked
                        likeToggled.toggle()
                        localLikeAdjustment += wasLiked ? -1 : 1
                        Task {
                            if wasLiked {
                                try? await SocialService.unlikeOutfit(userId: userId, outfitId: post.outfitId)
                            } else {
                                try? await SocialService.likeOutfit(userId: userId, outfitId: post.outfitId)
                            }
                        }
                    }
                }
                actionButton(
                    icon: .comment,
                    count: displayCommentCount
                ) {
                    showComments = true
                }
                actionButton(
                    icon: .bookmark,
                    filled: store.savedIds.contains(post.outfitId),
                    isActive: store.savedIds.contains(post.outfitId)
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.toggleSave(post.outfitId)
                    }
                }

                if hasProducts {
                    actionButton(
                        icon: .cart,
                        isActive: cartOpen
                    ) {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                            cartOpen.toggle()
                        }
                        if cartOpen {
                            onCartOpen?()
                        }
                    }
                }

                Spacer()

                // Vibes — bottom-right reaction. Hidden on the
                // user's own posts (you can't vibe yourself —
                // the server blocks it, and showing a tappable
                // button that always errors would be confusing).
                if !isOwnPost {
                    vibeButtonInline
                }
            }
            .padding(.top, LayoutMetrics.xxxSmall)

            if cartOpen, let products = outfit?.products, !products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                            Button {
                                ProductShopLink.open(product)
                            } label: {
                                VStack(spacing: 6) {
                                    ProductImageView(product: product, size: 56, cornerRadius: 14)
                                    Text("BUY")
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(1.1)
                                        .foregroundStyle(AppPalette.textMuted)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color.white.opacity(0.45)))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
                                }
                            }
                            .buttonStyle(SolidPressButtonStyle())
                            .opacity(cartOpen ? 1 : 0)
                            .scaleEffect(cartOpen ? 1 : 0.85)
                            .animation(
                                .timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
                                    .delay(0.1 + Double(index) * 0.07),
                                value: cartOpen
                            )
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.medium)
                    .padding(.top, LayoutMetrics.xxSmall)
                    .padding(.bottom, LayoutMetrics.xxxSmall)
                }
                .padding(.horizontal, -LayoutMetrics.medium)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                GeometryReader { geo in
                    Color.clear
                        .preference(key: CartBottomKey.self, value: geo.frame(in: .global).maxY)
                }
                .frame(height: 0)
                .id("cartBottom-\(post.id)")
            }
        }
    }

    private var timestampLabel: String {
        RelativeTime.label(from: post.publishedDate ?? outfit?.parsedDate)
    }

    // Shop-link resolution moved to `ProductShopLink.open(_:)`.

    private func actionButton(
        icon: AppIconGlyph,
        count: Int? = nil,
        filled: Bool = false,
        isActive: Bool = false,
        longPressAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                AppIcon(
                    glyph: icon,
                    size: 14,
                    color: isActive ? AppPalette.iconActive : AppPalette.iconPrimary,
                    filled: filled
                )
                .frame(width: 40, height: 40)
                .appCircle(shadowRadius: 0, shadowY: 0)
                .scaleEffect(isActive ? 0.96 : 1)

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(minWidth: 16, minHeight: 16)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(Circle().fill(Color.white.opacity(0.96)))
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(SolidPressButtonStyle())
        .modifier(LongPressIfPresent(action: longPressAction))
        .frame(minWidth: LayoutMetrics.touchTarget, minHeight: LayoutMetrics.touchTarget)
    }
}

private struct CartBottomKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct LongPressIfPresent: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in action() }
            )
        } else {
            content
        }
    }
}



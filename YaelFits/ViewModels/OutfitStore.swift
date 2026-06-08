import SwiftUI

enum AppView: String, CaseIterable {
    case list = "List"
    case calendar = "Calendar"
    case feed = "Feed"
    case upload = "Upload"
    case profile = "Profile"
}

@Observable
class OutfitStore {
    var userId: UUID?
    var outfits: [Outfit] = []
    var feedPosts: [FeedPost] = []
    /// Multi-job generation queue. Marked `@ObservationIgnored` so
    /// `@Observable` doesn't try to wrap it as a computed property
    /// (which would break `lazy`). SwiftUI views still re-render
    /// on queue mutations because `GenerationQueue` is itself
    /// `@Observable`. `lazy` so it isn't constructed until the new
    /// flow actually needs it — avoids touching the
    /// closure-captured `outfits` / `userId` during sign-out or
    /// before the store has loaded.
    @ObservationIgnored
    lazy var generationQueue: GenerationQueue = {
        let q = GenerationQueue(
            nextOutfitNumber: { [weak self] in
                guard let self else { return 1 }
                // Account for *both* committed outfits in the archive
                // AND in-flight queue jobs. Without the queue check, two
                // rapid enqueues would each land on the same outfitNum
                // (because the first hasn't committed yet) → both
                // PipelineJobs share id "outfit-N" → ForEach collapses
                // them into one pill + one placeholder.
                let archiveMax = self.outfits.compactMap(\.outfitNumber).max() ?? 0
                let queueMax = (self.generationQueue.activeJobs + self.generationQueue.waitingJobs)
                    .map(\.outfitNum).max() ?? 0
                let base = max(archiveMax, queueMax)
                guard let userId = self.userId else { return base + 1 }
                return max(base + 1, LocalOutfitStore.shared.nextOutfitNum(userId: userId))
            }
        )
        // Wire orchestration: any newly active job (fresh enqueue or
        // promoted from waiting) kicks off the fake pipeline. Swap
        // to the real orchestrator when step 8 lands.
        q.onJobBecameActive = { [weak self] job in
            self?.generationOrchestrator.start(job)
        }
        return q
    }()

    /// Production orchestrator — runs each `PipelineJob` through
    /// the real Bria → fork → Kling → poll → review pipeline. The
    /// fake variant (`FakeGenerationOrchestrator`) is still on disk
    /// and can be swapped in here for UI iteration without burning
    /// real credits.
    @ObservationIgnored
    lazy var generationOrchestrator: RealGenerationOrchestrator = RealGenerationOrchestrator(
        queue: generationQueue,
        userIdProvider: { [weak self] in self?.userId },
        onAcceptOutfit: { [weak self] outfit in self?.addOutfit(outfit) },
        onPublishOutfit: { [weak self] outfit in self?.publishOutfitToFeed(outfit) }
    )
    var currentView: AppView = .list
    var useFahrenheit: Bool = (UserDefaults.standard.object(forKey: "preferredTempUnitFahrenheit") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(useFahrenheit, forKey: "preferredTempUnitFahrenheit")
        }
    }
    var likedIds: Set<String> = []
    var savedIds: Set<String> = []
    var followingIds: Set<UUID> = []
    var isLoading: Bool = true
    var selectedOutfitId: String?
    var centeredListOutfitId: String?
    var pendingCalendarScrollOutfitId: String?
    /// Symmetric to pendingCalendarScrollOutfitId — when switching from
    /// calendar back to list, OutfitGridView reads this on appearance
    /// and scrolls so the named outfit is centered. Lets the user land
    /// on the same outfit they were viewing in the calendar.
    var pendingListScrollOutfitId: String?
    var listOutfitFrames: [String: CGRect] = [:]
    var calendarOutfitFrames: [String: CGRect] = [:]
    var listOutfitFrameIndices: [String: Int] = [:]
    /// The single outfit being "carried" between list and calendar via
    /// matchedGeometryEffect. Set before the view switch, cleared after
    /// the animation completes. Only this outfit's cell animates its
    /// position between the two views — all other cells just opacity-
    /// fade with the parent view transition (so non-anchor cells don't
    /// fly off-screen toward their destination position).
    var transitionAnchorOutfitId: String?
    /// During a list↔calendar transition, holds the source-anchor
    /// cell's currently-displayed frame index so the destination-
    /// anchor cell can sync to the same frame for the duration of
    /// the morph (no visual snap mid-transition). Cleared when
    /// `transitionAnchorOutfitId` clears. Independent of
    /// `listOutfitFrameIndices` — does NOT persist scrub state
    /// across views.
    var transitionAnchorFrameIndex: Int?
    /// Cells broadcast their currently-displayed frame index here as
    /// the user scrubs. Used by `switchView` to capture the source
    /// anchor's frame at transition start. Writes are per-frame
    /// during scrub but no view body reads this dict, so writes
    /// don't trigger re-renders.
    var currentDisplayedFrame: [String: Int] = [:]
    var isCarouselOpen = false
    /// Set to true while the carousel's detail card is in edit mode.
    /// RootView's top bar reads this to hide the X dismiss button
    /// and the temperature toggle in that state — the card grows
    /// taller in edit mode (and shifts up further when the keyboard
    /// appears), so it visually covers that strip and they'd
    /// otherwise show through the card's translucent material. In
    /// the resting expanded state we keep them visible so the user
    /// can still see the weather + dismiss the carousel.
    var isCarouselCardEditing = false
    /// Set to true once the in-page grid/calendar toggle on the
    /// profile-home screen has scrolled up to the top-bar threshold.
    /// RootView's top bar reads this to swap settings + share for the
    /// pinned toggle; OutfitGridView reads it to fade the in-page
    /// copy so it doesn't render twice. Reset to false when the
    /// section scrolls back below the threshold or when leaving the
    /// list view.
    var archiveTogglePinned = false
    /// Increment to ask `OutfitGridView` to scroll back to the top
    /// (Profile tab tap while already on the archive). Same trigger
    /// pattern as `feedScrollToTopTrigger`.
    var archiveScrollToTopTrigger = 0
    /// Increment to ask the active carousel host (archive or other-
    /// user profile) to dismiss. Used by the global X button that
    /// replaces the Yafa logo while the carousel is open, since
    /// that button lives in `RootView` and can't reach the host's
    /// internal `dismissCarousel()` directly.
    var carouselDismissTrigger = 0
    var unreadNotificationCount = 0
    var feedScrollToTopTrigger = 0
    /// Increment to ask `RootView` to open the floating generation
    /// picker. Used by the archive empty state's "Create your first
    /// outfit" button — the picker lives in `RootView`, so a trigger
    /// counter is the cleanest cross-view bridge.
    var generationPickerOpenTrigger = 0

    func beginSession(for userId: UUID) {
        UserDefaults.standard.removeObject(forKey: "lastSeenNotificationsAt")
        let isSwitchingUsers = self.userId != nil && self.userId != userId
        self.userId = userId

        guard isSwitchingUsers else {
            isLoading = true
            return
        }

        outfits = []
        feedPosts = []
        likedIds = []
        savedIds = []
        followingIds = []
        isLoading = true
        selectedOutfitId = nil
        centeredListOutfitId = nil
        pendingCalendarScrollOutfitId = nil
        pendingListScrollOutfitId = nil
        listOutfitFrames = [:]
        calendarOutfitFrames = [:]
        listOutfitFrameIndices = [:]
        transitionAnchorOutfitId = nil
        transitionAnchorFrameIndex = nil
        currentDisplayedFrame = [:]
        isCarouselOpen = false
        unreadNotificationCount = 0
        currentProfile = nil
        currentAvatarImage = nil
        currentAvatarCutoutImage = nil
        currentCreditBalance = nil
        feedOutfitCache = [:]
    }

    func resetForSignedOutState() {
        userId = nil
        outfits = []
        feedPosts = []
        likedIds = []
        savedIds = []
        followingIds = []
        isLoading = false
        selectedOutfitId = nil
        centeredListOutfitId = nil
        pendingCalendarScrollOutfitId = nil
        pendingListScrollOutfitId = nil
        listOutfitFrames = [:]
        calendarOutfitFrames = [:]
        listOutfitFrameIndices = [:]
        transitionAnchorOutfitId = nil
        transitionAnchorFrameIndex = nil
        currentDisplayedFrame = [:]
        isCarouselOpen = false
        unreadNotificationCount = 0
        currentProfile = nil
        currentAvatarImage = nil
        currentAvatarCutoutImage = nil
        currentCreditBalance = nil
        feedOutfitCache = [:]
    }

    /// Computes the unread-notification badge count by counting
    /// new likes, comments, vibes, follows, and any 5-vibe
    /// milestones the user crossed since `lastSeen`.
    ///
    /// Queries fire in two parallel tiers via `async let`:
    ///   Tier 1: user's outfit IDs + new follows (independent)
    ///   Tier 2: likes/comments/vibes/milestones (all need
    ///           Tier 1's outfit IDs)
    /// Each Supabase request is an independent HTTP/2 stream so
    /// the tiered structure collapses 7 sequential round-trips
    /// into 2 tiers of parallel queries.
    func refreshUnreadNotificationCount() async {
        guard let userId else { return }
        let lastSeen = NotificationReadState.lastSeenDate(for: userId)
        let since = ISO8601DateFormatter().string(from: lastSeen)

        struct IdRow: Decodable { let id: String }
        struct OutfitIdRow: Decodable {
            let outfitId: String
            enum CodingKeys: String, CodingKey { case outfitId = "outfit_id" }
        }
        struct VibeRow: Decodable {
            let outfitId: String
            let createdAt: String
            enum CodingKeys: String, CodingKey {
                case outfitId = "outfit_id"
                case createdAt = "created_at"
            }
        }
        struct FollowIdRow: Decodable { let follower_id: String }

        // Tier 1: user's outfit IDs + new follows.
        // The follows query doesn't need outfit IDs at all; it
        // can race the outfits-lookup.
        async let userOutfitsResult: [IdRow] = supabase
            .from("outfits")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value
        async let followsResult: [FollowIdRow] = supabase
            .from("follows")
            .select("follower_id")
            .eq("following_id", value: userId.uuidString)
            .neq("follower_id", value: userId.uuidString)
            .gt("created_at", value: since)
            .execute()
            .value

        let userOutfitIds = ((try? await userOutfitsResult) ?? []).map(\.id)
        let follows = (try? await followsResult) ?? []

        var count = follows.count

        // Tier 2: all five outfit-scoped queries fire together.
        if !userOutfitIds.isEmpty {
            async let likesResult: [OutfitIdRow] = supabase
                .from("likes")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .gt("created_at", value: since)
                .execute()
                .value
            async let commentsResult: [OutfitIdRow] = supabase
                .from("comments")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .gt("created_at", value: since)
                .execute()
                .value
            // Vibes count toward the unread badge the same way
            // likes do. Each vibe = one notification row.
            async let recentVibesResult: [VibeRow] = supabase
                .from("vibes")
                .select("outfit_id, created_at")
                .in("outfit_id", values: userOutfitIds)
                .neq("giver_id", value: userId.uuidString)
                .gt("created_at", value: since)
                .execute()
                .value
            // Free-gen-earned milestones: every 5th lifetime vibe
            // received is its own notification. Compare
            // milestones-now vs milestones-before to find unread.
            // Per-user vibe rows are bounded by the 3/week quota
            // so these full-history queries stay light.
            async let allVibesResult: [OutfitIdRow] = supabase
                .from("vibes")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("giver_id", value: userId.uuidString)
                .execute()
                .value
            async let vibesBeforeSinceResult: [OutfitIdRow] = supabase
                .from("vibes")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("giver_id", value: userId.uuidString)
                .lte("created_at", value: since)
                .execute()
                .value

            let likes = (try? await likesResult) ?? []
            let comments = (try? await commentsResult) ?? []
            let recentVibes = (try? await recentVibesResult) ?? []
            let allVibes = (try? await allVibesResult) ?? []
            let vibesBeforeSince = (try? await vibesBeforeSinceResult) ?? []

            count += likes.count
            count += comments.count
            count += recentVibes.count

            let milestonesNow = allVibes.count / 5
            let milestonesBefore = vibesBeforeSince.count / 5
            count += max(0, milestonesNow - milestonesBefore)
        }

        let finalCount = count
        await MainActor.run {
            guard self.userId == userId else { return }
            unreadNotificationCount = finalCount
        }
    }
    var hasPlayedInitialListEntrance = false
    var currentProfile: Profile?
    /// In-memory cache of the current user's avatar UIImage,
    /// loaded once and reused across tab switches so the profile
    /// page renders the photo instantly on return instead of
    /// flashing the gradient-initial fallback while AsyncImage
    /// re-resolves the URL. Cleared on sign-out + when the user
    /// picks a new photo (the picker assigns the freshly-cropped
    /// image here so the header shows the new pixels immediately).
    var currentAvatarImage: UIImage?
    /// In-memory cache of the current user's bust cutout PNG.
    /// Same rationale as `currentAvatarImage` — survives view
    /// recreation so the bust header renders from RAM on tab
    /// return. The cutout file is bigger than the regular
    /// avatar (PNG with alpha) so the network round-trip it
    /// avoids is the longest of the three avatar loads.
    var currentAvatarCutoutImage: UIImage?
    /// Latest credit balance (free monthly + paid non-expiring +
    /// optional reset timestamp). Cached on the store so every
    /// surface that shows credits — the settings chip, the
    /// paywall's balance display, the (future) header pill — reads
    /// from one reactive source. Updated by:
    ///   * Settings page on appear (initial hydration).
    ///   * Paywall on successful purchase (so settings auto-
    ///     refreshes the next time you open it without needing
    ///     to re-fetch from the server).
    var currentCreditBalance: CreditService.Balance?
    var feedOutfitCache: [String: Outfit] = [:]

    var outfitById: [String: Outfit] {
        // Use uniquingKeysWith (last-write-wins) instead of uniqueKeysWithValues
        // so a duplicate id doesn't crash the feed render. Duplicates can occur
        // briefly when addOutfit appends a freshly-accepted outfit whose id is
        // already in self.outfits from cache or a prior load.
        Dictionary(outfits.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    var archiveOutfits: [Outfit] {
        outfits.filter { !$0.id.hasSuffix("-public") }
    }

    var sortedOutfits: [Outfit] {
        // Newest first (Instagram-style). Outfit numbers increment
        // monotonically as the user uploads — see
        // `LocalOutfitStore.nextOutfitNum` — so descending order
        // surfaces the most recent fit at the top of the grid.
        archiveOutfits.sorted { a, b in
            (a.outfitNumber ?? 0) > (b.outfitNumber ?? 0)
        }
    }

    func loadData() async {
        guard let userId else {
            isLoading = false
            return
        }

        // Load from cache or bundled + local outfits — instant, no network
        let cached = LocalCache.loadOutfits(userId: userId)
        let cachedFeed = LocalCache.loadFeedPosts(userId: userId)

        // Bundled outfits belong to Yael's account only.
        // Other users start with an empty archive and upload their own.
        let isOwnerAccount = userId.uuidString.lowercased() == AppConfig.archiveOwnerUserId
        let bundled = isOwnerAccount ? ContentSource.getBundledOutfits() : []

        let base: [Outfit]
        if let cached {
            let cachedIds = Set(cached.map(\.id))
            let newFromBundled = bundled.filter { !cachedIds.contains($0.id) }
            base = cached + newFromBundled
        } else {
            base = bundled
        }
        // Strip locally-tracked outfits that have no local frame and
        // no remote_base_url before merging — without this, orphans
        // (failed uploads, deleted Supabase rows) keep rendering as
        // blank cells.
        LocalOutfitStore.shared.pruneOrphanedOutfits(userId: userId)
        let local = ContentSource.getLocalOutfits(userId: userId)
        let baseIds = Set(base.map(\.id))
        let uniqueLocal = local.filter { !baseIds.contains($0.id) }
        // Stamp localOwnerUserId on every outfit owned by this user
        // (i.e. everything except bundled). Supabase doesn't store
        // localOwnerUserId, so cached rows come back with nil and
        // FrameLoader can't resolve the local frame path.
        let bundledIds = Set(bundled.map(\.id))
        let stamped: (Outfit) -> Outfit = { outfit in
            guard !bundledIds.contains(outfit.id), outfit.localOwnerUserId == nil else { return outfit }
            var o = outfit
            o.localOwnerUserId = userId.uuidString
            return o
        }
        let instant = (base + uniqueLocal).map(stamped)
        let instantFeed = cachedFeed ?? ContentSource.getBundledFeed()
        let sorted = instant.sorted { ($0.outfitNumber ?? 0) < ($1.outfitNumber ?? 0) }

        if !sorted.isEmpty {
            await FrameLoader.shared.preloadFullSequences(for: Array(sorted.prefix(9)))
        }

        await MainActor.run {
            guard self.userId == userId else { return }
            self.outfits = instant
            self.feedPosts = instantFeed
            self.isLoading = false
        }

        if !sorted.isEmpty {
            Task.detached(priority: .utility) {
                await FrameLoader.shared.preloadFirstFrames(outfits: Array(sorted.prefix(12)))
            }
        }

        // Refresh feed in background — includes user's own public outfits + followed users
        Task.detached(priority: .utility) {
            guard self.userId == userId else { return }
            await self.refreshFeed()
        }

        // Save fresh Supabase data to cache for next launch — don't update live UI.
        // Preserve user-curated metadata (products/tags/caption) when fresh drops it.
        Task.detached(priority: .utility) {
            let fresh = await ContentSource.getAllOutfits(userId: userId)
            if !fresh.isEmpty {
                let existing = LocalCache.loadOutfits(userId: userId) ?? []

                // Same defensive check as refreshOutfits: if fresh has zero products
                // but the cache had products, the join probably failed — skip overwrite.
                let freshHasAnyProducts = fresh.contains { !($0.products ?? []).isEmpty }
                let cacheHasAnyProducts = existing.contains { !($0.products ?? []).isEmpty }
                if !freshHasAnyProducts && cacheHasAnyProducts {
                    return
                }

                let existingById = Dictionary(existing.map { ($0.id, $0) },
                                              uniquingKeysWith: { a, _ in a })
                let merged = fresh.map { outfit -> Outfit in
                    guard let cached = existingById[outfit.id] else { return outfit }
                    var preserved = outfit
                    if (outfit.products ?? []).isEmpty && !(cached.products ?? []).isEmpty {
                        preserved.products = cached.products
                    }
                    if (outfit.tags ?? []).isEmpty && !(cached.tags ?? []).isEmpty {
                        preserved.tags = cached.tags
                    }
                    if (outfit.caption ?? "").isEmpty && !(cached.caption ?? "").isEmpty {
                        preserved.caption = cached.caption
                    }
                    if (outfit.location ?? "").isEmpty, let cachedLocation = cached.location, !cachedLocation.isEmpty {
                        preserved.location = cachedLocation
                    }
                    return preserved
                }
                LocalCache.saveOutfits(merged, userId: userId)

                // Reconcile LocalOutfitStore with Supabase: drop local
                // entries that no longer exist server-side. Compare
                // against the pure-Supabase fetch (getUserOutfits) —
                // NOT getAllOutfits, which re-merges local entries in
                // and would let orphans survive forever.
                let supabaseOnly = await ContentSource.getUserOutfits(userId: userId)
                let serverIds = Set(supabaseOnly.map(\.id))
                LocalOutfitStore.shared.pruneOutfits(notIn: serverIds, userId: userId)

                // Update in-memory list too so removed outfits drop
                // out of the grid this session without needing a
                // relaunch. `merged` was built from a pre-prune
                // snapshot of getAllOutfits (which includes local
                // entries) — filter it down to Supabase rows plus
                // bundled so orphan cells don't render blank.
                let isOwnerAccount = userId.uuidString.lowercased() == AppConfig.archiveOwnerUserId
                let bundled = isOwnerAccount ? ContentSource.getBundledOutfits() : []
                let bundledIds = Set(bundled.map(\.id))
                // Read post-prune LocalOutfitStore so in-flight uploads
                // (saved locally but Supabase row hasn't landed yet)
                // aren't filtered out of the in-memory list.
                let postPruneLocalIds = Set(ContentSource.getLocalOutfits(userId: userId).map(\.id))
                let keptMerged = merged.filter {
                    serverIds.contains($0.id) || bundledIds.contains($0.id) || postPruneLocalIds.contains($0.id)
                }
                let mergedIds = Set(keptMerged.map(\.id))
                let bundledExtras = bundled.filter { !mergedIds.contains($0.id) }
                // Stamp localOwnerUserId on non-bundled outfits — see
                // matching block in loadData for the rationale.
                let stampedMerged = keptMerged.map { outfit -> Outfit in
                    guard !bundledIds.contains(outfit.id), outfit.localOwnerUserId == nil else { return outfit }
                    var o = outfit
                    o.localOwnerUserId = userId.uuidString
                    return o
                }
                let updated = stampedMerged + bundledExtras
                await MainActor.run {
                    guard self.userId == userId else { return }
                    self.outfits = updated
                }
            }
        }
    }

    func loadSocialData(userId: UUID) async {
        // Load from disk cache — one single update
        let cachedLikes = LocalCache.loadLikedIds(userId: userId) ?? []
        let cachedSaves = LocalCache.loadSavedIds(userId: userId) ?? []
        let cachedProfile = LocalCache.loadProfile(userId: userId)
        let cachedFollowing = LocalCache.loadFollowingIds(userId: userId) ?? []

        await MainActor.run {
            guard self.userId == userId else { return }
            self.likedIds = cachedLikes
            self.savedIds = cachedSaves
            self.followingIds = cachedFollowing
            self.currentProfile = cachedProfile
        }

        // Refresh from Supabase — update live UI and save to cache
        Task.detached(priority: .utility) {
            async let likedTask = try? SocialService.getLikedOutfitIds(userId: userId)
            async let savedTask = try? SocialService.getSavedOutfitIds(userId: userId)
            async let profileTask = try? SocialService.getProfile(userId: userId)
            async let followingTask = try? SocialService.getFollowingIds(userId: userId)

            let liked = await likedTask
            let saved = await savedTask
            let profile = await profileTask
            let following = await followingTask

            if let liked { LocalCache.saveLikedIds(liked, userId: userId) }
            if let saved { LocalCache.saveSavedIds(saved, userId: userId) }
            if let profile { LocalCache.saveProfile(profile, userId: userId) }
            if let following { LocalCache.saveFollowingIds(following, userId: userId) }

            await MainActor.run {
                self.applyFreshSocialData(
                    liked: liked,
                    saved: saved,
                    profile: profile,
                    following: following,
                    for: userId
                )
            }
        }
    }

    func applyFreshSocialData(
        liked: Set<String>?,
        saved: Set<String>?,
        profile: Profile?,
        following: Set<UUID>?,
        for userId: UUID
    ) {
        guard self.userId == userId else { return }
        if let liked { self.likedIds = liked }
        if let saved { self.savedIds = saved }
        if let profile { self.currentProfile = profile }
        if let following { self.followingIds = following }
    }

    /// Updates an outfit's caption and products locally after publishing.
    func updateOutfit(_ outfitId: String, caption: String?, products: [Product]) {
        guard let index = outfits.firstIndex(where: { $0.id == outfitId }) else { return }
        outfits[index].caption = caption
        outfits[index].products = products.isEmpty ? outfits[index].products : products
        persistCache()
    }

    func updateOutfitTags(outfitId: String, tags: [String]) {
        guard let index = outfits.firstIndex(where: { $0.id == outfitId }) else { return }
        outfits[index].tags = tags
        persistCache()
    }

    func updateOutfitDate(outfitId: String, date: String) {
        guard let index = outfits.firstIndex(where: { $0.id == outfitId }) else { return }
        outfits[index].date = date
        persistCache()
    }

    func updateOutfitLocation(outfitId: String, location: String?) {
        guard let index = outfits.firstIndex(where: { $0.id == outfitId }) else { return }
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        outfits[index].location = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistCache()
    }

    func removeProduct(_ product: Product, fromOutfitId outfitId: String) {
        guard let index = outfits.firstIndex(where: { $0.id == outfitId }) else { return }
        outfits[index].products?.removeAll { $0.id == product.id }
        persistCache()
    }

    /// All unique tags used across the user's archive outfits — for autocomplete.
    var allOutfitTags: [String] {
        var seen = Set<String>()
        return archiveOutfits
            .flatMap { $0.tags ?? [] }
            .filter { seen.insert($0).inserted }
    }

    private func persistCache() {
        guard let userId else { return }
        // Snapshot on main actor before dispatching to avoid race with further mutations
        let snapshot = outfits
        let uid = userId
        Task.detached(priority: .utility) {
            LocalCache.saveOutfits(snapshot, userId: uid)
        }
    }

    func toggleFollow(_ targetUserId: UUID) {
        guard let userId else { return }
        if followingIds.contains(targetUserId) {
            followingIds.remove(targetUserId)
        } else {
            followingIds.insert(targetUserId)
        }
        LocalCache.saveFollowingIds(followingIds, userId: userId)
        let isFollowing = followingIds.contains(targetUserId)
        Task {
            if isFollowing {
                try? await SocialService.follow(followerId: userId, followingId: targetUserId)
            } else {
                try? await SocialService.unfollow(followerId: userId, followingId: targetUserId)
            }
        }
    }

    func toggleLike(_ outfitId: String) {
        guard let userId else { return }
        if likedIds.contains(outfitId) {
            likedIds.remove(outfitId)
        } else {
            likedIds.insert(outfitId)
        }
        LocalCache.saveLikedIds(likedIds, userId: userId)
        let isLiked = likedIds.contains(outfitId)
        Task {
            if isLiked {
                try? await SocialService.likeOutfit(userId: userId, outfitId: outfitId)
            } else {
                try? await SocialService.unlikeOutfit(userId: userId, outfitId: outfitId)
            }
        }
    }

    func toggleSave(_ outfitId: String) {
        guard let userId else { return }
        if savedIds.contains(outfitId) {
            savedIds.remove(outfitId)
        } else {
            savedIds.insert(outfitId)
        }
        LocalCache.saveSavedIds(savedIds, userId: userId)
        let isSaved = savedIds.contains(outfitId)
        Task {
            if isSaved {
                try? await SocialService.saveOutfit(userId: userId, outfitId: outfitId)
            } else {
                try? await SocialService.unsaveOutfit(userId: userId, outfitId: outfitId)
            }
        }
    }

    func addOutfit(_ outfit: Outfit) {
        guard let userId else { return }
        var ownedOutfit = outfit
        if ownedOutfit.localOwnerUserId == nil {
            ownedOutfit.localOwnerUserId = userId.uuidString
        }
        if let existing = outfits.firstIndex(where: { $0.id == outfit.id }) {
            outfits[existing] = ownedOutfit
        } else {
            outfits.append(ownedOutfit)
        }
        LocalOutfitStore.shared.saveOutfit(ownedOutfit, userId: userId)
    }

    func publishOutfitToFeed(_ outfit: Outfit, authorName: String = "You", caption: String? = nil) {
        let post = FeedPost(
            id: "local-feed-\(outfit.id)",
            authorName: authorName,
            outfitId: outfit.id,
            caption: caption,
            height: nil,
            size: nil,
            profileImage: nil
        )

        feedPosts.removeAll { $0.id == post.id || $0.outfitId == post.outfitId }
        feedPosts.insert(post, at: 0)
        if let userId {
            LocalOutfitStore.shared.saveFeedPost(post, userId: userId)
        }
    }

    /// Called on app launch/foreground. Pulls every server-side job
    /// the user has running (still polling) *or* sitting in review,
    /// rebuilds a `PipelineJob` for each, and drops them into the
    /// generation queue. For in-flight ones the orchestrator's
    /// `resume(_:)` re-attaches polling — without this, killing the
    /// app mid-3D-render means the server finishes the job but the
    /// client never sees it.
    func checkForServerCompletedJob(userId: UUID) async {
        do {
            async let inflightTask = GenerationJobService.shared.fetchInflightJobs(userId: userId)
            async let reviewTask = GenerationJobService.shared.fetchPendingReviewJob(userId: userId)
            let (inflight, reviewRecord) = try await (inflightTask, reviewTask)

            await MainActor.run {
                guard self.userId == userId else { return }

                let knownJobIds = Set(
                    (generationQueue.activeJobs + generationQueue.waitingJobs)
                        .compactMap(\.serverJobId)
                )

                for record in inflight {
                    guard !knownJobIds.contains(record.id) else { continue }
                    let job = restoredJob(from: record, outfit: nil)
                    generationQueue.adoptFromServer(job)
                    generationOrchestrator.resume(job)
                }

                if let record = reviewRecord,
                   var remoteOutfit = record.remoteOutfit {
                    // Already in archive → user accepted it on another
                    // device or pre-rebuild. Mark accepted server-side
                    // so it stops re-surfacing, don't restore.
                    if outfits.contains(where: { $0.id == remoteOutfit.id }) {
                        Task { try? await GenerationJobService.shared.markAccepted(jobId: record.id, isPublished: false) }
                    } else if !knownJobIds.contains(record.id) {
                        remoteOutfit.isRotationReversed = false
                        let job = restoredJob(from: record, outfit: remoteOutfit)
                        generationQueue.adoptFromServer(job)
                        // No `resume` — review-ready jobs aren't
                        // polled; the card just sits waiting for Accept.
                    }
                }
            }
        } catch {
            // Non-fatal — user can still manually check
        }
    }

    private func restoredJob(from record: GenerationJobRecord, outfit: Outfit?) -> PipelineJob {
        let outfitNum = record.outfitNum
            ?? outfit?.outfitNumber
            ?? LocalOutfitStore.shared.nextOutfitNum(userId: userId ?? UUID())
        let job = PipelineJob(outfitNum: outfitNum)
        job.serverJobId = record.id
        job.loaderStage = record.loaderStage
        if let outfit {
            job.stagedOutfit = outfit
            job.step = .review
            job.isProcessing = false
            job.statusTitle = "READY TO REVIEW"
            job.statusDetail = "Spin's ready to view."
        } else {
            job.step = .generate
            job.isProcessing = true
            job.statusTitle = "GENERATING 3D"
            job.statusDetail = "Spinning your fit..."
        }
        return job
    }

    func isLocalOutfit(_ outfit: Outfit) -> Bool {
        guard let userId else { return false }
        return LocalOutfitStore.shared.loadOutfits(userId: userId).contains { $0.id == outfit.id }
    }

    func deleteOutfit(_ outfit: Outfit) {
        guard isLocalOutfit(outfit) else { return }

        Task {
            await FrameLoader.shared.evict(outfit: outfit)
        }

        outfits.removeAll { $0.id == outfit.id }
        likedIds.remove(outfit.id)
        savedIds.remove(outfit.id)
        feedPosts.removeAll { $0.outfitId == outfit.id }

        if selectedOutfitId == outfit.id {
            selectedOutfitId = nil
        }
        if centeredListOutfitId == outfit.id {
            centeredListOutfitId = nil
        }
        if pendingCalendarScrollOutfitId == outfit.id {
            pendingCalendarScrollOutfitId = nil
        }
        if pendingListScrollOutfitId == outfit.id {
            pendingListScrollOutfitId = nil
        }

        if let userId {
            LocalOutfitStore.shared.deleteOutfitData(for: outfit, userId: userId)
        }
        persistCache()
        // Also delete from Supabase (handles both uploaded and bundled outfits)
        Task.detached(priority: .utility) {
            try? await OutfitService.deleteOutfit(outfit.id)
        }
    }

    func refreshOutfits() async {
        guard let userId else { return }
        let fresh = await ContentSource.getAllOutfits(userId: userId)
        guard !fresh.isEmpty else { return }

        // Defensive: if the fresh fetch silently dropped products (e.g. the
        // outfit_products join failed and the fallback bare-select kicked in),
        // skip the update entirely. Otherwise we'd persist a products-less
        // snapshot to LocalCache and the user would see all products vanish.
        let freshHasAnyProducts = fresh.contains { !($0.products ?? []).isEmpty }
        let currentHasAnyProducts = self.outfits.contains { !($0.products ?? []).isEmpty }
        if !freshHasAnyProducts && currentHasAnyProducts {
            return
        }

        let existingById = Dictionary(self.outfits.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let merged = fresh.map { outfit -> Outfit in
            guard let cached = existingById[outfit.id] else { return outfit }
            // Always prefer fresh as the base, but recover any per-outfit fields
            // that fresh dropped but cached still had (products / tags / caption).
            // Protects user-curated metadata from a single bad fetch.
            var preserved = outfit
            if (outfit.products ?? []).isEmpty && !(cached.products ?? []).isEmpty {
                preserved.products = cached.products
            }
            if (outfit.tags ?? []).isEmpty && !(cached.tags ?? []).isEmpty {
                preserved.tags = cached.tags
            }
            if (outfit.caption ?? "").isEmpty && !(cached.caption ?? "").isEmpty {
                preserved.caption = cached.caption
            }
            if (outfit.location ?? "").isEmpty, let cachedLocation = cached.location, !cachedLocation.isEmpty {
                preserved.location = cachedLocation
            }
            return preserved
        }

        // Stamp localOwnerUserId on non-bundled outfits — Supabase
        // doesn't store this field, so rows that came back via the
        // remote fetch have nil and FrameLoader can't resolve the
        // local frame path. Without this, a 2D outfit that was just
        // accepted goes blank the moment refreshOutfits fires
        // (e.g. PhotosPicker dismissal → scenePhase .active).
        let isOwnerAccount = userId.uuidString.lowercased() == AppConfig.archiveOwnerUserId
        let bundledIds = isOwnerAccount ? Set(ContentSource.getBundledOutfits().map(\.id)) : []
        let stamped = merged.map { outfit -> Outfit in
            guard !bundledIds.contains(outfit.id), outfit.localOwnerUserId == nil else { return outfit }
            var o = outfit
            o.localOwnerUserId = userId.uuidString
            return o
        }
        await MainActor.run {
            guard self.userId == userId else { return }
            self.outfits = stamped
        }
        LocalCache.saveOutfits(stamped, userId: userId)
    }

    func refreshFeed() async {
        guard let userId else { return }
        let freshFeed = await ContentSource.getPublicFeed()
        guard self.userId == userId else { return }
        LocalCache.saveFeedPosts(freshFeed, userId: userId)

        // Skip the UI update only when the fetch returned nothing —
        // we don't want to clear the feed because of a transient
        // network blip. Otherwise always commit, so updated
        // avatars/names propagate even when an Equatable diff would
        // (incorrectly) consider the arrays equivalent.
        guard !freshFeed.isEmpty else { return }

        await MainActor.run {
            guard self.userId == userId else { return }
            self.feedPosts = freshFeed
        }

        await refreshUnreadNotificationCount()

        // Prefetch outfits + frame 0 for the first visible cards
        Task.detached(priority: .utility) {
            let postsToPreload = Array(freshFeed.prefix(10))
            for post in postsToPreload {
                guard self.outfitById[post.outfitId] == nil else { continue }
                if let outfit = await ContentSource.getPublicOutfit(id: post.outfitId) {
                    await MainActor.run {
                        guard self.userId == userId else { return }
                        self.feedOutfitCache[post.outfitId] = outfit
                    }
                    _ = await FrameLoader.shared.frame(for: outfit, index: 0)
                }
            }
        }
    }

}

enum NotificationReadState {
    private static func key(for userId: UUID) -> String {
        "lastSeenNotificationsAt-\(userId.uuidString)"
    }

    static func lastSeenDate(for userId: UUID) -> Date {
        UserDefaults.standard.object(forKey: key(for: userId)) as? Date ?? .distantPast
    }

    static func markSeen(for userId: UUID, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: key(for: userId))
    }

    static func clear(for userId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: userId))
    }
}

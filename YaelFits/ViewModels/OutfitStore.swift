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
    var uploadJob: PipelineJob?
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
    var generationReadyForReview = false
    var isCarouselOpen = false
    var unreadNotificationCount = 0
    var feedScrollToTopTrigger = 0

    func beginSession(for userId: UUID) {
        UserDefaults.standard.removeObject(forKey: "lastSeenNotificationsAt")
        let isSwitchingUsers = self.userId != nil && self.userId != userId
        self.userId = userId

        guard isSwitchingUsers else {
            isLoading = true
            return
        }

        cancelUploadTask()
        outfits = []
        feedPosts = []
        uploadJob = nil
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
        generationReadyForReview = false
        isCarouselOpen = false
        unreadNotificationCount = 0
        currentProfile = nil
        feedOutfitCache = [:]
    }

    func resetForSignedOutState() {
        cancelUploadTask()
        userId = nil
        outfits = []
        feedPosts = []
        uploadJob = nil
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
        generationReadyForReview = false
        isCarouselOpen = false
        unreadNotificationCount = 0
        currentProfile = nil
        feedOutfitCache = [:]
    }

    func refreshUnreadNotificationCount() async {
        guard let userId else { return }
        let lastSeen = NotificationReadState.lastSeenDate(for: userId)
        let since = ISO8601DateFormatter().string(from: lastSeen)

        struct IdRow: Decodable { let id: String }
        struct OutfitIdRow: Decodable {
            let outfitId: String
            enum CodingKeys: String, CodingKey { case outfitId = "outfit_id" }
        }
        let userOutfitIds: [String] = (try? await supabase
            .from("outfits")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value as [IdRow])?.map(\.id) ?? []

        var count = 0

        if !userOutfitIds.isEmpty {
            let likes: [OutfitIdRow] = (try? await supabase
                .from("likes")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .gt("created_at", value: since)
                .execute()
                .value) ?? []
            count += likes.count

            let comments: [OutfitIdRow] = (try? await supabase
                .from("comments")
                .select("outfit_id")
                .in("outfit_id", values: userOutfitIds)
                .neq("user_id", value: userId.uuidString)
                .gt("created_at", value: since)
                .execute()
                .value) ?? []
            count += comments.count
        }

        struct FollowIdRow: Decodable { let follower_id: String }
        let follows: [FollowIdRow] = (try? await supabase
            .from("follows")
            .select("follower_id")
            .eq("following_id", value: userId.uuidString)
            .neq("follower_id", value: userId.uuidString)
            .gt("created_at", value: since)
            .execute()
            .value) ?? []
        count += follows.count

        let finalCount = count
        await MainActor.run {
            guard self.userId == userId else { return }
            unreadNotificationCount = finalCount
        }
    }
    var hasPlayedInitialListEntrance = false
    var uploadTask: Task<Void, Never>?
    var currentProfile: Profile?
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
        archiveOutfits.sorted { a, b in
            (a.outfitNumber ?? 0) < (b.outfitNumber ?? 0)
        }
    }

    var isUploadInProgress: Bool {
        uploadJob?.isProcessing == true
    }

    var uploadIndicatorProgress: Double {
        guard let uploadJob, isUploadInProgress else { return 0 }

        switch uploadJob.loaderStage {
        case .removingBackground:
            return 0.12
        case .creatingInteractiveFit:
            return 0.42
        case .compressing:
            return min(0.96, 0.5 + (uploadJob.progress ?? 0) * 0.46)
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
        let local = ContentSource.getLocalOutfits(userId: userId)
        let baseIds = Set(base.map(\.id))
        let uniqueLocal = local.filter { !baseIds.contains($0.id) }
        let instant = base + uniqueLocal
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

    func replaceUploadTask(with task: Task<Void, Never>?) {
        uploadTask?.cancel()
        uploadTask = task
    }

    func cancelUploadTask() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    func restorePersistedPendingReviewIfNeeded() {
        guard let userId,
              uploadJob == nil,
              let review = LocalOutfitStore.shared.loadPendingReview(userId: userId) else {
            return
        }

        uploadJob = review.makePipelineJob()
        generationReadyForReview = true
    }

    /// Called on app launch/foreground. Finds any server-completed job waiting for review
    /// and restores it so the user can accept/retake without losing their generation.
    func checkForServerCompletedJob(userId: UUID) async {
        guard uploadJob == nil else { return }

        do {
            guard let record = try await GenerationJobService.shared.fetchPendingReviewJob(userId: userId),
                  var remoteOutfit = record.remoteOutfit else { return }

            // If the outfit already exists in the archive the user already accepted it —
            // mark it accepted on the server and skip restoring the review screen.
            let alreadyAccepted = outfits.contains { $0.id == remoteOutfit.id }
            if alreadyAccepted {
                Task { try? await GenerationJobService.shared.markAccepted(jobId: record.id, isPublished: false) }
                return
            }

            remoteOutfit.isRotationReversed = false

            let job = PipelineJob(outfitNum: remoteOutfit.outfitNumber ?? 0)
            job.step = .review
            job.isProcessing = false
            job.serverJobId = record.id
            job.stagedOutfit = remoteOutfit
            job.statusTitle = "Ready"
            job.statusDetail = "Your interactive fit is ready for review."

            await MainActor.run {
                guard self.userId == userId, uploadJob == nil else { return }
                uploadJob = job
                generationReadyForReview = true
            }
        } catch {
            // Non-fatal — user can still manually check
        }
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
        await MainActor.run {
            guard self.userId == userId else { return }
            self.outfits = merged
        }
        LocalCache.saveOutfits(merged, userId: userId)
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

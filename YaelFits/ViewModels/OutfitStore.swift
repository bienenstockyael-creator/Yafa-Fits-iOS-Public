import SwiftUI

enum ViewTransitionPhase: Equatable {
    case idle
    case sourceOut   // source view elements fading/blurring out
    case targetIn    // target view elements fading/blurring in
}

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
    var useFahrenheit: Bool = true
    var likedIds: Set<String> = []
    var savedIds: Set<String> = []
    var followingIds: Set<UUID> = []
    var isLoading: Bool = true
    var selectedOutfitId: String?
    var centeredListOutfitId: String?
    var pendingCalendarScrollOutfitId: String?
    var listOutfitFrames: [String: CGRect] = [:]
    var calendarOutfitFrames: [String: CGRect] = [:]
    var listOutfitFrameIndices: [String: Int] = [:]
    var heroAnchorOutfitId: String?
    var viewTransitionPhase: ViewTransitionPhase = .idle
    var generationReadyForReview = false
    var isCarouselOpen = false
    var unreadNotificationCount = 0
    var feedScrollToTopTrigger = 0
    var hasPlayedInitialListEntrance = false
    var uploadTask: Task<Void, Never>?
    var currentProfile: Profile?
    var feedOutfitCache: [String: Outfit] = [:]

    var outfitById: [String: Outfit] {
        Dictionary(uniqueKeysWithValues: outfits.map { ($0.id, $0) })
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
        let local = ContentSource.getLocalOutfits()
        let baseIds = Set(base.map(\.id))
        let uniqueLocal = local.filter { !baseIds.contains($0.id) }
        let instant = base + uniqueLocal
        let instantFeed = cachedFeed ?? ContentSource.getBundledFeed()
        let sorted = instant.sorted { ($0.outfitNumber ?? 0) < ($1.outfitNumber ?? 0) }

        if !sorted.isEmpty {
            await FrameLoader.shared.preloadFullSequences(for: Array(sorted.prefix(9)))
        }

        await MainActor.run {
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
            await self.refreshFeed()
        }

        // Save fresh Supabase data to cache for next launch — don't update live UI.
        // For bundled outfits (not in Supabase), preserve the cached version so
        // user-tagged products and tags aren't lost when the refresh runs.
        Task.detached(priority: .utility) {
            let fresh = await ContentSource.getAllOutfits(userId: userId)
            if !fresh.isEmpty {
                let existing = LocalCache.loadOutfits(userId: userId) ?? []
                let existingById = Dictionary(existing.map { ($0.id, $0) },
                                              uniquingKeysWith: { a, _ in a })
                let bundledIds = Set(ContentSource.getBundledOutfits().map(\.id))
                let merged = fresh.map { outfit -> Outfit in
                    // For bundled outfits, keep the cached copy (has user products/tags)
                    if bundledIds.contains(outfit.id), let cached = existingById[outfit.id] {
                        return cached
                    }
                    return outfit
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

            let liked = await likedTask ?? []
            let saved = await savedTask ?? []
            let profile = await profileTask
            let following = await followingTask ?? []

            LocalCache.saveLikedIds(liked, userId: userId)
            LocalCache.saveSavedIds(saved, userId: userId)
            if let profile { LocalCache.saveProfile(profile, userId: userId) }
            LocalCache.saveFollowingIds(following, userId: userId)

            // Update live UI with fresh data — critical for first sign-in when cache is empty
            await MainActor.run {
                if !liked.isEmpty { self.likedIds = liked }
                if !saved.isEmpty { self.savedIds = saved }
                if let profile { self.currentProfile = profile }
                if !following.isEmpty { self.followingIds = following }
            }
        }
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
        outfits.append(outfit)
        LocalOutfitStore.shared.saveOutfit(outfit)
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
        LocalOutfitStore.shared.saveFeedPost(post)
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
        guard uploadJob == nil,
              let review = LocalOutfitStore.shared.loadPendingReview() else {
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
                guard uploadJob == nil else { return }
                uploadJob = job
                generationReadyForReview = true
            }
        } catch {
            // Non-fatal — user can still manually check
        }
    }

    func isLocalOutfit(_ outfit: Outfit) -> Bool {
        LocalOutfitStore.shared.loadOutfits().contains { $0.id == outfit.id }
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

        LocalOutfitStore.shared.deleteOutfitData(for: outfit)
        persistCache()
        // Also delete from Supabase (handles both uploaded and bundled outfits)
        Task.detached(priority: .utility) {
            try? await OutfitService.deleteOutfit(outfit.id)
        }
    }

    func refreshOutfits() async {
        guard let userId else { return }
        let allOutfits = await ContentSource.getAllOutfits(userId: userId)
        await MainActor.run {
            self.outfits = allOutfits
        }
    }

    func refreshFeed() async {
        guard let userId else { return }
        var feedUserIds = followingIds
        feedUserIds.insert(userId)
        let freshFeed = await ContentSource.getFollowedFeed(followingIds: feedUserIds)
        LocalCache.saveFeedPosts(freshFeed, userId: userId)

        let currentIds = Set(feedPosts.map(\.id))
        let freshIds = Set(freshFeed.map(\.id))
        guard currentIds != freshIds else { return }

        await MainActor.run {
            self.feedPosts = freshFeed
        }

        // Prefetch outfits + frame 0 for the first visible cards
        Task.detached(priority: .utility) {
            let postsToPreload = Array(freshFeed.prefix(10))
            for post in postsToPreload {
                guard self.outfitById[post.outfitId] == nil else { continue }
                if let outfit = await ContentSource.getPublicOutfit(id: post.outfitId) {
                    await MainActor.run { self.feedOutfitCache[post.outfitId] = outfit }
                    _ = await FrameLoader.shared.frame(for: outfit, index: 0)
                }
            }
        }
    }
}

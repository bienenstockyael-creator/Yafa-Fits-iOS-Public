import SwiftUI

enum AppView: String, CaseIterable {
    case list = "List"
    case calendar = "Calendar"
    case feed = "Feed"
    case upload = "Upload"
}

@Observable
class OutfitStore {
    var outfits: [Outfit] = []
    var feedPosts: [FeedPost] = []
    var uploadJob: PipelineJob?
    var currentView: AppView = .list
    var useFahrenheit: Bool = true
    var likedIds: Set<String> = []
    var feedLikedPostIds: Set<String> = []
    var feedSavedPostIds: Set<String> = []
    var feedCommentedPostIds: Set<String> = []
    var isLoading: Bool = true
    var selectedOutfitId: String?
    var centeredListOutfitId: String?
    var pendingCalendarScrollOutfitId: String?
    var hasPlayedInitialListEntrance = false
    var uploadTask: Task<Void, Never>?

    var outfitById: [String: Outfit] {
        Dictionary(uniqueKeysWithValues: outfits.map { ($0.id, $0) })
    }

    var archiveOutfits: [Outfit] {
        outfits.filter { !AppConfig.publicOnlyOutfitIDs.contains($0.id) }
    }

    var sortedOutfits: [Outfit] {
        archiveOutfits.sorted { a, b in
            (a.outfitNumber ?? 0) < (b.outfitNumber ?? 0)
        }
    }

    var isUploadInProgress: Bool {
        guard let uploadJob else { return false }
        return uploadJob.isProcessing && uploadJob.loaderStage != .removingBackground
    }

    var uploadIndicatorProgress: Double {
        guard let uploadJob, isUploadInProgress else { return 0 }

        switch uploadJob.loaderStage {
        case .removingBackground:
            return 0
        case .creatingInteractiveFit:
            return 0.34
        case .compressing:
            return min(0.96, 0.42 + (uploadJob.progress ?? 0) * 0.54)
        }
    }

    func loadData() async {
        let loadStartedAt = Date()
        async let outfitsTask = ContentSource.getAllOutfits()
        async let feedTask = ContentSource.getPublicFeed()
        let allOutfits = await outfitsTask
        let feed = await feedTask
        let prioritizedOutfits = allOutfits.sorted { a, b in
            (a.outfitNumber ?? 0) < (b.outfitNumber ?? 0)
        }
        async let initialSequencePreload: Void =
            FrameLoader.shared.preloadFullSequences(for: Array(prioritizedOutfits.prefix(9)))
        let minimumLoaderDuration: TimeInterval = 1.5
        let remainingLoaderTime = minimumLoaderDuration - Date().timeIntervalSince(loadStartedAt)

        if remainingLoaderTime > 0 {
            try? await Task.sleep(for: .seconds(remainingLoaderTime))
        }

        _ = await initialSequencePreload

        await MainActor.run {
            self.outfits = allOutfits
            self.feedPosts = feed
            self.isLoading = false
        }

        // Preload first frames in background (non-blocking)
        Task.detached(priority: .utility) {
            await FrameLoader.shared.preloadFirstFrames(outfits: Array(prioritizedOutfits.prefix(12)))
        }
    }

    func toggleLike(_ outfitId: String) {
        if likedIds.contains(outfitId) {
            likedIds.remove(outfitId)
        } else {
            likedIds.insert(outfitId)
        }
    }

    func toggleFeedLike(_ postId: String) {
        if feedLikedPostIds.contains(postId) {
            feedLikedPostIds.remove(postId)
        } else {
            feedLikedPostIds.insert(postId)
        }
    }

    func toggleFeedSave(_ postId: String) {
        if feedSavedPostIds.contains(postId) {
            feedSavedPostIds.remove(postId)
        } else {
            feedSavedPostIds.insert(postId)
        }
    }

    func toggleFeedComment(_ postId: String) {
        if feedCommentedPostIds.contains(postId) {
            feedCommentedPostIds.remove(postId)
        } else {
            feedCommentedPostIds.insert(postId)
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
    }

    func refreshOutfits() async {
        let allOutfits = await ContentSource.getAllOutfits()
        await MainActor.run {
            self.outfits = allOutfits
        }
    }
}

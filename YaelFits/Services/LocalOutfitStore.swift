import Foundation
import UIKit

/// Manages locally created outfits and any device-only review state.
/// Metadata is scoped per signed-in user so accounts on the same device
/// do not see each other's private local content.
class LocalOutfitStore {
    static let shared = LocalOutfitStore()

    private let previewFileName = "preview"
    private let pendingReviewFileName = "pending-generation-review.json"

    private let fileManager = FileManager.default
    private let rootDir: URL
    private let userDataRootDir: URL
    private let legacyMetadataFile: URL
    private let legacyFeedMetadataFile: URL
    private let legacyPendingReviewFile: URL

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootDir = docs.appendingPathComponent("outfits", isDirectory: true)
        userDataRootDir = docs.appendingPathComponent("local-user-data", isDirectory: true)
        legacyMetadataFile = docs.appendingPathComponent("local-outfits.json")
        legacyFeedMetadataFile = docs.appendingPathComponent("local-feed.json")
        legacyPendingReviewFile = docs.appendingPathComponent(pendingReviewFileName)
        try? fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: userDataRootDir, withIntermediateDirectories: true)
    }

    /// Returns the next outfit number to use for a new outfit by
    /// this user. Monotonically increasing — even after a delete,
    /// the slot is NOT reused.
    ///
    /// Previously this returned `max(currentOutfits.outfitNumber) + 1`,
    /// which reused freed-up numbers after a delete. That caused a
    /// subtle data-integrity bug: a freshly-saved outfit could share
    /// an ID with a recently-deleted outfit whose server-side row
    /// hadn't been fully cleaned up (the server delete is fire-and-
    /// forget via `try?`), and the next refresh would merge ghost
    /// data into the new outfit's slot.
    ///
    /// Now we track a per-user "high-water mark" alongside the
    /// existing metadata — a single integer that only ever grows.
    /// `next = max(currentMax, highWaterMark) + 1`. Mark gets
    /// bumped here on every call. The double-source (current outfits
    /// AND mark) is belt-and-suspenders: if the mark file is ever
    /// missing or corrupt, we fall back to current outfits and
    /// still always return at-least-monotonic numbers.
    func nextOutfitNum(userId: UUID) -> Int {
        let outfits = loadOutfits(userId: userId)
        let currentMax = outfits.compactMap(\.outfitNumber).max() ?? 0
        let highWaterMark = loadOutfitNumberHighWaterMark(userId: userId)
        let next = max(currentMax, highWaterMark) + 1
        saveOutfitNumberHighWaterMark(next, userId: userId)
        return next
    }

    private func highWaterMarkFile(for userId: UUID) -> URL {
        userDirectory(for: userId).appendingPathComponent("outfit-number-hwm.json")
    }

    private struct HighWaterMark: Codable { let value: Int }

    private func loadOutfitNumberHighWaterMark(userId: UUID) -> Int {
        let url = highWaterMarkFile(for: userId)
        guard let data = try? Data(contentsOf: url),
              let mark = try? JSONDecoder().decode(HighWaterMark.self, from: data) else {
            return 0
        }
        return mark.value
    }

    private func saveOutfitNumberHighWaterMark(_ value: Int, userId: UUID) {
        let url = highWaterMarkFile(for: userId)
        guard let encoded = try? JSONEncoder().encode(HighWaterMark(value: value)) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private func assetOwnerId(for outfit: Outfit, userId: UUID? = nil) -> String? {
        if let userId {
            return userId.uuidString
        }
        return outfit.localOwnerUserId
    }

    private func userDirectory(for userId: UUID) -> URL {
        let dir = userDataRootDir.appendingPathComponent(userId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metadataFile(for userId: UUID) -> URL {
        userDirectory(for: userId).appendingPathComponent("local-outfits.json")
    }

    private func feedMetadataFile(for userId: UUID) -> URL {
        userDirectory(for: userId).appendingPathComponent("local-feed.json")
    }

    private func pendingReviewFile(for userId: UUID) -> URL {
        userDirectory(for: userId).appendingPathComponent(pendingReviewFileName)
    }

    private func migrateLegacyDataIfNeeded(to userId: UUID) {
        let userMetadataFile = metadataFile(for: userId)
        let userFeedFile = feedMetadataFile(for: userId)
        let userPendingReviewFile = pendingReviewFile(for: userId)

        if fileManager.fileExists(atPath: legacyMetadataFile.path),
           !fileManager.fileExists(atPath: userMetadataFile.path),
           let data = try? Data(contentsOf: legacyMetadataFile),
           let outfitData = try? JSONDecoder().decode(OutfitData.self, from: data) {
            let migratedOutfits = outfitData.outfits.map { outfit -> Outfit in
                var ownedOutfit = outfit
                ownedOutfit.localOwnerUserId = userId.uuidString
                migrateLegacyAssets(for: outfit, to: ownedOutfit, userId: userId)
                return ownedOutfit
            }
            if let encoded = try? JSONEncoder().encode(OutfitData(outfits: migratedOutfits)) {
                try? encoded.write(to: userMetadataFile, options: .atomic)
                try? fileManager.removeItem(at: legacyMetadataFile)
            }
        }

        if fileManager.fileExists(atPath: legacyFeedMetadataFile.path),
           !fileManager.fileExists(atPath: userFeedFile.path),
           let data = try? Data(contentsOf: legacyFeedMetadataFile) {
            try? data.write(to: userFeedFile, options: .atomic)
            try? fileManager.removeItem(at: legacyFeedMetadataFile)
        }

        if fileManager.fileExists(atPath: legacyPendingReviewFile.path),
           !fileManager.fileExists(atPath: userPendingReviewFile.path),
           let data = try? Data(contentsOf: legacyPendingReviewFile),
           var review = try? JSONDecoder().decode(PersistedPipelineReview.self, from: data) {
            var ownedOutfit = review.stagedOutfit
            ownedOutfit.localOwnerUserId = userId.uuidString
            migrateLegacyAssets(for: review.stagedOutfit, to: ownedOutfit, userId: userId)
            review = PersistedPipelineReview(
                id: review.id,
                outfitNum: review.outfitNum,
                stagedOutfit: ownedOutfit,
                uploadWeather: review.uploadWeather,
                uploadLocation: review.uploadLocation,
                isRotationReversed: review.isRotationReversed,
                sourceImagePath: review.sourceImagePath,
                serverJobId: review.serverJobId,
                prompt: review.prompt,
                persistedAt: review.persistedAt,
                statusTitle: review.statusTitle,
                statusDetail: review.statusDetail
            )
            if let encoded = try? JSONEncoder().encode(review) {
                try? encoded.write(to: userPendingReviewFile, options: .atomic)
                try? fileManager.removeItem(at: legacyPendingReviewFile)
            }
        }
    }

    private func migrateLegacyAssets(for legacyOutfit: Outfit, to ownedOutfit: Outfit, userId: UUID) {
        let legacyDir = rootDir.appendingPathComponent(legacyOutfit.folder, isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDir.path) else { return }

        let destinationDir = outfitDirectory(for: ownedOutfit, userId: userId)
        guard !fileManager.fileExists(atPath: destinationDir.path) else { return }
        try? fileManager.createDirectory(at: destinationDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacyDir, to: destinationDir)
    }

    func outfitDirectory(for outfit: Outfit, userId: UUID? = nil) -> URL {
        if let ownerId = assetOwnerId(for: outfit, userId: userId) {
            let ownerDir = rootDir.appendingPathComponent(ownerId, isDirectory: true)
            try? fileManager.createDirectory(at: ownerDir, withIntermediateDirectories: true)
            return ownerDir.appendingPathComponent(outfit.folder, isDirectory: true)
        }
        return rootDir.appendingPathComponent(outfit.folder, isDirectory: true)
    }

    func frameURL(for outfit: Outfit, index: Int, userId: UUID? = nil) -> URL {
        let dir = outfitDirectory(for: outfit, userId: userId)
        let padded = String(format: "%05d", index)
        return dir.appendingPathComponent("\(outfit.prefix)\(padded).\(outfit.normalizedFrameExt)")
    }

    func previewURL(for outfit: Outfit, userId: UUID? = nil) -> URL {
        outfitDirectory(for: outfit, userId: userId).appendingPathComponent("\(previewFileName).webp")
    }

    func hasAssets(for outfit: Outfit, userId: UUID? = nil) -> Bool {
        if outfit.resolvedRemoteBaseURL != nil {
            return true
        }

        let candidateDirs: [URL]
        if let userId {
            candidateDirs = [outfitDirectory(for: outfit, userId: userId)]
        } else if outfit.localOwnerUserId != nil {
            candidateDirs = [outfitDirectory(for: outfit)]
        } else {
            candidateDirs = [outfitDirectory(for: outfit)]
        }

        for dir in candidateDirs {
            guard fileManager.fileExists(atPath: dir.path) else { continue }

            let previewPath = dir.appendingPathComponent("\(previewFileName).webp").path
            let firstFramePath = dir
                .appendingPathComponent("\(outfit.prefix)\(String(format: "%05d", 0)).\(outfit.normalizedFrameExt)")
                .path
            if fileManager.fileExists(atPath: previewPath) || fileManager.fileExists(atPath: firstFramePath) {
                return true
            }
        }

        return false
    }

    func saveFrame(_ imageData: Data, outfit: Outfit, userId: UUID? = nil, index: Int) throws {
        let dir = outfitDirectory(for: outfit, userId: userId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = frameURL(for: outfit, index: index, userId: userId)
        try imageData.write(to: url)
    }

    func savePreview(_ imageData: Data, outfit: Outfit, userId: UUID? = nil) throws {
        let dir = outfitDirectory(for: outfit, userId: userId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try imageData.write(to: previewURL(for: outfit, userId: userId))
    }

    func previewImage(for outfit: Outfit) -> UIImage? {
        let previewURL = previewURL(for: outfit)
        if fileManager.fileExists(atPath: previewURL.path),
           let data = try? Data(contentsOf: previewURL),
           let image = UIImage(data: data) {
            return image
        }

        let firstFrameURL = frameURL(for: outfit, index: 0)
        guard fileManager.fileExists(atPath: firstFrameURL.path),
              let data = try? Data(contentsOf: firstFrameURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    func loadOutfits(userId: UUID) -> [Outfit] {
        migrateLegacyDataIfNeeded(to: userId)
        let url = metadataFile(for: userId)
        guard let data = try? Data(contentsOf: url),
              let outfitData = try? JSONDecoder().decode(OutfitData.self, from: data) else {
            return []
        }
        return outfitData.outfits
    }

    func saveOutfit(_ outfit: Outfit, userId: UUID) {
        var outfits = loadOutfits(userId: userId)
        var ownedOutfit = outfit
        if ownedOutfit.localOwnerUserId == nil {
            ownedOutfit.localOwnerUserId = userId.uuidString
        }
        outfits.removeAll { $0.id == ownedOutfit.id }
        outfits.append(ownedOutfit)
        let data = OutfitData(outfits: outfits)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile(for: userId), options: .atomic)
        }
    }

    /// Removes locally-tracked outfits whose IDs are not in the given
    /// keep set AND have no local frame on disk. Outfits with local
    /// files are preserved even if missing from `keepIds` — they may
    /// be in-flight uploads whose Supabase row hasn't landed yet.
    /// Used to reconcile the local JSON with the source of truth
    /// (Supabase) without nuking just-created outfits.
    @discardableResult
    func pruneOutfits(notIn keepIds: Set<String>, userId: UUID) -> Int {
        let outfits = loadOutfits(userId: userId)
        let toRemove = outfits.filter { outfit in
            guard !keepIds.contains(outfit.id) else { return false }
            // Keep outfits whose frames are reachable via Supabase
            // storage (3D outfits land here): `remoteBaseURL` means the
            // outfit is renderable even if its archive row hasn't synced
            // yet. Without this, a freshly-accepted 3D outfit gets
            // pruned on the next launch when `saveArchiveOutfit` hadn't
            // completed before the previous app session ended —
            // `serverIds` (Supabase archive) doesn't include it AND
            // there's no local first frame (3D frames are remote-only).
            if let url = outfit.remoteBaseURL, !url.isEmpty { return false }
            let firstFrame = frameURL(for: outfit, index: 0, userId: userId)
            return !fileManager.fileExists(atPath: firstFrame.path)
        }
        guard !toRemove.isEmpty else { return 0 }
        let toRemoveIds = Set(toRemove.map(\.id))
        let kept = outfits.filter { !toRemoveIds.contains($0.id) }
        for outfit in toRemove {
            let dir = outfitDirectory(for: outfit, userId: userId)
            try? fileManager.removeItem(at: dir)
        }
        let data = OutfitData(outfits: kept)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile(for: userId), options: .atomic)
        }
        return toRemove.count
    }

    /// Removes locally-tracked outfits that have no usable assets: no
    /// local frame on disk AND no remote_base_url. These accumulate
    /// when an upload fails mid-flow or the user wipes the Supabase
    /// row but the local JSON still references the orphan. Returns
    /// the count pruned for logging.
    @discardableResult
    func pruneOrphanedOutfits(userId: UUID) -> Int {
        let outfits = loadOutfits(userId: userId)
        let kept = outfits.filter { outfit in
            if let url = outfit.remoteBaseURL, !url.isEmpty { return true }
            let firstFrameURL = frameURL(for: outfit, index: 0, userId: userId)
            return fileManager.fileExists(atPath: firstFrameURL.path)
        }
        let pruned = outfits.count - kept.count
        guard pruned > 0 else { return 0 }
        let data = OutfitData(outfits: kept)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile(for: userId), options: .atomic)
        }
        return pruned
    }

    func deleteOutfitData(for outfit: Outfit, userId: UUID) {
        let dir = outfitDirectory(for: outfit, userId: userId)
        try? fileManager.removeItem(at: dir)

        var outfits = loadOutfits(userId: userId)
        outfits.removeAll { $0.id == outfit.id }
        let data = OutfitData(outfits: outfits)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile(for: userId), options: .atomic)
        }

        deleteFeedPosts(forOutfitID: outfit.id, userId: userId)
    }

    func loadFeedPosts(userId: UUID) -> [FeedPost] {
        migrateLegacyDataIfNeeded(to: userId)
        let url = feedMetadataFile(for: userId)
        guard let data = try? Data(contentsOf: url),
              let feedData = try? JSONDecoder().decode(FeedData.self, from: data) else {
            return []
        }
        return feedData.posts
    }

    func saveFeedPost(_ post: FeedPost, userId: UUID) {
        var posts = loadFeedPosts(userId: userId)
        posts.removeAll { $0.id == post.id || $0.outfitId == post.outfitId }
        posts.insert(post, at: 0)
        let data = FeedData(posts: posts)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: feedMetadataFile(for: userId), options: .atomic)
        }
    }

    func deleteFeedPosts(forOutfitID outfitId: String, userId: UUID) {
        var posts = loadFeedPosts(userId: userId)
        posts.removeAll { $0.outfitId == outfitId }
        let data = FeedData(posts: posts)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: feedMetadataFile(for: userId), options: .atomic)
        }
    }

    func savePendingReview(_ review: PersistedPipelineReview, userId: UUID) {
        guard let encoded = try? JSONEncoder().encode(review) else { return }
        try? encoded.write(to: pendingReviewFile(for: userId), options: .atomic)
    }

    func loadPendingReview(userId: UUID) -> PersistedPipelineReview? {
        migrateLegacyDataIfNeeded(to: userId)
        let url = pendingReviewFile(for: userId)
        guard let data = try? Data(contentsOf: url),
              let review = try? JSONDecoder().decode(PersistedPipelineReview.self, from: data) else {
            return nil
        }

        guard hasAssets(for: review.stagedOutfit, userId: userId) else {
            clearPendingReview(userId: userId)
            return nil
        }

        return review
    }

    func clearPendingReview(userId: UUID) {
        try? fileManager.removeItem(at: pendingReviewFile(for: userId))
    }

    // MARK: - Pending pipeline jobs (fork / generating / review persistence)

    // A fork-stage 2D still must survive app kills indefinitely —
    // it only leaves disk when the user acts on it (save 2D, accept
    // 3D, or cancel). One JSON per job keyed by outfit number, with
    // the cutout / green-screen PNGs saved alongside.

    private func pendingJobsDirectory(for userId: UUID) -> URL {
        let dir = userDirectory(for: userId).appendingPathComponent("pending-jobs", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pendingJobFile(outfitNum: Int, userId: UUID) -> URL {
        pendingJobsDirectory(for: userId).appendingPathComponent("job-\(outfitNum).json")
    }

    private func pendingJobImageFile(outfitNum: Int, kind: String, userId: UUID) -> URL {
        pendingJobsDirectory(for: userId).appendingPathComponent("job-\(outfitNum)-\(kind).png")
    }

    func savePendingJob(_ record: PersistedPendingJob, userId: UUID) {
        guard let encoded = try? JSONEncoder().encode(record) else { return }
        try? encoded.write(to: pendingJobFile(outfitNum: record.outfitNum, userId: userId), options: .atomic)
    }

    /// Saves the job's heavy image assets once — subsequent persists
    /// only rewrite the small JSON snapshot.
    func savePendingJobImages(cutout: Data?, greenScreen: Data?, outfitNum: Int, userId: UUID) {
        if let cutout {
            try? cutout.write(to: pendingJobImageFile(outfitNum: outfitNum, kind: "cutout", userId: userId), options: .atomic)
        }
        if let greenScreen {
            try? greenScreen.write(to: pendingJobImageFile(outfitNum: outfitNum, kind: "green", userId: userId), options: .atomic)
        }
    }

    func loadPendingJobImage(outfitNum: Int, kind: String, userId: UUID) -> Data? {
        try? Data(contentsOf: pendingJobImageFile(outfitNum: outfitNum, kind: kind, userId: userId))
    }

    func loadPendingJobs(userId: UUID) -> [PersistedPendingJob] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: pendingJobsDirectory(for: userId),
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(PersistedPendingJob.self, from: data)
            }
            .sorted { $0.outfitNum < $1.outfitNum }
    }

    func removePendingJob(outfitNum: Int, userId: UUID) {
        try? fileManager.removeItem(at: pendingJobFile(outfitNum: outfitNum, userId: userId))
        for kind in ["cutout", "green"] {
            try? fileManager.removeItem(at: pendingJobImageFile(outfitNum: outfitNum, kind: kind, userId: userId))
        }
    }

    /// Removes the locally-saved frames/preview for an outfit WITHOUT
    /// touching the local manifest or feed posts. Used when a 3D
    /// accept supersedes the temp 2D still saved at fork time — the
    /// local frame 0 would otherwise shadow the remote 3D frames in
    /// `FrameLoader`.
    func deleteLocalFrames(for outfit: Outfit, userId: UUID) {
        try? fileManager.removeItem(at: outfitDirectory(for: outfit, userId: userId))
    }

    func storageUsed() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: rootDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func removeAllData(userId: UUID) {
        try? fileManager.removeItem(at: userDirectory(for: userId))
        try? fileManager.removeItem(at: rootDir.appendingPathComponent(userId.uuidString, isDirectory: true))
    }

    func removeLegacyData() {
        try? fileManager.removeItem(at: legacyMetadataFile)
        try? fileManager.removeItem(at: legacyFeedMetadataFile)
        try? fileManager.removeItem(at: legacyPendingReviewFile)
    }
}

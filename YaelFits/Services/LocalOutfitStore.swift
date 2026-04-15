import Foundation
import UIKit

/// Manages locally created outfits — frames stored on-device.
class LocalOutfitStore {
    static let shared = LocalOutfitStore()

    private let previewFileName = "preview"
    private let pendingReviewFileName = "pending-generation-review.json"

    private let fileManager = FileManager.default
    private let outfitsDir: URL
    private let metadataFile: URL
    private let feedMetadataFile: URL
    private let pendingReviewFile: URL

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outfitsDir = docs.appendingPathComponent("outfits", isDirectory: true)
        metadataFile = docs.appendingPathComponent("local-outfits.json")
        feedMetadataFile = docs.appendingPathComponent("local-feed.json")
        pendingReviewFile = docs.appendingPathComponent(pendingReviewFileName)
        try? fileManager.createDirectory(at: outfitsDir, withIntermediateDirectories: true)
    }

    func nextOutfitNum() -> Int {
        let outfits = loadOutfits()
        let nums = outfits.compactMap(\.outfitNumber)
        return (nums.max() ?? 0) + 1
    }

    func outfitDirectory(for outfit: Outfit) -> URL {
        outfitsDir.appendingPathComponent(outfit.folder, isDirectory: true)
    }

    func frameURL(for outfit: Outfit, index: Int) -> URL {
        let dir = outfitDirectory(for: outfit)
        let padded = String(format: "%05d", index)
        return dir.appendingPathComponent("\(outfit.prefix)\(padded).\(outfit.normalizedFrameExt)")
    }

    func previewURL(for outfit: Outfit) -> URL {
        outfitDirectory(for: outfit).appendingPathComponent("\(previewFileName).webp")
    }

    func hasAssets(for outfit: Outfit) -> Bool {
        if outfit.resolvedRemoteBaseURL != nil {
            return true
        }
        let dir = outfitDirectory(for: outfit)
        guard fileManager.fileExists(atPath: dir.path) else { return false }
        return fileManager.fileExists(atPath: previewURL(for: outfit).path) ||
            fileManager.fileExists(atPath: frameURL(for: outfit, index: 0).path)
    }

    func saveFrame(_ imageData: Data, outfit: Outfit, index: Int) throws {
        let dir = outfitDirectory(for: outfit)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = frameURL(for: outfit, index: index)
        try imageData.write(to: url)
    }

    func savePreview(_ imageData: Data, outfit: Outfit) throws {
        let dir = outfitDirectory(for: outfit)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try imageData.write(to: previewURL(for: outfit))
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

    func loadOutfits() -> [Outfit] {
        guard let data = try? Data(contentsOf: metadataFile),
              let outfitData = try? JSONDecoder().decode(OutfitData.self, from: data) else {
            return []
        }
        return outfitData.outfits
    }

    func saveOutfit(_ outfit: Outfit) {
        var outfits = loadOutfits()
        outfits.removeAll { $0.id == outfit.id }
        outfits.append(outfit)
        let data = OutfitData(outfits: outfits)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile)
        }
    }

    func deleteOutfitData(for outfit: Outfit) {
        let dir = outfitDirectory(for: outfit)
        try? fileManager.removeItem(at: dir)

        var outfits = loadOutfits()
        outfits.removeAll { $0.id == outfit.id }
        let data = OutfitData(outfits: outfits)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: metadataFile)
        }

        deleteFeedPosts(forOutfitID: outfit.id)
    }

    func loadFeedPosts() -> [FeedPost] {
        guard let data = try? Data(contentsOf: feedMetadataFile),
              let feedData = try? JSONDecoder().decode(FeedData.self, from: data) else {
            return []
        }
        return feedData.posts
    }

    func saveFeedPost(_ post: FeedPost) {
        var posts = loadFeedPosts()
        posts.removeAll { $0.id == post.id || $0.outfitId == post.outfitId }
        posts.insert(post, at: 0)
        let data = FeedData(posts: posts)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: feedMetadataFile)
        }
    }

    func deleteFeedPosts(forOutfitID outfitId: String) {
        var posts = loadFeedPosts()
        posts.removeAll { $0.outfitId == outfitId }
        let data = FeedData(posts: posts)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: feedMetadataFile)
        }
    }

    func savePendingReview(_ review: PersistedPipelineReview) {
        guard let encoded = try? JSONEncoder().encode(review) else { return }
        try? encoded.write(to: pendingReviewFile)
    }

    func loadPendingReview() -> PersistedPipelineReview? {
        guard let data = try? Data(contentsOf: pendingReviewFile),
              let review = try? JSONDecoder().decode(PersistedPipelineReview.self, from: data) else {
            return nil
        }

        guard hasAssets(for: review.stagedOutfit) else {
            clearPendingReview()
            return nil
        }

        return review
    }

    func clearPendingReview() {
        try? fileManager.removeItem(at: pendingReviewFile)
    }

    func storageUsed() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: outfitsDir, includingPropertiesForKeys: [.fileSizeKey]) else {
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
}

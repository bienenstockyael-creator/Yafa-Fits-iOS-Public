import Foundation
@testable import Yafa

enum TestHelpers {
    static func makeOutfit(
        id: String = "outfit-test-\(UUID().uuidString)",
        folder: String? = nil,
        localOwnerUserId: String? = nil
    ) -> Outfit {
        let resolvedFolder = folder ?? id
        return Outfit(
            id: id,
            name: "Test Outfit",
            date: "2026-05-05",
            frameCount: 1,
            folder: resolvedFolder,
            prefix: "\(resolvedFolder)_",
            frameExt: "webp",
            remoteBaseURL: nil,
            scale: nil,
            isRotationReversed: false,
            tags: [],
            activity: nil,
            weather: nil,
            products: [],
            caption: nil,
            location: nil,
            localOwnerUserId: localOwnerUserId
        )
    }

    static func makePersistedReview(outfit: Outfit) -> PersistedPipelineReview {
        PersistedPipelineReview(
            id: "review-\(outfit.id)",
            outfitNum: outfit.outfitNumber ?? 1,
            stagedOutfit: outfit,
            uploadWeather: nil,
            uploadLocation: nil,
            isRotationReversed: false,
            sourceImagePath: nil,
            serverJobId: nil,
            prompt: UploadConfig.defaultPrompt,
            persistedAt: Date(timeIntervalSince1970: 1234),
            statusTitle: "Ready",
            statusDetail: "Ready for review."
        )
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var legacyOutfitsRoot: URL {
        documentsDirectory.appendingPathComponent("outfits", isDirectory: true)
    }

    static var legacyMetadataFile: URL {
        documentsDirectory.appendingPathComponent("local-outfits.json")
    }

    static var legacyFeedMetadataFile: URL {
        documentsDirectory.appendingPathComponent("local-feed.json")
    }

    static var legacyPendingReviewFile: URL {
        documentsDirectory.appendingPathComponent("pending-generation-review.json")
    }
}

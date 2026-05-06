import XCTest
@testable import Yafa

final class StateScopingTests: XCTestCase {
    private let localStore = LocalOutfitStore.shared

    override func tearDown() {
        super.tearDown()
        localStore.removeLegacyData()
    }

    func testNotificationReadStateIsScopedPerUser() {
        let userA = UUID()
        let userB = UUID()
        let dateA = Date(timeIntervalSince1970: 100)
        let dateB = Date(timeIntervalSince1970: 200)

        NotificationReadState.clear(for: userA)
        NotificationReadState.clear(for: userB)

        NotificationReadState.markSeen(for: userA, at: dateA)
        NotificationReadState.markSeen(for: userB, at: dateB)

        XCTAssertEqual(NotificationReadState.lastSeenDate(for: userA), dateA)
        XCTAssertEqual(NotificationReadState.lastSeenDate(for: userB), dateB)
    }

    func testBeginSessionResetsStateWhenSwitchingUsers() {
        let userA = UUID()
        let userB = UUID()
        let store = OutfitStore()
        let outfit = TestHelpers.makeOutfit(id: "outfit-a")

        store.userId = userA
        store.outfits = [outfit]
        store.feedPosts = [
            FeedPost(
                id: "feed-1",
                authorName: "A",
                outfitId: outfit.id,
                caption: nil,
                height: nil,
                size: nil,
                profileImage: nil,
                avatarUrl: nil,
                authorId: nil,
                isAuthorPro: nil,
                createdAt: nil
            )
        ]
        store.uploadJob = PipelineJob(outfitNum: 1)
        store.likedIds = ["liked"]
        store.savedIds = ["saved"]
        store.followingIds = [UUID()]
        store.selectedOutfitId = outfit.id
        store.centeredListOutfitId = outfit.id
        store.pendingCalendarScrollOutfitId = outfit.id
        store.listOutfitFrames = [outfit.id: .zero]
        store.calendarOutfitFrames = [outfit.id: .zero]
        store.listOutfitFrameIndices = [outfit.id: 0]
        store.heroAnchorOutfitId = outfit.id
        store.viewTransitionPhase = .targetIn
        store.generationReadyForReview = true
        store.isCarouselOpen = true
        store.unreadNotificationCount = 3
        store.currentProfile = Profile(id: UUID(), username: "alpha", displayName: "Alpha")
        store.feedOutfitCache = [outfit.id: outfit]

        store.beginSession(for: userB)

        XCTAssertEqual(store.userId, userB)
        XCTAssertTrue(store.outfits.isEmpty)
        XCTAssertTrue(store.feedPosts.isEmpty)
        XCTAssertNil(store.uploadJob)
        XCTAssertTrue(store.likedIds.isEmpty)
        XCTAssertTrue(store.savedIds.isEmpty)
        XCTAssertTrue(store.followingIds.isEmpty)
        XCTAssertTrue(store.isLoading)
        XCTAssertNil(store.selectedOutfitId)
        XCTAssertNil(store.centeredListOutfitId)
        XCTAssertNil(store.pendingCalendarScrollOutfitId)
        XCTAssertTrue(store.listOutfitFrames.isEmpty)
        XCTAssertTrue(store.calendarOutfitFrames.isEmpty)
        XCTAssertTrue(store.listOutfitFrameIndices.isEmpty)
        XCTAssertNil(store.heroAnchorOutfitId)
        XCTAssertEqual(store.viewTransitionPhase, .idle)
        XCTAssertFalse(store.generationReadyForReview)
        XCTAssertFalse(store.isCarouselOpen)
        XCTAssertEqual(store.unreadNotificationCount, 0)
        XCTAssertNil(store.currentProfile)
        XCTAssertTrue(store.feedOutfitCache.isEmpty)
    }

    func testApplyFreshSocialDataClearsEmptyCollections() {
        let userId = UUID()
        let store = OutfitStore()
        store.userId = userId
        store.likedIds = ["liked"]
        store.savedIds = ["saved"]
        store.followingIds = [UUID()]

        store.applyFreshSocialData(
            liked: [],
            saved: [],
            profile: nil,
            following: [],
            for: userId
        )

        XCTAssertTrue(store.likedIds.isEmpty)
        XCTAssertTrue(store.savedIds.isEmpty)
        XCTAssertTrue(store.followingIds.isEmpty)
    }

    func testLocalOutfitsAreScopedPerUser() {
        let userA = UUID()
        let userB = UUID()
        let outfit = TestHelpers.makeOutfit(id: "outfit-scope-\(UUID().uuidString)")

        localStore.removeAllData(userId: userA)
        localStore.removeAllData(userId: userB)

        localStore.saveOutfit(outfit, userId: userA)

        let userAOutfits = localStore.loadOutfits(userId: userA)
        let userBOutfits = localStore.loadOutfits(userId: userB)

        XCTAssertEqual(userAOutfits.count, 1)
        XCTAssertEqual(userAOutfits.first?.localOwnerUserId, userA.uuidString)
        XCTAssertTrue(userBOutfits.isEmpty)
    }

    func testPendingReviewIsScopedPerUser() {
        let userA = UUID()
        let userB = UUID()
        let outfit = TestHelpers.makeOutfit(
            id: "outfit-review-\(UUID().uuidString)",
            localOwnerUserId: userA.uuidString
        )
        let review = TestHelpers.makePersistedReview(outfit: outfit)

        localStore.removeAllData(userId: userA)
        localStore.removeAllData(userId: userB)
        try? FileManager.default.createDirectory(
            at: localStore.outfitDirectory(for: outfit, userId: userA),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: localStore.previewURL(for: outfit, userId: userA).path,
            contents: Data([0x00])
        )

        localStore.savePendingReview(review, userId: userA)

        XCTAssertNotNil(localStore.loadPendingReview(userId: userA))
        XCTAssertNil(localStore.loadPendingReview(userId: userB))
    }

    func testLegacyOutfitsMigrateIntoFirstUserScope() throws {
        let userId = UUID()
        let outfit = TestHelpers.makeOutfit(id: "outfit-legacy-\(UUID().uuidString)")
        let legacyDir = TestHelpers.legacyOutfitsRoot.appendingPathComponent(outfit.folder, isDirectory: true)
        let legacyFrame = legacyDir.appendingPathComponent("\(outfit.prefix)00000.\(outfit.normalizedFrameExt)")

        localStore.removeAllData(userId: userId)
        localStore.removeLegacyData()

        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: legacyFrame.path, contents: Data([0x01, 0x02]))
        let encoded = try XCTUnwrap(try? JSONEncoder().encode(OutfitData(outfits: [outfit])))
        try encoded.write(to: TestHelpers.legacyMetadataFile, options: .atomic)

        let migrated = localStore.loadOutfits(userId: userId)
        let migratedOutfit = try XCTUnwrap(migrated.first)

        XCTAssertEqual(migratedOutfit.localOwnerUserId, userId.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TestHelpers.legacyMetadataFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: localStore.frameURL(for: migratedOutfit, index: 0, userId: userId).path
            )
        )
    }
}

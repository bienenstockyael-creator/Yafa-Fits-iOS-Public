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

    // The previous `testBeginSessionResetsStateWhenSwitchingUsers`
    // was removed when the upload pipeline + view-transition
    // state machine got reworked. It exercised `uploadJob`,
    // `viewTransitionPhase`, and `generationReadyForReview` —
    // properties that no longer exist on `OutfitStore`. The
    // session-reset behavior should still be covered eventually,
    // but a fresh test against the current API would need to
    // re-enumerate the now-reset fields from scratch.

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

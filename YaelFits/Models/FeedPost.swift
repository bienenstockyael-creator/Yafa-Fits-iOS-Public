import Foundation

struct FeedPost: Codable, Identifiable {
    let id: String
    let authorName: String
    let outfitId: String
    var caption: String?
    var height: String?
    var size: String?
    var profileImage: String?
    var avatarUrl: String?
    var authorId: UUID?
    var isAuthorPro: Bool?
    var createdAt: String?

    var publishedDate: Date? {
        guard let createdAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt)
    }

    var profileImageURL: URL? {
        guard let profileImage else { return nil }

        let fileName = profileImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileName.isEmpty == false else { return nil }

        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension
        let ext = nsName.pathExtension.isEmpty ? "png" : nsName.pathExtension
        return Bundle.main.url(forResource: baseName, withExtension: ext)
    }
}

struct FeedData: Codable {
    let posts: [FeedPost]
}

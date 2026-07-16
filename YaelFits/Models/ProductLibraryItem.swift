import Foundation

struct ProductLibraryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let userId: UUID
    let name: String
    let imageURL: String
    let tags: [String]
    let createdAt: Date?
    /// The shop page this product came from (link imports, extension
    /// saves). Rides along when the product is tagged on a fit so BUY
    /// opens the actual shop instead of Google Lens.
    let sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tags
        case userId = "user_id"
        case imageURL = "image_url"
        case createdAt = "created_at"
        case sourceURL = "source_url"
    }

    var displayName: String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

import Foundation

struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarUrl: String?
    var bio: String?
    var isPro: Bool?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case isPro = "is_pro"
        case createdAt = "created_at"
    }

    var displayLabel: String {
        displayName ?? username ?? "User"
    }

    var initial: String {
        String(displayLabel.prefix(1)).uppercased()
    }

    static func sanitizeUsername(_ input: String) -> String {
        let stripped = input.folding(options: .diacriticInsensitive, locale: .current)
        let allowed = stripped.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_"
        }
        return String(String.UnicodeScalarView(allowed))
    }
}

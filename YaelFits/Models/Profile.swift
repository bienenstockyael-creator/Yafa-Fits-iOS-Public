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

    /// Used in places where the display name should be primary
    /// (currently: profile pages, account headers). Falls back to
    /// username, then a generic "User".
    var displayLabel: String {
        displayName ?? username ?? "User"
    }

    /// Instagram-style handle. Used in places where the username is the
    /// canonical identity (feed post author, comments, list items).
    /// Falls back to displayName, then "User", so callers don't need
    /// to special-case missing usernames.
    var handle: String {
        if let u = username, !u.isEmpty { return u }
        if let d = displayName, !d.isEmpty { return d }
        return "User"
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

    /// Generates a default username from the inputs available at signup.
    /// Prefers a sanitized version of the display name; falls back to
    /// the email's local-part; falls back to a `user_<random>` to
    /// guarantee a non-empty value. Used to auto-fill the onboarding
    /// username field so users are never left without a handle.
    static func suggestedUsername(displayName: String?, email: String?) -> String {
        if let name = displayName?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty {
            let sanitized = sanitizeUsername(name)
            if !sanitized.isEmpty { return sanitized }
        }
        if let email = email,
           let local = email.split(separator: "@").first {
            let sanitized = sanitizeUsername(String(local))
            if !sanitized.isEmpty { return sanitized }
        }
        // Last-resort guarantee — caller should treat this as a draft
        // and prompt the user to customize.
        let suffix = String(Int.random(in: 1000...9999))
        return "user\(suffix)"
    }
}

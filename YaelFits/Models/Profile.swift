import Foundation

struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarUrl: String?
    var bio: String?
    var isPro: Bool?
    var createdAt: Date?
    /// SHA-256 hash of the user's normalized E.164 phone number.
    /// Used internally by the `match_contacts_by_phone` RPC; the
    /// column is REVOKE-d from `SELECT` for authenticated clients
    /// in production, so this property decodes to nil even on the
    /// row owner's own profile fetch. Use `phoneIsSet` for the
    /// "does this user have a phone hash registered?" gate. Kept
    /// here because the WRITE path (UPDATE) still sets it
    /// server-side; the local mirror is harmless but stale.
    var phoneE164Hash: String?
    /// Server-maintained boolean (generated column on the profiles
    /// table). True iff the user has a phone-number hash on file.
    /// Drives the "ask the user for their phone" UX without leaking
    /// the hash itself.
    var phoneIsSet: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case isPro = "is_pro"
        case createdAt = "created_at"
        case phoneE164Hash = "phone_e164_hash"
        case phoneIsSet = "phone_is_set"
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

import UIKit

struct AvatarService {
    static func uploadAvatar(_ image: UIImage, userId: UUID) async throws -> String {
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            throw AvatarError.compressionFailed
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let filePath = "\(userId.uuidString)/avatar-\(timestamp).jpg"

        try await supabase.storage
            .from("avatars")
            .upload(filePath, data: jpegData, options: .init(contentType: "image/jpeg"))

        let publicURL = try supabase.storage
            .from("avatars")
            .getPublicURL(path: filePath)

        let avatarURLString = publicURL.absoluteString

        try await supabase
            .from("profiles")
            .update(["avatar_url": avatarURLString])
            .eq("id", value: userId.uuidString)
            .execute()

        return avatarURLString
    }

    /// Uploads the background-removed PNG version of a user's
    /// avatar to the `avatars` bucket and returns the public URL.
    /// Used by the profile header `bust` style.
    ///
    /// Stored under a `cutout-` prefix at a fresh timestamped
    /// path so caching layers (CDN, AsyncImage) treat it as a
    /// distinct asset from the source avatar. Doesn't write to
    /// the `profiles` row — the customize flow handles that as
    /// part of a wider profile update (saving style + color in
    /// the same call).
    static func uploadAvatarCutout(_ image: UIImage, userId: UUID) async throws -> String {
        guard let pngData = image.pngData() else {
            throw AvatarError.compressionFailed
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let filePath = "\(userId.uuidString)/cutout-\(timestamp).png"

        try await supabase.storage
            .from("avatars")
            .upload(filePath, data: pngData, options: .init(contentType: "image/png"))

        let publicURL = try supabase.storage
            .from("avatars")
            .getPublicURL(path: filePath)

        return publicURL.absoluteString
    }
}

enum AvatarError: LocalizedError {
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Failed to compress image."
        }
    }
}

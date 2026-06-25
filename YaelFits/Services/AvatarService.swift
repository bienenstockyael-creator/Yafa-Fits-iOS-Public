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

    /// Generates a transparent "bust" cut-out from the SQUARE crop the user
    /// framed (the un-clipped square from `AvatarCropView`, NOT the circle
    /// avatar) and persists it as `avatar_cutout_url` on their profile.
    ///
    /// Run on EVERY avatar change so a real, square-sourced bust is always on
    /// file — used by the profile-header bust style, the Best Dressed
    /// leaderboard, and share cards — regardless of which header style the user
    /// picked. Generating from the square (not the stored circle avatar) is what
    /// keeps the shoulders/hair intact: background-removing the circle-clipped
    /// avatar would bake the circle outline into the cut-out.
    ///
    /// Best-effort and safe to call fire-and-forget: returns the new URL on
    /// success, nil on any failure (the bust then falls back to the framed
    /// circle avatar). Runs the FAL bg-removal, so it's slow — call it off the
    /// critical path after the avatar itself is already live.
    @discardableResult
    static func generateAndStoreCutout(from squareCrop: UIImage, userId: UUID) async -> String? {
        guard let jpegData = squareCrop.jpegData(compressionQuality: 0.92) else { return nil }
        do {
            let pngData = try await FalBackgroundRemovalService.shared
                .removeBackground(from: jpegData) { _ in }
            guard let cutout = UIImage(data: pngData) else { return nil }
            let url = try await uploadAvatarCutout(cutout, userId: userId)
            try await supabase
                .from("profiles")
                .update(["avatar_cutout_url": url])
                .eq("id", value: userId.uuidString)
                .execute()
            return url
        } catch {
            return nil
        }
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

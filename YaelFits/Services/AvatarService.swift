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

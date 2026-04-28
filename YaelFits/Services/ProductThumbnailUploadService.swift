import UIKit

/// Uploads an auto-generated product thumbnail to the `products` Supabase
/// Storage bucket and returns the public URL string.
struct ProductThumbnailUploadService {
    static func upload(_ image: UIImage, userId: UUID) async throws -> String {
        guard let pngData = image.pngData() else {
            throw ProductThumbnailUploadError.compressionFailed
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filePath = "\(userId.uuidString)/auto-\(timestamp).png"

        try await supabase.storage
            .from("products")
            .upload(filePath, data: pngData, options: .init(contentType: "image/png"))

        let publicURL = try supabase.storage
            .from("products")
            .getPublicURL(path: filePath)

        return publicURL.absoluteString
    }
}

enum ProductThumbnailUploadError: LocalizedError {
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "Failed to compress thumbnail."
        }
    }
}

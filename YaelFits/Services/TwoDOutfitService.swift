import Foundation

/// Uploads the single PNG frame for a 2D outfit to the
/// `outfit-2d-frames` public bucket and returns the base URL that
/// should be stored as `Outfit.remoteBaseURL`.
///
/// Layout: <userId>/<outfit-id>/00000.png. The returned base URL is
/// `<bucket-public-root>/<userId>` so combined with
/// `Outfit.framePath(0)` ("outfit-id/00000.png") the renderer
/// resolves to the correct file.
struct TwoDOutfitService {
    static func uploadFrame(_ imageData: Data, outfitId: String, userId: UUID) async throws -> String {
        // Lowercase the user UUID — Postgres's auth.uid()::text comes
        // back lowercase and the bucket's RLS policy compares directly
        // against that. If we send Swift's default uppercase UUID, RLS
        // denies the upload and remote_base_url stays NULL.
        let userIdString = userId.uuidString.lowercased()
        let filePath = "\(userIdString)/\(outfitId)/00000.png"

        try await supabase.storage
            .from("outfit-2d-frames")
            .upload(filePath, data: imageData, options: .init(contentType: "image/png", upsert: true))

        let publicURL = try supabase.storage
            .from("outfit-2d-frames")
            .getPublicURL(path: filePath)

        // Strip "/<outfit-id>/00000.png" to get the per-user base URL.
        let baseURL = publicURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return baseURL.absoluteString
    }
}

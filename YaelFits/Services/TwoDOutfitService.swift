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

    /// `uploadFrame` with 3 attempts (1.5s backoff). Returns nil when
    /// every attempt fails — the caller decides what a frameless
    /// outfit is allowed to do (it must never be published).
    static func uploadFrameWithRetry(
        _ imageData: Data,
        outfitId: String,
        userId: UUID
    ) async -> String? {
        for attempt in 1...3 {
            do {
                return try await uploadFrame(imageData, outfitId: outfitId, userId: userId)
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        return nil
    }

    /// Launch heal: finds the user's local 2D outfits whose frame
    /// upload silently failed (frameCount == 1, no remoteBaseURL, the
    /// PNG still on disk), re-uploads, and repairs both the Supabase
    /// row and the local metadata. This is what un-blanks a card that
    /// already shipped broken — the frame only exists on the author's
    /// device, so only their app can fix it.
    static func healMissingRemoteFrames(userId: UUID) {
        Task.detached(priority: .utility) {
            let outfits = await LocalOutfitStore.shared.loadOutfits(userId: userId)
            let broken = outfits.filter { $0.frameCount == 1 && ($0.remoteBaseURL ?? "").isEmpty }
            guard !broken.isEmpty else { return }
            for outfit in broken {
                let frameURL = await LocalOutfitStore.shared.frameURL(for: outfit, index: 0, userId: userId)
                guard let data = try? Data(contentsOf: frameURL) else { continue }
                guard let base = await uploadFrameWithRetry(data, outfitId: outfit.id, userId: userId) else { continue }

                struct RemoteBaseUpdate: Encodable {
                    let remote_base_url: String
                }
                _ = try? await supabase
                    .from("outfits")
                    .update(RemoteBaseUpdate(remote_base_url: base))
                    .eq("id", value: outfit.id)
                    .eq("user_id", value: userId.uuidString)
                    .execute()

                var healed = outfit
                healed.remoteBaseURL = base
                await LocalOutfitStore.shared.saveOutfit(healed, userId: userId)
                Analytics.log("2d_frames_healed", properties: [
                    "outfit_id": .string(outfit.id),
                ])
            }
        }
    }
}

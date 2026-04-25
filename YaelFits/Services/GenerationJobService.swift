import Foundation

/// Handles all server-side generation job operations:
/// uploading source images, submitting jobs, polling status, and lifecycle management.
actor GenerationJobService {
    static let shared = GenerationJobService()

    // MARK: - Submit

    /// Uploads the source photo to generation-inputs and inserts a generation_jobs row.
    /// Returns the job ID to poll.
    func submitJob(imageData: Data, userId: UUID, outfitNum: Int, prompt: String) async throws -> (jobId: UUID, sourceImagePath: String) {
        // 1. Upload source image to generation-inputs/{userId}/{uuid}.jpg
        let fileName = "\(UUID().uuidString).png"
        let storagePath = "\(userId.uuidString)/\(fileName)"

        try await supabase.storage
            .from("generation-inputs")
            .upload(storagePath, data: imageData, options: .init(contentType: "image/png", upsert: false))

        // 2. Insert job row
        struct JobInsert: Encodable {
            let user_id: String
            let outfit_num: Int
            let prompt: String
            let source_image_path: String
            let status: String
        }

        let insert = JobInsert(
            user_id: userId.uuidString,
            outfit_num: outfitNum,
            prompt: prompt,
            source_image_path: storagePath,
            status: "queued"
        )

        let row = try await supabase
            .from("generation_jobs")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value as GenerationJobRecord

        return (jobId: row.id, sourceImagePath: storagePath)
    }

    /// Re-submits a job using an already-uploaded source image (for retakes).
    func resubmitJob(sourceImagePath: String, userId: UUID, outfitNum: Int, prompt: String) async throws -> UUID {
        struct JobInsert: Encodable {
            let user_id: String
            let outfit_num: Int
            let prompt: String
            let source_image_path: String
            let status: String
        }

        let insert = JobInsert(
            user_id: userId.uuidString,
            outfit_num: outfitNum,
            prompt: prompt,
            source_image_path: sourceImagePath,
            status: "queued"
        )

        let row = try await supabase
            .from("generation_jobs")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value as GenerationJobRecord

        return row.id
    }

    // MARK: - Poll

    func pollJob(jobId: UUID) async throws -> GenerationJobRecord {
        try await supabase
            .from("generation_jobs")
            .select()
            .eq("id", value: jobId.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Lifecycle

    func cancelJob(jobId: UUID) async throws {
        try await supabase
            .from("generation_jobs")
            .update(["status": "cancelled"])
            .eq("id", value: jobId.uuidString)
            .execute()
    }

    func markAccepted(jobId: UUID, isPublished: Bool) async throws {
        let reviewState = isPublished ? "published" : "accepted"
        try await supabase
            .from("generation_jobs")
            .update(["review_state": reviewState])
            .eq("id", value: jobId.uuidString)
            .execute()
    }

    /// Marks a completed-but-unaccepted job as discarded so it stops re-surfacing
    /// in the review screen on next launch.
    func markRejected(jobId: UUID) async throws {
        try await supabase
            .from("generation_jobs")
            .update(["review_state": "rejected"])
            .eq("id", value: jobId.uuidString)
            .execute()
    }

    // MARK: - Restore on launch

    /// Finds the most recent completed-but-unreviewed job for the current user.
    /// Used to restore the review screen after the app was killed or push was tapped.
    func fetchPendingReviewJob(userId: UUID) async throws -> GenerationJobRecord? {
        let rows = try await supabase
            .from("generation_jobs")
            .select()
            .eq("user_id", value: userId.uuidString)
            .eq("status", value: "complete")
            .eq("review_state", value: "pending")
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value as [GenerationJobRecord]

        return rows.first
    }
}

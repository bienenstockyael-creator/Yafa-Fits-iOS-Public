import Foundation
import UIKit

/// Stand-in for the real `GenerationOrchestrator` (step 8). Drives
/// each `PipelineJob` through the phase machine on fake timers,
/// using the user's source image as a stunt double for both the
/// cutout (decision preview) and the staged outfit (review preview).
///
/// Wired into `GenerationQueue` via the `onJobBecameActive` hook so
/// every new or promoted job automatically starts faking. Replace
/// with the real orchestrator when step 8 lands — same surface
/// area (`start` / `cancel` / `make3D` / `saveAs2D` / `accept` /
/// `acceptAndPublish` / `retake`) so RootView's call sites don't
/// need to change.
///
/// **Tuning timing**: edit `Timing` below.
///
/// Not `@MainActor` at the class level — the queue's
/// `onJobBecameActive` callback fires from non-isolated context,
/// so callsites would need to wrap every call in
/// `Task { @MainActor in ... }`. Instead the methods that touch
/// observable state hop to the main actor internally via the
/// Tasks they spawn.
final class FakeGenerationOrchestrator {
    /// Per-phase fake durations. Tweak to feel the UI.
    struct Timing {
        /// `.upload` (rendering2D) → `.fork` (awaiting decision).
        var renderingTo2D: TimeInterval = 2.5
        /// `.generate` (rendering3D) → `.review` (ready to review).
        var renderingTo3D: TimeInterval = 3.5
    }

    var timing = Timing()

    private weak var queue: GenerationQueue?
    private let userIdProvider: () -> UUID?
    /// Called when a job is accepted (2D or 3D path) so the host
    /// store can append the staged outfit to its archive. Without
    /// this, accepted jobs would just leave the queue and never
    /// show up in the grid.
    private let onAcceptOutfit: (Outfit) -> Void
    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        queue: GenerationQueue,
        userIdProvider: @escaping () -> UUID?,
        onAcceptOutfit: @escaping (Outfit) -> Void,
        onPublishOutfit: @escaping (Outfit) -> Void = { _ in }
    ) {
        self.queue = queue
        self.userIdProvider = userIdProvider
        self.onAcceptOutfit = onAcceptOutfit
        _ = onPublishOutfit  // accepted for surface parity with RealGenerationOrchestrator
    }

    // MARK: - Phase entry points (called by GenerationQueue or card actions)

    /// Job just entered `activeJobs`. Start faking the 2D render.
    ///
    /// No `withAnimation` here — the orchestrator runs once per
    /// job, and wrapping each phase change in a transaction
    /// caused N overlapping animation contexts when several jobs
    /// were in flight (the chip / pill stack lagged visibly). The
    /// card's animation is now `.animation(.smooth(0.28), value:
    /// phase)` on the card body — applies only when the card is
    /// mounted (max one at a time), no per-job overhead.
    func start(_ job: PipelineJob) {
        cancel(job)
        tasks[job.id] = Task { @MainActor in
            job.step = .upload
            job.statusTitle = "RENDERING"
            job.statusDetail = "Cooking your fit..."

            try? await Task.sleep(nanoseconds: nanos(timing.renderingTo2D))
            guard !Task.isCancelled else { return }

            // Fake cutout = source image. Good enough for the
            // decision card's preview thumbnail.
            job.cutoutImage = job.sourceImage

            // Advance to decision phase
            job.step = .fork
            job.statusTitle = "READY"
            job.statusDetail = "Save your fit or spin it in 3D."
        }
    }

    /// User tapped "Make 3D" in the decision card.
    func make3D(_ job: PipelineJob) {
        cancel(job)
        tasks[job.id] = Task { @MainActor in
            job.step = .generate
            job.statusTitle = "GENERATING 3D"
            job.statusDetail = "Spinning your fit..."

            try? await Task.sleep(nanoseconds: nanos(timing.renderingTo3D))
            guard !Task.isCancelled else { return }

            stageFakeOutfit(for: job)

            job.step = .review
            job.statusTitle = "READY TO REVIEW"
            job.statusDetail = "Spin's ready to view."
        }
    }

    /// User tapped "Save 2D" in the decision card. Builds the
    /// fake outfit on the fly (the 3D path's `stageFakeOutfit`
    /// hasn't fired yet) and pushes it into the archive.
    func saveAs2D(_ job: PipelineJob) {
        cancel(job)
        if job.stagedOutfit == nil {
            stageFakeOutfit(for: job)
        }
        finalizeIntoArchive(job)
    }

    /// User tapped "Accept" in the review card.
    func accept(_ job: PipelineJob) {
        cancel(job)
        finalizeIntoArchive(job)
    }

    /// User tapped "Accept + Publish to Public" in the review card.
    /// Identical to `accept` in the fake (the actual publish RPC
    /// happens server-side and isn't faked here).
    func acceptAndPublish(_ job: PipelineJob) {
        cancel(job)
        finalizeIntoArchive(job)
    }

    /// Push the job's staged outfit into the host archive and
    /// remove the job from the queue.
    private func finalizeIntoArchive(_ job: PipelineJob) {
        if let outfit = job.stagedOutfit {
            onAcceptOutfit(outfit)
        }
        queue?.complete(job)
    }

    /// User tapped "Retake" in the review card. Resets the job and
    /// reruns the fake pipeline.
    func retake(_ job: PipelineJob) {
        cancel(job)
        job.cutoutImage = nil
        job.stagedOutfit = nil
        start(job)
    }

    /// Stops any in-flight fake task for this job. Called by the
    /// queue's `cancel(_:)` and whenever we transition phases.
    func cancel(_ job: PipelineJob) {
        tasks[job.id]?.cancel()
        tasks.removeValue(forKey: job.id)
    }

    // MARK: - Fakes

    /// Creates a single-frame `Outfit` backed by the job's source
    /// image and persists it to `LocalOutfitStore` so the review
    /// card's `RotatableOutfitImage` can render it. Without disk
    /// frames, the review card would just show the empty preview
    /// placeholder.
    private func stageFakeOutfit(for job: PipelineJob) {
        guard let userId = userIdProvider(),
              let sourceData = job.sourceImage else { return }

        let outfitId = "outfit-\(userId.uuidString.prefix(8))-\(job.outfitNum)"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let outfit = Outfit(
            id: outfitId,
            name: "Outfit \(job.outfitNum)",
            date: dateFormatter.string(from: Date()),
            frameCount: 1,
            folder: outfitId,
            prefix: "",
            frameExt: "jpg",
            remoteBaseURL: nil,
            scale: 1.0,
            isRotationReversed: false,
            tags: nil,
            activity: nil,
            weather: job.uploadWeather,
            products: nil,
            caption: nil,
            location: job.uploadLocation,
            localOwnerUserId: userId.uuidString
        )

        try? LocalOutfitStore.shared.saveFrame(sourceData, outfit: outfit, userId: userId, index: 0)
        try? LocalOutfitStore.shared.savePreview(sourceData, outfit: outfit, userId: userId)

        job.stagedOutfit = outfit
    }

    private func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}

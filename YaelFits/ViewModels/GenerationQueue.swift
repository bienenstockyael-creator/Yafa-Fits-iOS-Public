import Foundation
import Observation
import SwiftUI
import UIKit

/// Tunable knobs for the generation queue. Promoted to its own type
/// so concurrency cap (and any future limits) live in one place —
/// when the backend gets more remote workers we just raise
/// `maxConcurrent` here.
enum GenerationConfig {
    /// Maximum number of generations that can run in parallel.
    /// Anything beyond this sits in `GenerationQueue.waitingJobs`
    /// until a slot frees up. The pill stack UI is sized for this
    /// number — bumping it past 3 means revisiting the pill layout.
    static let maxConcurrent: Int = 3
}

/// User-facing phase of a generation job. Derived from
/// `PipelineJob.step` + the queue's active/waiting split, surfaced as
/// the cute one-liner shown on the pill and inside the placeholder
/// card. Single mapping point so the pill, placeholder card, and any
/// future surface (notifications, debug overlay) stay in sync.
enum GenerationPhase {
    case queued            // sitting in waitingJobs behind the concurrency cap
    case rendering2D       // Bria + initial pipeline
    case awaitingDecision  // user picks Save 2D vs Make 3D
    case rendering3D       // Kling rendering after Make 3D
    case readyToReview     // 2D-only or 3D result waiting for Accept
    case done              // accepted, transient state before queue removal

    /// Cute text on the pill and inside the placeholder card. Tone
    /// rules (locked earlier): action-required states use distinct
    /// phrasing so the eye reads them as "needs me," and "your fit"
    /// + "spin" stay consistent vocab across the journey.
    var pillText: String {
        switch self {
        case .queued:           return "Up next in line"
        case .rendering2D:      return "Cooking your fit"
        case .awaitingDecision: return "Save or spin?"
        case .rendering3D:      return "Spinning your fit"
        case .readyToReview:    return "Ready to review"
        case .done:             return "All done"
        }
    }

    /// True when the state requires user input (decision card or
    /// review card). Drives the pill's call-attention bounce + color.
    var needsUserAction: Bool {
        switch self {
        case .awaitingDecision, .readyToReview: return true
        default: return false
        }
    }
}

/// Owns every in-flight generation the user has kicked off.
/// Runs multiple generations in parallel up to
/// `GenerationConfig.maxConcurrent`.
///
/// Responsibility split:
///  - `PipelineJob` (existing) — per-job *state* container. Untouched.
///  - `GenerationQueue` (this file) — *fleet management*: which jobs
///    are running, which are waiting for a slot, lifecycle events
///    (enqueue / cancel / complete), and surfaces the data the UI
///    (pills, placeholder cards, floating review cards) reads from.
///  - `GenerationOrchestrator` (TODO, step 8) — per-job *orchestration*:
///    runs Bria → fork → Kling → poll → review for a single job.
///    The queue will hold one orchestrator task per active job.
///
/// The server is the source of truth for in-flight jobs across app
/// launches — there's no local persistence here. On launch we
/// rehydrate from `GenerationJobService.fetchPendingReviewJob` (and
/// will extend that to fetch *all* pending jobs, not just review).
@Observable
final class GenerationQueue {

    // MARK: - Public state (UI reads these)

    /// Jobs currently running in parallel. Bounded by
    /// `GenerationConfig.maxConcurrent`. Newest enqueued lands at
    /// the *end* of this array — the UI flips that to newest-first
    /// for the placeholder/pill stacks.
    /// Fires whenever a job transitions from waiting → active (or
    /// is enqueued directly into active because there was a slot
    /// free). Wired up to `FakeGenerationOrchestrator.start` so
    /// the fake pipeline kicks off automatically — step 8 swaps
    /// the closure target to the real orchestrator without
    /// touching the queue.
    var onJobBecameActive: ((PipelineJob) -> Void)?

    private(set) var activeJobs: [PipelineJob] = []

    /// Jobs queued behind the concurrency cap. Promoted into
    /// `activeJobs` when a slot frees up via `cancel` or `complete`.
    private(set) var waitingJobs: [PipelineJob] = []

    /// Convenience for badge / pill count. Counts everything the
    /// user has in flight, including waiting jobs.
    var inFlightCount: Int { activeJobs.count + waitingJobs.count }

    /// Progress value for the upload-tab glow ring. Picks the
    /// first active job so the ring tracks the freshest in-flight
    /// generation (others will surface via the pill stack).
    var aggregateUploadProgress: Double {
        guard let job = activeJobs.first else { return 0 }
        switch job.loaderStage {
        case .removingBackground: return 0.12
        case .creatingInteractiveFit: return 0.42
        case .compressing: return min(0.96, 0.5 + (job.progress ?? 0) * 0.46)
        }
    }

    /// True if any job has reached a state that needs user input
    /// (the fork decision card or the 3D review card). Drives the
    /// pill's call-attention bounce.
    var hasJobAwaitingUser: Bool {
        activeJobs.contains { $0.step == .fork || $0.step == .review }
    }

    // MARK: - Dependencies

    /// Used to monotonically allocate per-job `outfitNum`s. The
    /// existing single-job flow read this off OutfitStore; the
    /// queue keeps the same source so numbers stay consistent
    /// across the whole archive.
    private let nextOutfitNumber: () -> Int

    init(nextOutfitNumber: @escaping () -> Int) {
        self.nextOutfitNumber = nextOutfitNumber
    }

    // MARK: - Lifecycle

    /// Kick off a new generation. Returns the freshly-created
    /// `PipelineJob` so the caller (the floating picker) can wire
    /// up callbacks or read its `id` for matched-geometry. The job
    /// either starts running immediately (if a slot is free) or
    /// joins `waitingJobs`.
    ///
    /// Orchestration is intentionally *not* started here yet —
    /// step 8 will plug in `GenerationOrchestrator.start(job:)`.
    /// Until then the job sits at `.upload` step and the placeholder
    /// card / pill UI can be driven manually for testing.
    @discardableResult
    func enqueue(
        sourceImage: Data,
        weather: Weather?,
        location: String?,
        captureMetadata: PhotoMetadata? = nil
    ) -> PipelineJob {
        let job = PipelineJob(outfitNum: nextOutfitNumber())
        job.sourceImage = sourceImage
        job.uploadWeather = weather
        job.uploadLocation = location
        // Camera-roll pick of an older photo: the fit belongs to the
        // day the photo was TAKEN. The orchestrator resolves this
        // into date/location/weather instead of the live fetches.
        if let captureMetadata {
            job.captureDate = captureMetadata.captureDate
            job.captureDayString = captureMetadata.dayString
            job.captureLatitude = captureMetadata.coordinate?.latitude
            job.captureLongitude = captureMetadata.coordinate?.longitude
        }
        job.statusTitle = "Queued"
        job.statusDetail = "Waiting for a worker to pick this up."

        if activeJobs.count < GenerationConfig.maxConcurrent {
            activeJobs.append(job)
            onJobBecameActive?(job)
        } else {
            waitingJobs.append(job)
            // Picked up by `promoteWaitingIfPossible` when a slot frees up.
        }
        return job
    }

    /// Rehydrate a job restored from the server (pending review,
    /// in-flight Kling poll, etc.). The server is the source of
    /// truth across launches, so this is how the queue gets
    /// populated on app cold-start. Bypasses the concurrency cap —
    /// the assumption is the server already accepted the work and
    /// the local app is just catching up to it.
    func adoptFromServer(_ job: PipelineJob) {
        guard !activeJobs.contains(where: { $0.id == job.id }),
              !waitingJobs.contains(where: { $0.id == job.id }) else {
            return
        }
        activeJobs.append(job)
        // Caller is responsible for calling `orchestrator.resume(job)`
        // on in-flight jobs after this — `adoptFromServer` itself
        // can't reach the orchestrator (no callback wired here on
        // purpose: review-ready jobs shouldn't be polled).
    }

    /// User tapped Cancel on a pill / review card. Kills the
    /// server-side worker (Kling jobs are remote, so this is the
    /// only way to actually stop the work) and releases the
    /// reserved credit if there was one. Removes the job from the
    /// queue and promotes the next waiter into its slot.
    func cancel(_ job: PipelineJob) async {
        // Server-side worker kill + credit release.
        if let serverJobId = job.serverJobId {
            // Both calls are intentionally fire-and-forget-on-error.
            // If the server's already finished the work, cancelJob
            // is a no-op and release returns the credit anyway —
            // both RPCs are documented as idempotent.
            try? await GenerationJobService.shared.cancelJob(jobId: serverJobId)
            try? await CreditService.shared.release(jobId: serverJobId)
        }
        remove(job)
    }

    /// Job reached a terminal state and was accepted into the
    /// archive. Frees up its slot for the next waiter.
    func complete(_ job: PipelineJob) {
        remove(job)
    }

    // MARK: - Lookup

    func job(withId id: String) -> PipelineJob? {
        activeJobs.first(where: { $0.id == id })
            ?? waitingJobs.first(where: { $0.id == id })
    }

    /// Resolve the user-facing phase for a job. Reads `PipelineJob.step`
    /// + the queue's active/waiting split. UI surfaces (pill,
    /// placeholder card, decision card) all read through this so the
    /// cute-text mapping has one source of truth.
    func phase(for job: PipelineJob) -> GenerationPhase {
        if waitingJobs.contains(where: { $0.id == job.id }) {
            return .queued
        }
        switch job.step {
        case .upload:   return .rendering2D
        case .fork:     return .awaitingDecision
        case .generate: return .rendering3D
        case .review:   return .readyToReview
        case .complete: return .done
        }
    }

    // MARK: - Internal queue management

    private func remove(_ job: PipelineJob) {
        // Wrap the array mutations in `withAnimation` so the
        // pill / chip's `.transition(.scale + .opacity)` removal
        // actually fires. Callers like `cancel(_:)` run from an
        // async `Task` (the 350ms delay after the card morph) —
        // those state changes happen outside any caller-provided
        // animation context. Without this, SwiftUI saw the array
        // shrink with no animation transaction and removed the
        // view in a hard cut.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            activeJobs.removeAll { $0.id == job.id }
            waitingJobs.removeAll { $0.id == job.id }
        }
        promoteWaitingIfPossible()
    }

    private func promoteWaitingIfPossible() {
        while activeJobs.count < GenerationConfig.maxConcurrent,
              !waitingJobs.isEmpty {
            let next = waitingJobs.removeFirst()
            activeJobs.append(next)
            onJobBecameActive?(next)
        }
    }
}

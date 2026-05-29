import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Production driver for the generation queue — runs each
/// `PipelineJob` through the real pipeline:
///
///     start    → Bria background removal             → `.fork`
///     make3D   → submit Kling, reserve credit, poll  → `.review`
///     saveAs2D → build single-frame outfit locally   → `.review`
///     accept[+ publish] → persist + upload + commit credit
///     retake   → cancel server job, reset, start over
///     cancel   → cancel server job + release credit
///
/// Surface matches `FakeGenerationOrchestrator` so swapping between
/// them is one line in `OutfitStore`. Per-job tasks live in `tasks`
/// so the queue can run multiple in parallel (up to
/// `GenerationConfig.maxConcurrent`); cancelling one doesn't affect
/// the others.
///
/// Each job owns its own Task in `tasks[job.id]` so cancellation
/// of one generation doesn't tear down the others.
/// Not `@MainActor`-isolated at the class level so it can be
/// instantiated lazily from `OutfitStore` (nonisolated) and
/// receive `GenerationQueue.onJobBecameActive` callbacks from
/// the queue's non-isolated methods. All state mutations on
/// `PipelineJob` happen inside `Task { @MainActor in ... }` or
/// inside `@MainActor` private helpers explicitly hopped to.
final class RealGenerationOrchestrator {
    private weak var queue: GenerationQueue?
    private let userIdProvider: () -> UUID?
    private let onAcceptOutfit: (Outfit) -> Void
    private let onPublishOutfit: (Outfit) -> Void
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Active background-task identifier, reference-counted so
    /// multiple jobs in flight share a single OS task. Replaces
    /// the `GenerationBackgroundActivity` singleton which lives
    /// outside this repo.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskRefCount: Int = 0

    init(
        queue: GenerationQueue,
        userIdProvider: @escaping () -> UUID?,
        onAcceptOutfit: @escaping (Outfit) -> Void,
        onPublishOutfit: @escaping (Outfit) -> Void
    ) {
        self.queue = queue
        self.userIdProvider = userIdProvider
        self.onAcceptOutfit = onAcceptOutfit
        self.onPublishOutfit = onPublishOutfit
    }

    // MARK: - Phase entry points

    /// Job just entered `activeJobs`. Run Bria → `.fork`.
    func start(_ job: PipelineJob) {
        cancel(job)
        guard let imageData = job.sourceImage else { return }
        tasks[job.id] = Task { @MainActor in
            await processAndGenerate(job: job, imageData: imageData)
        }
    }

    /// Re-attach polling to a job that was already submitted to the
    /// server (i.e. has a `serverJobId`). Used by restore-on-launch
    /// when the user kills the app mid-3D-render — the server-side
    /// Kling worker keeps generating, and this picks the result back
    /// up once the app comes back. No-op for jobs without a server
    /// job id (those weren't submitted yet, can't recover).
    func resume(_ job: PipelineJob) {
        cancel(job)
        guard let serverJobId = job.serverJobId else { return }
        // If the job's already at review (restored via the pending-
        // review fetch), there's nothing to poll — just leave it as
        // a sitting-in-queue review card waiting for accept.
        guard job.step != .review else { return }

        tasks[job.id] = Task { @MainActor in
            self.beginBackgroundActivity()
            job.isProcessing = true
            job.statusTitle = "GENERATING 3D"
            job.statusDetail = "Spinning your fit..."
            await self.runPollingLoop(jobId: serverJobId, job: job)
        }
    }

    /// User tapped "Generate 3D". Submit + reserve credit + poll.
    func make3D(_ job: PipelineJob) {
        cancel(job)
        guard let userId = userIdProvider(),
              let greenScreenData = job.greenScreenImage else { return }

        tasks[job.id] = Task { @MainActor in
            self.beginBackgroundActivity()
            job.step = .generate
            job.loaderStage = .creatingInteractiveFit
            job.isProcessing = true
            job.error = nil
            job.statusTitle = "GENERATING 3D"
            job.statusDetail = "Spinning your fit..."

            do {
                let (jobId, sourceImagePath) = try await GenerationJobService.shared.submitJob(
                    imageData: greenScreenData,
                    userId: userId,
                    outfitNum: job.outfitNum,
                    prompt: job.prompt
                )
                job.serverJobId = jobId
                job.sourceImagePath = sourceImagePath

                let source = try await CreditService.shared.reserve(jobId: jobId)
                if source == .none {
                    try? await GenerationJobService.shared.cancelJob(jobId: jobId)
                    throw UploadPipelineError.outOfCredits
                }

                await runPollingLoop(jobId: jobId, job: job)
            } catch is CancellationError {
                self.endBackgroundActivity()
            } catch {
                if let serverJobId = job.serverJobId {
                    try? await CreditService.shared.release(jobId: serverJobId)
                }
                job.isProcessing = false
                if let pipelineError = error as? UploadPipelineError,
                   case .outOfCredits = pipelineError {
                    job.step = .fork  // back to the fork so user can pick 2D
                }
                job.error = self.readableError(error)
                self.endBackgroundActivity()
            }
        }
    }

    /// User tapped "Save 2D" in the decision chin. Build the
    /// single-frame outfit AND finalize immediately — 2D is the
    /// "fast path" so it skips the review step and goes straight
    /// to the archive.
    func saveAs2D(_ job: PipelineJob) {
        cancel(job)
        guard let userId = userIdProvider(), let cutoutData = job.cutoutImage else { return }
        tasks[job.id] = Task { @MainActor in
            // Block briefly on weather/location if they haven't
            // landed yet — a fast 2D tap can beat the parallel
            // fetch from `start`, and the outfit deserves its tags.
            if job.uploadWeather == nil || job.uploadLocation == nil {
                async let fetchedWeather = UploadWeatherService.shared.fetchCurrentWeather()
                async let fetchedLocation = UploadWeatherService.shared.fetchCurrentLocationName()
                let (weather, location) = await (fetchedWeather, fetchedLocation)
                if job.uploadWeather == nil { job.uploadWeather = weather }
                if job.uploadLocation == nil { job.uploadLocation = location }
            }
            self.build2DOutfit(job: job, userId: userId, cutoutData: cutoutData)
            if job.stagedOutfit != nil {
                self.finalize(job: job, publishToFeed: false)
            }
        }
    }

    /// User tapped "Accept" in the review card.
    func accept(_ job: PipelineJob) {
        cancel(job)
        tasks[job.id] = Task { @MainActor in
            self.finalize(job: job, publishToFeed: false)
        }
    }

    /// User tapped "Accept & Publish to Feed" in the review card.
    func acceptAndPublish(_ job: PipelineJob) {
        cancel(job)
        tasks[job.id] = Task { @MainActor in
            self.finalize(job: job, publishToFeed: true)
        }
    }

    /// User tapped "Regenerate" in the review card. Resubmit Kling
    /// against the same `sourceImagePath`.
    func retake(_ job: PipelineJob) {
        cancel(job)
        guard let userId = userIdProvider(),
              let sourceImagePath = job.sourceImagePath else {
            // No saved source — restart from the original image.
            tasks[job.id] = Task { @MainActor in
                job.cutoutImage = nil
                job.greenScreenImage = nil
                job.stagedOutfit = nil
                job.serverJobId = nil
            }
            start(job)
            return
        }

        tasks[job.id] = Task { @MainActor in
            self.beginBackgroundActivity()
            if let prev = job.stagedOutfit {
                Task { await FrameLoader.shared.evict(outfit: prev) }
            }

            job.step = .generate
            job.loaderStage = .removingBackground
            job.isRotationReversed = false
            job.error = nil
            job.isProcessing = true
            job.videoURL = nil
            job.stagedOutfit = nil
            job.progress = nil
            job.logLines = []
            job.serverJobId = nil
            job.statusTitle = "GENERATING 3D"
            job.statusDetail = "Spinning your fit again..."

            do {
                let jobId = try await GenerationJobService.shared.resubmitJob(
                    sourceImagePath: sourceImagePath,
                    userId: userId,
                    outfitNum: job.outfitNum,
                    prompt: job.prompt
                )
                job.serverJobId = jobId
                await runPollingLoop(jobId: jobId, job: job)
            } catch is CancellationError {
                self.endBackgroundActivity()
            } catch {
                job.isProcessing = false
                job.error = self.readableError(error)
                self.endBackgroundActivity()
            }
        }
    }

    /// Cancel the in-flight task, release any reserved credit, and
    /// remove the orchestrator's per-job state. Does NOT touch the
    /// queue — the queue's own `cancel(_:)` handles removal.
    func cancel(_ job: PipelineJob) {
        tasks[job.id]?.cancel()
        tasks.removeValue(forKey: job.id)
    }

    // MARK: - Pipeline (private)

    @MainActor
    private func processAndGenerate(job: PipelineJob, imageData: Data) async {
        do {
            guard userIdProvider() != nil else {
                throw UploadPipelineError.invalidImage
            }

            job.step = .upload
            job.loaderStage = .removingBackground
            job.isProcessing = true
            job.error = nil
            job.statusTitle = "RENDERING"
            job.statusDetail = "Cooking your fit..."

            // Fire weather + location in parallel with Bria so they're
            // ready by the time the user reaches review.
            Task { [weak job] in
                async let weatherTask = UploadWeatherService.shared.fetchCurrentWeather()
                async let locationTask = UploadWeatherService.shared.fetchCurrentLocationName()
                let (weather, location) = await (weatherTask, locationTask)
                await MainActor.run {
                    job?.uploadWeather = weather
                    job?.uploadLocation = location
                }
            }

            beginBackgroundActivity()
            let preparedAssets = try await ImageMaskingService.shared.prepareUploadAssets(
                from: imageData,
                using: .falBria
            ) { _, _ in
                // Ignore the service's progress strings — they leak
                // backend names (e.g. "QUEUED AT FAL BRIA"). Keep
                // the mysterious copy set above.
            }

            job.cutoutImage = preparedAssets.cutoutPNGData
            job.greenScreenImage = preparedAssets.greenScreenPNGData
            job.step = .fork
            job.isProcessing = false
            job.statusTitle = "READY"
            job.statusDetail = "Save your fit or spin it in 3D."
            endBackgroundActivity()
        } catch is CancellationError {
            endBackgroundActivity()
        } catch {
            job.isProcessing = false
            job.error = readableError(error)
            endBackgroundActivity()
        }
    }

    /// Polls the server job every 4s, updates `job` as records
    /// arrive, lands on `.review` when terminal.
    @MainActor
    private func runPollingLoop(jobId: UUID, job: PipelineJob) async {
        var lastRecord: GenerationJobRecord?
        do {
            while true {
                try Task.checkCancellation()
                let record = try await GenerationJobService.shared.pollJob(jobId: jobId)
                lastRecord = record
                applyJobRecord(record, to: job)
                if record.isTerminal { break }
                try await Task.sleep(for: .seconds(4))
            }

            guard let record = lastRecord else { return }

            if record.isReviewReady, var remoteOutfit = record.remoteOutfit {
                remoteOutfit.isRotationReversed = false
                let localDateFormatter = DateFormatter()
                localDateFormatter.dateFormat = "yyyy-MM-dd"
                remoteOutfit.date = localDateFormatter.string(from: Date())
                if remoteOutfit.weather == nil { remoteOutfit.weather = job.uploadWeather }
                if remoteOutfit.location == nil, let uploadLocation = job.uploadLocation {
                    remoteOutfit.location = uploadLocation
                }
                if !job.autoDetectedProducts.isEmpty {
                    let existing = remoteOutfit.products ?? []
                    remoteOutfit.products = existing + job.autoDetectedProducts
                }
                job.stagedOutfit = remoteOutfit
                job.step = .review
                job.isProcessing = false
                job.progress = nil
                job.error = nil
                job.statusTitle = "READY TO REVIEW"
                job.statusDetail = "Spin's ready to view."
                persistPendingReviewIfNeeded(for: job)
                endBackgroundActivity()
                sendGenerationCompleteNotificationIfNeeded()
            } else {
                Task { try? await CreditService.shared.release(jobId: jobId) }
                job.isProcessing = false
                job.error = record.error ?? "Generation did not complete."
                endBackgroundActivity()
            }
        } catch is CancellationError {
            endBackgroundActivity()
        } catch {
            try? await CreditService.shared.release(jobId: jobId)
            job.isProcessing = false
            job.error = readableError(error)
            endBackgroundActivity()
        }
    }

    @MainActor
    private func applyJobRecord(_ record: GenerationJobRecord, to job: PipelineJob) {
        job.loaderStage = record.loaderStage
        // Don't pull `statusTitle` / `statusDetail` off the record
        // — server-side text leaks backend names. Keep the
        // mysterious phase copy ("GENERATING 3D" / "Spinning your
        // fit...") that was set when the phase began.
        if let progress = record.progress { job.progress = progress }
        if let err = record.error         { job.error    = err }
    }

    @MainActor
    private func build2DOutfit(job: PipelineJob, userId: UUID, cutoutData: Data) {
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
            frameExt: "png",
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

        do {
            try LocalOutfitStore.shared.saveFrame(cutoutData, outfit: outfit, userId: userId, index: 0)
            try LocalOutfitStore.shared.savePreview(cutoutData, outfit: outfit, userId: userId)
        } catch {
            job.error = "Couldn't save 2D frame locally."
            return
        }

        job.stagedOutfit = outfit
        job.step = .review
        job.isProcessing = false
        job.error = nil
        job.statusTitle = "READY TO REVIEW"
        job.statusDetail = "Your fit is ready."
        persistPendingReviewIfNeeded(for: job)
    }

    /// Accept the staged outfit (+ optionally publish). Adds to the
    /// archive, uploads the 2D frame to the public bucket if needed,
    /// commits the credit, and removes the job from the queue.
    @MainActor
    private func finalize(job: PipelineJob, publishToFeed: Bool) {
        guard let outfit = job.stagedOutfit else { return }

        var finalizedOutfit = outfit
        finalizedOutfit.isRotationReversed = job.isRotationReversed
        if finalizedOutfit.weather == nil { finalizedOutfit.weather = job.uploadWeather }
        if finalizedOutfit.location == nil, let uploadLocation = job.uploadLocation {
            finalizedOutfit.location = uploadLocation
        }

        onAcceptOutfit(finalizedOutfit)
        if publishToFeed {
            onPublishOutfit(finalizedOutfit)
        }
        job.resultOutfitId = finalizedOutfit.id
        job.resultFrameCount = finalizedOutfit.frameCount
        job.publishedToFeed = publishToFeed
        job.step = .complete
        job.isProcessing = false
        job.progress = nil
        job.statusTitle = publishToFeed ? "Saved and published" : "Complete"

        if let userId = userIdProvider() {
            LocalOutfitStore.shared.clearPendingReview(userId: userId)
        }
        endBackgroundActivity()

        if let userId = userIdProvider() {
            let needs2DUpload = finalizedOutfit.frameCount == 1 && finalizedOutfit.remoteBaseURL == nil
            let cutoutData = job.cutoutImage
            Task {
                var outfitToSave = finalizedOutfit
                if needs2DUpload, let cutoutData {
                    do {
                        let base = try await TwoDOutfitService.uploadFrame(
                            cutoutData,
                            outfitId: outfitToSave.id,
                            userId: userId
                        )
                        outfitToSave.remoteBaseURL = base
                    } catch {
                        // Bucket upload failed — local copy still persists.
                    }
                }
                // Last-resort weather/location fetch in case the
                // `start` task missed them (location denied, slow
                // network) so the persisted outfit at least gets
                // a chance at the tags.
                if outfitToSave.weather == nil {
                    outfitToSave.weather = await UploadWeatherService.shared.fetchCurrentWeather()
                }
                if outfitToSave.location == nil {
                    outfitToSave.location = await UploadWeatherService.shared.fetchCurrentLocationName()
                }
                try? await OutfitService.saveArchiveOutfit(outfitToSave, userId: userId, isPublic: publishToFeed)
            }
        }

        if let serverJobId = job.serverJobId {
            Task {
                try? await CreditService.shared.commit(jobId: serverJobId)
                try? await GenerationJobService.shared.markAccepted(jobId: serverJobId, isPublished: publishToFeed)
            }
        }

        Task.detached(priority: .utility) {
            await FrameLoader.shared.preloadFirstFrames(outfits: [finalizedOutfit])
        }

        // Delay queue removal until after the card morph completes
        // (~300ms). Without this, the pill / chip slot's removal
        // transition (scale + opacity) plays while the card is still
        // morphing on top of it — by the time the card unmounts,
        // the pill is already gone and the user perceives a hard
        // cut. Matches the existing `onCancel` delay in `RootView`.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.queue?.complete(job)
        }
    }

    @MainActor
    private func persistPendingReviewIfNeeded(for job: PipelineJob) {
        guard let userId = userIdProvider() else { return }
        if let review = PersistedPipelineReview(job: job) {
            LocalOutfitStore.shared.savePendingReview(review, userId: userId)
        } else {
            LocalOutfitStore.shared.clearPendingReview(userId: userId)
        }
    }

    // MARK: - Background activity / notifications

    /// Reference-counted UIBackgroundTask so the OS keeps the
    /// generation alive briefly when the app is backgrounded.
    /// `@MainActor` because `UIApplication` is main-isolated.
    @MainActor
    private func beginBackgroundActivity() {
        backgroundTaskRefCount += 1
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GenerationOrchestrator") { [weak self] in
            Task { @MainActor in self?.endBackgroundActivityForce() }
        }
    }

    @MainActor
    private func endBackgroundActivity() {
        backgroundTaskRefCount = max(0, backgroundTaskRefCount - 1)
        if backgroundTaskRefCount == 0 { endBackgroundActivityForce() }
    }

    @MainActor
    private func endBackgroundActivityForce() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        backgroundTaskRefCount = 0
    }

    @MainActor
    private func sendGenerationCompleteNotificationIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your interactive fit is ready ✨"
        content.body = "Tap to review and add it to your archive."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "generation-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Errors

    private func readableError(_ error: Error) -> String {
        if let uploadError = error as? UploadPipelineError,
           let description = uploadError.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }
}

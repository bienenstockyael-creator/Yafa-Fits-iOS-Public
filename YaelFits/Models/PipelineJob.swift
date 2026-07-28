import Foundation

enum PipelineStep: String, CaseIterable {
    case upload = "Upload"
    /// User picks 2D-or-3D after Bria removes the background. 3D path
    /// continues to .generate; 2D path jumps straight to .review.
    case fork = "Choose"
    case generate = "Generate"
    case review = "Review"
    case complete = "Done"
}

enum UploadLoaderStage: Int, CaseIterable {
    case removingBackground
    case creatingInteractiveFit
    case compressing

    var title: String {
        switch self {
        case .removingBackground:
            return "Removing background"
        case .creatingInteractiveFit:
            return "Creating your interactive fit"
        case .compressing:
            return "Compressing"
        }
    }
}

@Observable
final class PipelineJob: Identifiable, @unchecked Sendable {
    let id: String
    let outfitNum: Int
    var step: PipelineStep = .upload
    var loaderStage: UploadLoaderStage = .removingBackground
    var maskingBackend: UploadMaskingBackend = .appleVision
    var maskingVariants: [PreparedMaskingVariant] = []
    var sourceImage: Data?
    var sourceImagePath: String?  // path in generation-inputs bucket (for retakes)
    var serverJobId: UUID?        // generation_jobs.id being polled
    var cutoutImage: Data?
    var greenScreenImage: Data?
    var videoURL: URL?
    var stagedOutfit: Outfit?
    /// Single-frame outfit built from the Bria cutout the moment the
    /// fork is reached. This is the user's "2D temporary self": the
    /// archive grid and carousel show it (with sparkles overlaid)
    /// while the fork decision is pending or the 3D render is in
    /// flight. Its frame is saved to local storage under the same
    /// outfit id the final accept will use, so the swap is seamless.
    var previewOutfit: Outfit?
    var uploadWeather: Weather?
    var uploadLocation: String?
    var isRotationReversed: Bool = false
    var requestId: String?
    var prompt: String = UploadConfig.defaultPrompt
    var resultOutfitId: String?
    var resultFrameCount: Int?
    var error: String?
    /// True specifically when the last 3D attempt failed because
    /// the user has no credits left. Set by the orchestrator when
    /// it catches `UploadPipelineError.outOfCredits`. Drives the
    /// fork chin's "Generate 3D" CTA → "Buy 3D credits" swap so
    /// the user can top up without leaving the card.
    var isOutOfCredits: Bool = false
    var isProcessing: Bool = false
    var statusTitle: String = "Select a full-body mirror selfie."
    var statusDetail: String = "Use Camera Roll or Camera to start the pipeline."
    var progress: Double?
    var logLines: [String] = []
    var publishedToFeed: Bool = false
    /// Products auto-detected via tap-to-segment during the upload flow.
    /// Merged into stagedOutfit.products once Kling completes.
    var autoDetectedProducts: [Product] = []

    init(outfitNum: Int) {
        self.id = "outfit-\(outfitNum)"
        self.outfitNum = outfitNum
        regenerateCount = PipelineJob.storedRegenerateCount(for: id)
    }

    // MARK: Regenerate cap

    /// Each Regenerate resubmits the video generation — real money.
    /// Capped per fit; the count is UserDefaults-backed by job id so
    /// a restart (or a restored review card) can't reset the meter.
    static let maxRegenerates = 3
    var regenerateCount: Int = 0

    private static let regenerateCountsKey = "yafa.regenerateCounts"

    static func storedRegenerateCount(for id: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: regenerateCountsKey) as? [String: Int])?[id] ?? 0
    }

    func recordRegenerate() {
        regenerateCount = max(regenerateCount, PipelineJob.storedRegenerateCount(for: id)) + 1
        var counts = (UserDefaults.standard.dictionary(forKey: PipelineJob.regenerateCountsKey) as? [String: Int]) ?? [:]
        counts[id] = regenerateCount
        UserDefaults.standard.set(counts, forKey: PipelineJob.regenerateCountsKey)
    }

    /// Terminal states clear the meter so the id can't leak defaults
    /// storage (job ids recycle per outfit number).
    func clearRegenerateCount() {
        var counts = (UserDefaults.standard.dictionary(forKey: PipelineJob.regenerateCountsKey) as? [String: Int]) ?? [:]
        counts.removeValue(forKey: id)
        UserDefaults.standard.set(counts, forKey: PipelineJob.regenerateCountsKey)
    }

    var regeneratesRemaining: Int {
        max(0, PipelineJob.maxRegenerates - max(regenerateCount, PipelineJob.storedRegenerateCount(for: id)))
    }
}

struct PersistedPipelineReview: Codable, Sendable {
    let id: String
    let outfitNum: Int
    let stagedOutfit: Outfit
    let uploadWeather: Weather?
    let uploadLocation: String?
    let isRotationReversed: Bool
    let sourceImagePath: String?
    let serverJobId: UUID?
    let prompt: String
    let persistedAt: Date
    let statusTitle: String
    let statusDetail: String

    init(
        id: String,
        outfitNum: Int,
        stagedOutfit: Outfit,
        uploadWeather: Weather?,
        uploadLocation: String?,
        isRotationReversed: Bool,
        sourceImagePath: String?,
        serverJobId: UUID?,
        prompt: String,
        persistedAt: Date,
        statusTitle: String,
        statusDetail: String
    ) {
        self.id = id
        self.outfitNum = outfitNum
        self.stagedOutfit = stagedOutfit
        self.uploadWeather = uploadWeather
        self.uploadLocation = uploadLocation
        self.isRotationReversed = isRotationReversed
        self.sourceImagePath = sourceImagePath
        self.serverJobId = serverJobId
        self.prompt = prompt
        self.persistedAt = persistedAt
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
    }

    init?(job: PipelineJob) {
        guard let stagedOutfit = job.stagedOutfit,
              job.step == .review,
              job.resultOutfitId == nil else {
            return nil
        }

        self.id = job.id
        self.outfitNum = job.outfitNum
        self.stagedOutfit = stagedOutfit
        self.uploadWeather = job.uploadWeather
        self.uploadLocation = job.uploadLocation
        self.isRotationReversed = job.isRotationReversed
        self.sourceImagePath = job.sourceImagePath
        self.serverJobId = job.serverJobId
        self.prompt = job.prompt
        self.persistedAt = Date()
        self.statusTitle = job.statusTitle
        self.statusDetail = job.statusDetail
    }

    func makePipelineJob() -> PipelineJob {
        let job = PipelineJob(outfitNum: outfitNum)
        job.step = .review
        job.loaderStage = .compressing
        job.stagedOutfit = stagedOutfit
        job.uploadWeather = uploadWeather
        job.uploadLocation = uploadLocation
        job.isRotationReversed = isRotationReversed
        job.sourceImagePath = sourceImagePath
        job.serverJobId = serverJobId
        job.prompt = prompt
        job.statusTitle = statusTitle
        job.statusDetail = statusDetail
        job.isProcessing = false
        return job
    }
}

/// Disk snapshot of an in-flight pipeline job from the fork onward,
/// so the 2D still and the user's pending decision survive app kills.
/// One JSON per job in the user's pending-jobs directory, with the
/// cutout / green-screen PNGs saved alongside. A fork-stage job must
/// NEVER expire on its own — it's restored on every launch until the
/// user acts on it (2D save, 3D generate, or cancel).
struct PersistedPendingJob: Codable, Sendable {
    enum Step: String, Codable {
        case fork, generate, review
    }

    let outfitNum: Int
    let step: Step
    let uploadWeather: Weather?
    let uploadLocation: String?
    let prompt: String
    let sourceImagePath: String?
    let serverJobId: UUID?
    let stagedOutfit: Outfit?
    let previewOutfit: Outfit?
    let statusTitle: String
    let statusDetail: String
    let persistedAt: Date

    init?(job: PipelineJob) {
        switch job.step {
        case .fork:     self.step = .fork
        case .generate: self.step = .generate
        case .review:   self.step = .review
        case .upload, .complete:
            return nil
        }
        self.outfitNum = job.outfitNum
        self.uploadWeather = job.uploadWeather
        self.uploadLocation = job.uploadLocation
        self.prompt = job.prompt
        self.sourceImagePath = job.sourceImagePath
        self.serverJobId = job.serverJobId
        self.stagedOutfit = job.stagedOutfit
        self.previewOutfit = job.previewOutfit
        self.statusTitle = job.statusTitle
        self.statusDetail = job.statusDetail
        self.persistedAt = Date()
    }

    func makePipelineJob(cutout: Data?, greenScreen: Data?) -> PipelineJob {
        let job = PipelineJob(outfitNum: outfitNum)
        job.statusTitle = statusTitle
        job.statusDetail = statusDetail
        switch step {
        case .fork:
            job.step = .fork
            job.isProcessing = false
        case .generate:
            if serverJobId != nil {
                job.step = .generate
                job.isProcessing = true
            } else {
                // No server job to poll — drop back to the fork so
                // the user can re-decide instead of spinning forever.
                job.step = .fork
                job.isProcessing = false
                job.statusTitle = "READY"
                job.statusDetail = "Save your fit or spin it in 3D."
            }
        case .review:
            job.step = .review
            job.isProcessing = false
        }
        job.cutoutImage = cutout
        job.greenScreenImage = greenScreen
        job.stagedOutfit = stagedOutfit
        job.previewOutfit = previewOutfit
        job.uploadWeather = uploadWeather
        job.uploadLocation = uploadLocation
        job.prompt = prompt
        job.sourceImagePath = sourceImagePath
        job.serverJobId = serverJobId
        return job
    }
}

enum UploadPipelineError: LocalizedError {
    case invalidImage
    case unsupportedCamera
    case missingFalKey
    case missingVideo
    case maskGenerationFailed
    case emptyExport
    case requestFailed(String)
    case decodingFailed
    case outOfCredits

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The selected image could not be read."
        case .unsupportedCamera:
            return "Camera capture is not available on this device."
        case .missingFalKey:
            return "Add `FALAPIKey` to Info.plist to enable Kling generation."
        case .missingVideo:
            return "The video generation finished without a playable video."
        case .maskGenerationFailed:
            return "Background removal could not isolate the subject cleanly."
        case .emptyExport:
            return "No frames were exported from the generated video."
        case let .requestFailed(message):
            return message
        case .decodingFailed:
            return "The generation response could not be decoded."
        case .outOfCredits:
            return "You're out of 3D credits this month."
        }
    }
}

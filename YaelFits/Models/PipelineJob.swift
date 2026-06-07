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
    var uploadWeather: Weather?
    var uploadLocation: String?
    var isRotationReversed: Bool = false
    var requestId: String?
    var prompt: String = UploadConfig.defaultPrompt
    var resultOutfitId: String?
    var resultFrameCount: Int?
    var error: String?
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
            return "You're out of 3D credits for this month. Save this fit as 2D for free — your free credits refresh every 30 days."
        }
    }
}

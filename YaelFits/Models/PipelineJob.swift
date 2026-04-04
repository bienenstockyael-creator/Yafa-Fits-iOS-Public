import Foundation

enum PipelineStep: String, CaseIterable {
    case upload = "Upload"
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
    var cutoutImage: Data?
    var greenScreenImage: Data?
    var videoURL: URL?
    var stagedOutfit: Outfit?
    var uploadWeather: Weather?
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

    init(outfitNum: Int) {
        self.id = "outfit-\(outfitNum)"
        self.outfitNum = outfitNum
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
        }
    }
}

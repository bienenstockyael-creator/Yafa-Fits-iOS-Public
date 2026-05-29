import Foundation

struct GenerationJobRecord: Decodable {
    let id: UUID
    let outfitNum: Int?          // Used on launch to rebuild a PipelineJob without re-allocating
    let status: String           // queued | processing | complete | failed | cancelled
    let reviewState: String?     // pending | accepted | published | rejected
    let stage: String?           // removing_background | creating_interactive_fit | compressing | complete | failed
    let statusTitle: String?
    let statusDetail: String?
    let progress: Double?
    let error: String?
    let remoteOutfit: Outfit?    // decoded from jsonb — camelCase keys set by server

    var isTerminal: Bool {
        ["complete", "failed", "cancelled"].contains(status)
    }

    var isReviewReady: Bool {
        status == "complete" && reviewState == "pending" && remoteOutfit != nil
    }

    /// Server-side job is still running (or queued to run) and we
    /// can poll it. Used by restore-on-launch to decide whether to
    /// re-attach polling.
    var isInflight: Bool {
        status == "queued" || status == "processing"
    }

    var loaderStage: UploadLoaderStage {
        switch stage {
        case "removing_background":      return .removingBackground
        case "creating_interactive_fit": return .creatingInteractiveFit
        case "compressing":              return .compressing
        default:                         return .removingBackground
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case outfitNum     = "outfit_num"
        case status
        case reviewState   = "review_state"
        case stage
        case statusTitle   = "status_title"
        case statusDetail  = "status_detail"
        case progress
        case error
        case remoteOutfit  = "remote_outfit"
    }
}

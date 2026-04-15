import Foundation

struct GenerationJobRecord: Decodable {
    let id: UUID
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

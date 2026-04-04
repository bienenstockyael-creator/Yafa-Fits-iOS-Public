import Foundation

enum UploadMaskingBackend: String, CaseIterable, Identifiable, Sendable {
    case appleVision
    case falBria

    var id: Self { self }

    var selectionTitle: String {
        switch self {
        case .appleVision:
            return "Apple"
        case .falBria:
            return "fal Bria"
        }
    }

    var statusTitle: String {
        switch self {
        case .appleVision:
            return "Removing background"
        case .falBria:
            return "Submitting to fal Bria"
        }
    }

    var statusDetail: String {
        switch self {
        case .appleVision:
            return "Isolating the person with Apple Vision."
        case .falBria:
            return "Uploading the source photo to fal Bria background removal."
        }
    }

    var previewTitle: String {
        switch self {
        case .appleVision:
            return "Cutout · Apple"
        case .falBria:
            return "Cutout · fal Bria"
        }
    }
}

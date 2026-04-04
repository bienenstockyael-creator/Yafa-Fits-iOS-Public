import Foundation

struct PreparedMaskingVariant: Identifiable, Sendable {
    let backend: UploadMaskingBackend
    let cutoutPNGData: Data
    let greenScreenPNGData: Data

    var id: UploadMaskingBackend { backend }
}

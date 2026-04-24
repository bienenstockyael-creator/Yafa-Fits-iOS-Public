import CoreImage
import Foundation

/// On-device Core Image enhancement pass applied to the Bria-masked cutout
/// before it's composed onto the Kling green screen. Always on.
struct ImageEnhancementService {
    static let shared = ImageEnhancementService()

    /// Sharpen + small exposure bump + vibrance. Preserves the original extent
    /// (alpha untouched).
    func enhance(_ image: CIImage) -> CIImage {
        let extent = image.extent

        let sharpened = image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.0,
            kCIInputIntensityKey: 0.5,
        ])

        let brightened = sharpened.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: 0.15,
        ])

        let vibrant = brightened.applyingFilter("CIVibrance", parameters: [
            "inputAmount": 0.3,
        ])

        return vibrant.cropped(to: extent)
    }
}

import CoreImage
import Foundation

/// On-device Core Image enhancement pass applied to the Bria-masked cutout
/// before it's composed onto the Kling green screen. Gated by a UserDefaults
/// flag so it can be toggled on/off without a rebuild.
struct ImageEnhancementService {
    static let shared = ImageEnhancementService()

    private static let enabledKey = "imageEnhancement.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Sharpen + small exposure bump + vibrance. Returns the input unchanged
    /// if the toggle is off. Preserves the original extent (alpha untouched).
    func enhance(_ image: CIImage) -> CIImage {
        guard Self.isEnabled else { return image }

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

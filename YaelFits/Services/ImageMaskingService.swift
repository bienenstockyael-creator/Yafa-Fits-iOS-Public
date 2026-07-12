import CoreImage
import Foundation
import UIKit
import Vision

struct PreparedUploadAssets: Sendable {
    let cutoutPNGData: Data
    let greenScreenPNGData: Data
}

actor ImageMaskingService {
    static let shared = ImageMaskingService()

    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let greenScreenColor = CIColor(red: 0.09, green: 0.92, blue: 0.31, alpha: 1)
    private let compositionBoundsAlphaThreshold: UInt8 = 1
    // Keep the subject centered on the Kling canvas, but leave more headroom and footroom
    // so the generated orbit has space without clipping the silhouette.
    private let compositionWidthRatio: CGFloat = 0.70
    private let compositionHeightRatio: CGFloat = 0.88
    private let compositionWidthSafetyRatio: CGFloat = 1.08
    private let compositionHeightSafetyRatio: CGFloat = 1.08

    func prepareUploadAssets(
        from imageData: Data,
        using backend: UploadMaskingBackend,
        onUpdate: (@Sendable (String, String) async -> Void)? = nil
    ) async throws -> PreparedUploadAssets {
        guard let sourceImage = UIImage(data: imageData)?.normalizedUploadImage(maxDimension: 4096),
              let cgImage = sourceImage.cgImage else {
            throw UploadPipelineError.invalidImage
        }

        let normalizedSourceData = sourceImage.jpegData(compressionQuality: 1) ?? imageData
        let sourceCanvasSize = CGSize(width: cgImage.width, height: cgImage.height)

        if let onUpdate {
            await onUpdate(backend.statusTitle, backend.statusDetail)
        }

        let maskedImage = try await removeBackground(
            from: cgImage,
            sourceImageData: normalizedSourceData,
            using: backend,
            onUpdate: onUpdate
        )
        let refinedMaskedImage = refineMaskedImage(maskedImage, for: backend)
        let enhancedImage = ImageEnhancementService.shared.enhance(refinedMaskedImage)
        // Standardise the cutout onto the same Kling-style 9:16 canvas
        // we use for the green screen so the 2D archive thumbnail / fork
        // preview match what 3D outfits look like (person centered,
        // properly scaled) instead of a tiny figure on a giant canvas.
        let cutoutCanvas = composeForArchive(enhancedImage, sourceCanvasSize: sourceCanvasSize)
        let greenScreenCanvas = composeForKling(enhancedImage, sourceCanvasSize: sourceCanvasSize)

        guard let cutoutPNGData = ciContext.pngRepresentation(
            of: cutoutCanvas,
            format: .RGBA8,
            colorSpace: colorSpace
        ), let greenScreenPNGData = ciContext.pngRepresentation(
            of: greenScreenCanvas,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw UploadPipelineError.invalidImage
        }

        return PreparedUploadAssets(
            cutoutPNGData: cutoutPNGData,
            greenScreenPNGData: greenScreenPNGData
        )
    }

    private func removeBackground(
        from cgImage: CGImage,
        sourceImageData: Data,
        using backend: UploadMaskingBackend,
        onUpdate: (@Sendable (String, String) async -> Void)?
    ) async throws -> CIImage {
        switch backend {
        case .appleVision:
            return try removeBackgroundLocally(from: cgImage)

        case .falBria:
            let removedBackgroundData = try await FalBackgroundRemovalService.shared.removeBackground(
                from: sourceImageData
            ) { progress in
                guard let onUpdate else { return }
                await onUpdate(progress.title, progress.detail)
            }

            guard let removedBackgroundImage = UIImage(data: removedBackgroundData)?.normalizedUploadImageOrientation(),
                  let removedBackgroundCGImage = removedBackgroundImage.cgImage else {
                throw UploadPipelineError.invalidImage
            }

            return CIImage(cgImage: removedBackgroundCGImage)
        }
    }

    private func removeBackgroundLocally(from cgImage: CGImage) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let sourceImage = CIImage(cgImage: cgImage)

        // Prefer Apple's newer foreground instance masking on iOS 17+. It tends to keep
        // cleaner edges than the older person segmentation matte, especially around hair.
        let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([foregroundRequest])

        if let observation = foregroundRequest.results?.first,
           !observation.allInstances.isEmpty,
           let scaledMaskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
           ) {
            let maskImage = CIImage(cvPixelBuffer: scaledMaskBuffer)
            let clearBackground = CIImage(color: .clear).cropped(to: sourceImage.extent)
            return sourceImage.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: clearBackground,
                    kCIInputMaskImageKey: maskImage,
                ]
            )
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([request])

        guard let maskBuffer = request.results?.first?.pixelBuffer else {
            throw UploadPipelineError.maskGenerationFailed
        }

        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let scaleX = sourceImage.extent.width / maskImage.extent.width
        let scaleY = sourceImage.extent.height / maskImage.extent.height
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let clearBackground = CIImage(color: .clear).cropped(to: sourceImage.extent)

        return sourceImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearBackground,
                kCIInputMaskImageKey: scaledMask,
            ]
        )
    }

    private func refineMaskedImage(_ image: CIImage, for backend: UploadMaskingBackend) -> CIImage {
        switch backend {
        case .appleVision:
            return expandSubjectAlpha(in: image)
        case .falBria:
            return image
        }
    }

    private func expandSubjectAlpha(in image: CIImage) -> CIImage {
        let alphaAsMask = image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]
        )

        let expandedMask = alphaAsMask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 1.5])
            .cropped(to: image.extent)

        let clearBackground = CIImage(color: .clear).cropped(to: image.extent)
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearBackground,
                kCIInputMaskImageKey: expandedMask,
            ]
        )
    }

    private func compositeMaskedImage(_ image: CIImage, canvasSize: CGSize, backgroundColor: CIColor) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let background = CIImage(color: backgroundColor).cropped(to: canvasRect)
        let normalizedImage = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )

        return normalizedImage
            .composited(over: background)
            .cropped(to: canvasRect)
    }

    /// Same scaling + centering as `composeForKling` but composites
    /// onto a transparent canvas and scales the subject to fill the
    /// canvas (the Kling version leaves headroom for the orbit camera;
    /// the 2D archive thumbnail has no such constraint). The result
    /// visually matches Kling's 3D frames in the grid.
    private func composeForArchive(_ image: CIImage, sourceCanvasSize: CGSize) -> CIImage {
        // Fill-the-canvas ratios — no orbit-camera headroom needed for
        // a static thumbnail. ~98% on both axes leaves a tiny safety
        // margin to avoid clipping anti-aliased edges.
        let archiveFillRatio: CGFloat = 0.98
        let archiveSafetyRatio: CGFloat = 1.0

        let canvasRect = CGRect(origin: .zero, size: UploadConfig.compositionDimensions)
        let background = CIImage(color: .clear).cropped(to: canvasRect)
        let sourceCanvasImage = compositeMaskedImage(
            image,
            canvasSize: sourceCanvasSize,
            backgroundColor: .clear
        )

        let boundsImage = expandedBoundsImage(from: sourceCanvasImage)
        guard let subjectBounds = nonTransparentBounds(in: boundsImage) else {
            return sourceCanvasImage
                .composited(over: background)
                .cropped(to: canvasRect)
        }

        let scale = min(
            (canvasRect.width * archiveFillRatio) / (subjectBounds.width * archiveSafetyRatio),
            (canvasRect.height * archiveFillRatio) / (subjectBounds.height * archiveSafetyRatio)
        )
        let xOffset = (canvasRect.midX) - (subjectBounds.midX * scale)
        let sourceHeight = sourceCanvasSize.height
        let subjectMidCIY = (sourceHeight - subjectBounds.midY) * scale
        let yOffset = (canvasRect.midY) - subjectMidCIY
        let transformedImage = scaledImage(sourceCanvasImage, scaleX: scale, scaleY: scale)
            .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

        return transformedImage
            .composited(over: background)
            .cropped(to: canvasRect)
    }

    private func composeForKling(_ image: CIImage, sourceCanvasSize: CGSize) -> CIImage {
        let standardSize = UploadConfig.compositionDimensions
        let sourceCanvasImage = compositeMaskedImage(
            image,
            canvasSize: sourceCanvasSize,
            backgroundColor: .clear
        )

        let boundsImage = expandedBoundsImage(from: sourceCanvasImage)
        guard let subjectBounds = nonTransparentBounds(in: boundsImage) else {
            let canvasRect = CGRect(origin: .zero, size: standardSize)
            return sourceCanvasImage
                .composited(over: CIImage(color: greenScreenColor).cropped(to: canvasRect))
                .cropped(to: canvasRect)
        }

        // Subject scale is computed against the STANDARD canvas and never
        // changes — quality to Kling is identical for every outfit.
        let scale = min(
            (standardSize.width * compositionWidthRatio) / (subjectBounds.width * compositionWidthSafetyRatio),
            (standardSize.height * compositionHeightRatio) / (subjectBounds.height * compositionHeightSafetyRatio)
        )

        // WIDE poses (crouch, sprawl): Kling's orbit sweeps the pose
        // horizontally, and on the standard canvas the rotation can exit
        // the frame — Kling bakes that crop into the video itself,
        // unrecoverable downstream. Instead of shrinking the subject
        // (quality loss), WIDEN the canvas around it so the subject at
        // full scale never exceeds 50% of the width. Kling mirrors the
        // input ratio, so the video gets the same headroom; standing
        // outfits stay under 50% already and keep the standard canvas
        // byte-for-byte. Width is even-rounded for the video encoder.
        let subjectScaledWidth = subjectBounds.width * scale
        let neededWidth = ceil(subjectScaledWidth / 0.50 / 2) * 2
        let canvasRect = CGRect(
            origin: .zero,
            size: CGSize(width: max(standardSize.width, neededWidth), height: standardSize.height)
        )
        let background = CIImage(color: greenScreenColor).cropped(to: canvasRect)

        let xOffset = (canvasRect.midX) - (subjectBounds.midX * scale)
        // nonTransparentBounds returns CGImage coords (y-down) but CIImage
        // transforms use y-up coords. Convert midY before centering.
        let sourceHeight = sourceCanvasSize.height
        let subjectMidCIY = (sourceHeight - subjectBounds.midY) * scale
        let yOffset = (canvasRect.midY) - subjectMidCIY
        let transformedImage = scaledImage(sourceCanvasImage, scaleX: scale, scaleY: scale)
            .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

        return transformedImage
            .composited(over: background)
            .cropped(to: canvasRect)
    }

    private func scaledImage(_ image: CIImage, scaleX: CGFloat, scaleY: CGFloat) -> CIImage {
        guard scaleX > 0, scaleY > 0 else { return image }

        if abs(scaleX - scaleY) < 0.0001,
           let filter = CIFilter(
                name: "CILanczosScaleTransform",
                parameters: [
                    kCIInputImageKey: image,
                    kCIInputScaleKey: scaleY,
                    kCIInputAspectRatioKey: 1,
                ]
           ),
           let outputImage = filter.outputImage {
            return outputImage
        }

        if let filter = CIFilter(
            name: "CILanczosScaleTransform",
            parameters: [
                kCIInputImageKey: image,
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ]
        ), let outputImage = filter.outputImage {
            return outputImage
        }

        return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    private func expandedBoundsImage(from image: CIImage) -> CIImage {
        let alphaAsMask = image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]
        )

        return alphaAsMask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 4.0])
            .cropped(to: image.extent)
    }

    private func nonTransparentBounds(in image: CIImage) -> CGRect? {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0 ..< height {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0 ..< width {
                let alpha = row[(x * 4) + 3]
                guard alpha > compositionBoundsAlphaThreshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}

private extension UIImage {
    func normalizedUploadImage(maxDimension: CGFloat = 4096) -> UIImage {
        let image = normalizedUploadImageOrientation()
        let currentMaxDimension = max(image.size.width, image.size.height)
        guard currentMaxDimension > maxDimension else { return image }

        let scale = maxDimension / currentMaxDimension
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func normalizedUploadImageOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

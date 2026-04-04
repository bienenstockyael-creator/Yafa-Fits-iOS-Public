import AVFoundation
import CoreImage
import ImageIO
import Foundation
import UIKit
import WebP

actor VideoFrameSequenceExporter {
    static let shared = VideoFrameSequenceExporter()

    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let colorCubeSize = 32
    // High enough to ignore chroma key edge artifacts / semi-transparent
    // green residue, but low enough to catch the actual subject edges.
    private let boundsAlphaThreshold: UInt8 = 40
    // Existing outfits fill ~92% of the 550px frame height (median across all outfits).
    private let targetSubjectHeight: CGFloat = FrameConfig.dimensions.height * 0.92
    private let bottomMarginRatio: CGFloat = 0.02
    private let webPCompressionQuality: Float = 82
    private let previewCompressionQuality: Float = 70
    private let previewWidth: CGFloat = 180
    private lazy var colorCubeData = Self.makeChromaKeyCubeData(dimension: colorCubeSize)

    func exportSequence(
        from videoURL: URL,
        referenceGreenScreenPNGData: Data,
        outfitNumber: Int,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> Outfit {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frameTimes = (0 ..< UploadConfig.extractedFrameCount).map {
            CMTimeMultiplyByFloat64(duration, multiplier: Double($0) / Double(UploadConfig.extractedFrameCount))
        }
        let layout = try buildLayout(
            generator: generator,
            frameTimes: frameTimes
        )

        let outfit = makeOutfit(outfitNumber: outfitNumber)
        var firstFrameData: Data?
        var firstPreviewData: Data?

        for (index, time) in frameTimes.enumerated() {
            try Task.checkCancellation()

            let progress = Double(index) / Double(FrameConfig.framesPerOutfit)
            await onProgress(progress, "Removing green background and extracting frame \(index + 1) of \(UploadConfig.extractedFrameCount).")

            let frameImage = try generator.copyCGImage(at: time, actualTime: nil)
            let frameData = try renderFrame(frameImage, layout: layout)

            if firstFrameData == nil {
                firstFrameData = frameData
                firstPreviewData = try makePreviewData(from: frameImage, layout: layout)
            }

            try LocalOutfitStore.shared.saveFrame(frameData, outfit: outfit, index: index)
        }

        guard let firstFrameData else {
            throw UploadPipelineError.emptyExport
        }

        try LocalOutfitStore.shared.saveFrame(firstFrameData, outfit: outfit, index: FrameConfig.framesPerOutfit - 1)
        if let firstPreviewData {
            try LocalOutfitStore.shared.savePreview(firstPreviewData, outfit: outfit)
        }
        await onProgress(1, "Prepared \(FrameConfig.framesPerOutfit) frames for review.")
        return outfit
    }

    private func buildLayout(
        generator: AVAssetImageGenerator,
        frameTimes: [CMTime]
    ) throws -> StableFrameLayout {
        guard let firstTime = frameTimes.first else {
            throw UploadPipelineError.emptyExport
        }

        let firstFrameImage = try generator.copyCGImage(at: firstTime, actualTime: nil)
        let sourceRect = CIImage(cgImage: firstFrameImage).extent.integral
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            throw UploadPipelineError.emptyExport
        }

        // Detect the union of subject bounds across all video frames so the
        // layout accommodates the full range of motion without clipping.
        // Side/back views can be taller than the front-facing first frame.
        var unionBounds: CGRect?
        for time in frameTimes {
            let frameImage = try generator.copyCGImage(at: time, actualTime: nil)
            let keyedImage = removeGreenBackground(from: CIImage(cgImage: frameImage))
                .cropped(to: sourceRect)
            if let bounds = nonTransparentBounds(in: keyedImage) {
                unionBounds = unionBounds?.union(bounds) ?? bounds
            }
        }

        guard let sizingBounds = unionBounds else {
            throw UploadPipelineError.emptyExport
        }

        let targetSize = FrameConfig.dimensions

        // Scale so the subject height matches existing outfits (~92% of frame).
        let scale = targetSubjectHeight / max(sizingBounds.height, 1)

        // Horizontally center the subject. X axis is the same in both
        // CGImage and CIImage coordinate systems.
        let xOffset = (targetSize.width / 2) - (sizingBounds.midX * scale)

        // Bottom-align with a small margin. nonTransparentBounds returns CGImage
        // coords (y-down) but CIImage transforms use y-up coords. Convert the
        // subject's feet position (maxY in CGImage) to CIImage coords before
        // computing the offset.
        let bottomMargin = targetSize.height * bottomMarginRatio
        let feetCIY = (sourceRect.height - sizingBounds.maxY) * scale
        let yOffset = bottomMargin - feetCIY

        return StableFrameLayout(sourceRect: sourceRect, scale: scale, xOffset: xOffset, yOffset: yOffset)
    }

    private func renderFrame(_ cgImage: CGImage, layout: StableFrameLayout) throws -> Data {
        let sourceImage = CIImage(cgImage: cgImage)
        let keyedImage = removeGreenBackground(from: sourceImage).cropped(to: sourceImage.extent)
        let targetSize = FrameConfig.dimensions
        let targetRect = CGRect(origin: .zero, size: targetSize)
        let normalizedImage = keyedImage
            .cropped(to: layout.sourceRect)
            .transformed(
                by: CGAffineTransform(translationX: -layout.sourceRect.minX, y: -layout.sourceRect.minY)
        )

        let scaledImage = scaledImage(normalizedImage, scale: layout.scale)
        let translatedImage = scaledImage.transformed(
            by: CGAffineTransform(translationX: layout.xOffset, y: layout.yOffset)
        )
        let canvas = translatedImage
            .composited(over: CIImage(color: .clear).cropped(to: targetRect))
            .cropped(to: targetRect)

        guard let renderedImage = ciContext.createCGImage(canvas, from: targetRect) else {
            throw UploadPipelineError.emptyExport
        }

        return try encodedFrameData(from: renderedImage)
    }

    private func scaledImage(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale > 0,
              let filter = CIFilter(
                  name: "CILanczosScaleTransform",
                  parameters: [
                      kCIInputImageKey: image,
                      kCIInputScaleKey: scale,
                      kCIInputAspectRatioKey: 1,
                  ]
              ),
              let outputImage = filter.outputImage else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return outputImage
    }

    private func removeGreenBackground(from image: CIImage) -> CIImage {
        guard let filter = CIFilter(
            name: "CIColorCubeWithColorSpace",
            parameters: [
                "inputCubeDimension": colorCubeSize,
                "inputCubeData": colorCubeData,
                "inputColorSpace": colorSpace,
                kCIInputImageKey: image,
            ]
        ), let outputImage = filter.outputImage else {
            return image
        }

        return outputImage
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
                guard alpha > boundsAlphaThreshold else { continue }
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

    private func makeOutfit(outfitNumber: Int) -> Outfit {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let outfitId = "outfit-\(outfitNumber)"
        return Outfit(
            id: outfitId,
            name: "Outfit \(outfitNumber)",
            date: formatter.string(from: Date()),
            frameCount: FrameConfig.framesPerOutfit,
            folder: outfitId,
            prefix: "\(outfitId)_",
            frameExt: "webp",
            scale: nil,
            isRotationReversed: false,
            tags: [],
            activity: nil,
            weather: nil,
            products: []
        )
    }

    private func encodedFrameData(from image: CGImage) throws -> Data {
        let encoder = WebPEncoder()
        return try encoder.encode(
            UIImage(cgImage: image),
            config: .preset(.picture, quality: webPCompressionQuality)
        )
    }

    private func makePreviewData(from cgImage: CGImage, layout: StableFrameLayout) throws -> Data {
        let sourceImage = CIImage(cgImage: cgImage)
        let keyedImage = removeGreenBackground(from: sourceImage).cropped(to: sourceImage.extent)
        let targetSize = FrameConfig.dimensions
        let targetRect = CGRect(origin: .zero, size: targetSize)
        let normalizedImage = keyedImage
            .cropped(to: layout.sourceRect)
            .transformed(
                by: CGAffineTransform(translationX: -layout.sourceRect.minX, y: -layout.sourceRect.minY)
            )

        let scaledImage = scaledImage(normalizedImage, scale: layout.scale)
        let translatedImage = scaledImage.transformed(
            by: CGAffineTransform(translationX: layout.xOffset, y: layout.yOffset)
        )
        let canvas = translatedImage
            .composited(over: CIImage(color: .clear).cropped(to: targetRect))
            .cropped(to: targetRect)

        guard let renderedImage = ciContext.createCGImage(canvas, from: targetRect) else {
            throw UploadPipelineError.emptyExport
        }

        let aspectRatio = CGFloat(renderedImage.height) / CGFloat(renderedImage.width)
        let previewSize = CGSize(width: previewWidth, height: previewWidth * aspectRatio)
        let sourceUIImage = UIImage(cgImage: renderedImage)
        let renderer = UIGraphicsImageRenderer(size: previewSize)
        let previewImage = renderer.image { _ in
            sourceUIImage.draw(in: CGRect(origin: .zero, size: previewSize))
        }

        let encoder = WebPEncoder()
        return try encoder.encode(
            previewImage,
            config: .preset(.picture, quality: previewCompressionQuality)
        )
    }

    private static func makeChromaKeyCubeData(dimension: Int) -> Data {
        var cubeData = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var offset = 0

        for blueIndex in 0 ..< dimension {
            let blue = Float(blueIndex) / Float(dimension - 1)
            for greenIndex in 0 ..< dimension {
                let green = Float(greenIndex) / Float(dimension - 1)
                for redIndex in 0 ..< dimension {
                    let red = Float(redIndex) / Float(dimension - 1)

                    let maxRedBlue = max(red, blue)
                    let greenBias = green - maxRedBlue
                    let saturation = max(red, max(green, blue)) - min(red, min(green, blue))
                    let keyStrength = smoothstep(0.02, 0.24, greenBias) * smoothstep(0.02, 0.18, saturation)
                    let alpha = max(0, 1 - keyStrength)

                    cubeData[offset] = red
                    cubeData[offset + 1] = alpha < 1 ? min(green, maxRedBlue * 1.08) : green
                    cubeData[offset + 2] = blue
                    cubeData[offset + 3] = alpha
                    offset += 4
                }
            }
        }

        return cubeData.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let clamped = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

private struct StableFrameLayout {
    let sourceRect: CGRect
    let scale: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
}

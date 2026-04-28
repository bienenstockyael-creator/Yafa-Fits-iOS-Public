import CoreImage
import Foundation
import UIKit

struct FalSegmentationProgress: Sendable {
    let title: String
    let detail: String
}

/// Result of segmenting one garment.
struct FalSegmentationResult: Sendable {
    /// Tight crop of the garment with a transparent background — fed to nano-banana.
    let croppedGarment: UIImage
    /// Same dimensions as the source image; opaque cyan inside the mask, transparent
    /// outside. Composited over the original to highlight what SAM2 detected.
    let highlightOverlay: UIImage
}

actor FalSegmentationService {
    static let shared = FalSegmentationService()

    private let session: URLSession
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Run SAM2 with a single point prompt at (x, y) on `image`, then return the
    /// segmented region cropped tightly to its bounding box. The returned image
    /// has a transparent background outside the segment.
    ///
    /// - Parameters:
    ///   - image: the source image (typically the Bria-cleaned outfit selfie).
    ///   - point: tap location in the image's coordinate space (top-left origin, pixels).
    ///   - onUpdate: progress callback.
    func segmentGarment(
        in image: UIImage,
        at point: CGPoint,
        onUpdate: @escaping @Sendable (FalSegmentationProgress) async -> Void
    ) async throws -> FalSegmentationResult {
        // The cleaned outfit has a transparent background. With either a
        // transparent or flat-colour BG, SAM2 reads the silhouette as one
        // object and returns the whole-body mask for any tap. Compositing
        // onto low-frequency grey noise gives SAM2 enough internal-edge
        // contrast to pick out the specific garment that was tapped.
        guard let opaque = compositeOverNoiseBackground(image),
              let jpegData = opaque.jpegData(compressionQuality: 0.85) else {
            throw UploadPipelineError.requestFailed("Could not encode source image for segmentation.")
        }
        let apiKey = try loadFalAPIKey()

        print("[SAM] uploading \(jpegData.count) bytes, tap=(\(Int(point.x)), \(Int(point.y))), imageSize=\(Int(image.size.width))x\(Int(image.size.height))")

        await onUpdate(FalSegmentationProgress(title: "Segmenting", detail: "Asking SAM2 to outline the tapped garment."))

        let request = SamRequest(
            image_url: dataURI(for: jpegData, mimeType: "image/jpeg"),
            prompts: [SamPoint(x: Int(point.x.rounded()), y: Int(point.y.rounded()), label: 1)],
            multimask_output: true
        )

        let submitURL = AppConfig.falQueueBaseURL.appendingPathComponent("fal-ai/sam2/image")
        let submit: SamSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: request,
            apiKey: apiKey
        )

        let result: SamResult = try await pollUntilComplete(
            submit: submit,
            apiKey: apiKey,
            onUpdate: onUpdate
        )

        // Collect every mask URL the response provided. SAM2 with
        // multimask_output=true returns 3 candidates at different scales — we
        // download them all and pick the smallest, which is usually the
        // specific garment the user clicked rather than the whole subject.
        var maskURLs: [URL] = []
        if let individual = result.individual_masks {
            maskURLs = individual.compactMap { $0.url }
        }
        if maskURLs.isEmpty, let single = result.maskURL {
            maskURLs = [single]
        }
        guard !maskURLs.isEmpty else {
            throw UploadPipelineError.maskGenerationFailed
        }
        print("[SAM] returned \(maskURLs.count) mask(s)")

        await onUpdate(FalSegmentationProgress(title: "Segmenting", detail: "Picking the best mask."))
        let smallestMask = try await downloadSmallestMask(urls: maskURLs, apiKey: apiKey)

        await onUpdate(FalSegmentationProgress(title: "Segmenting", detail: "Cropping the garment from your photo."))
        return try applyMaskAndCrop(source: image, mask: smallestMask)
    }

    private func downloadSmallestMask(urls: [URL], apiKey: String) async throws -> UIImage {
        // Download all masks in parallel, then pick the one with the smallest
        // white area (most specific to the user's tap).
        try await withThrowingTaskGroup(of: (Int, UIImage, Int).self) { group in
            for (idx, url) in urls.enumerated() {
                group.addTask {
                    let data = try await self.downloadData(from: url, apiKey: apiKey)
                    guard let img = UIImage(data: data) else {
                        throw UploadPipelineError.maskGenerationFailed
                    }
                    let area = self.whitePixelCount(in: img)
                    return (idx, img, area)
                }
            }

            var bestImage: UIImage?
            var bestArea = Int.max
            var areas: [(Int, Int)] = []
            for try await (idx, img, area) in group {
                areas.append((idx, area))
                // Skip degenerate empty masks; pick the smallest non-empty one.
                guard area > 0 else { continue }
                if area < bestArea {
                    bestArea = area
                    bestImage = img
                }
            }
            print("[SAM] mask areas (idx, whitePixels): \(areas.sorted { $0.0 < $1.0 }) — picked area=\(bestArea)")
            guard let pick = bestImage else {
                throw UploadPipelineError.maskGenerationFailed
            }
            return pick
        }
    }

    /// Flatten the (likely transparent) source image onto an opaque,
    /// slightly-textured grey background. Used as SAM2 input only — the
    /// original is still passed to the masking stage so the cropped output
    /// keeps its transparent edges.
    private func compositeOverNoiseBackground(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)

        guard let randomFilter = CIFilter(name: "CIRandomGenerator"),
              let rawNoise = randomFilter.outputImage else { return nil }

        // Soft, low-saturation, mid-grey noise.
        let noise = rawNoise
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputBrightnessKey: 0.0,
                kCIInputContrastKey: 0.4,
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 4.0,
            ])
            .cropped(to: extent)

        let sourceCI = CIImage(cgImage: cg)
        let composite = sourceCI.composited(over: noise)

        guard let outputCG = ciContext.createCGImage(composite, from: extent) else {
            return nil
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Count of pixels with luminance above the threshold — i.e. masked area.
    nonisolated private func whitePixelCount(in image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            // Treat any pixel with R > 128 as "in mask". (SAM masks are b/w.)
            if pixels[i] > 128 { count += 1 }
        }
        return count
    }

    // MARK: - Mask + crop

    private func applyMaskAndCrop(source: UIImage, mask: UIImage) throws -> FalSegmentationResult {
        guard let sourceCG = source.cgImage, let maskCG = mask.cgImage else {
            throw UploadPipelineError.maskGenerationFailed
        }

        let sourceCI = CIImage(cgImage: sourceCG)
        // Resize the mask to match the source if dimensions differ.
        let maskCI = CIImage(cgImage: maskCG)
        let scaledMaskCI: CIImage = {
            let sx = sourceCI.extent.width / maskCI.extent.width
            let sy = sourceCI.extent.height / maskCI.extent.height
            if abs(sx - 1.0) < 0.001 && abs(sy - 1.0) < 0.001 { return maskCI }
            return maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }()

        // Close small gaps in the mask. Strong internal contours like a zipper
        // running down a jacket (or a hand/phone occluding the chest) cause SAM
        // to break the garment into disconnected halves; a morphological close
        // (dilate -> erode) bridges thin separators while leaving the outer
        // silhouette roughly intact.
        let closedMaskCI = scaledMaskCI
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 10.0])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 10.0])
            .cropped(to: scaledMaskCI.extent)

        // Masked source: original through the mask, transparent outside.
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw UploadPipelineError.maskGenerationFailed
        }
        blend.setValue(sourceCI, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: sourceCI.extent),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(closedMaskCI, forKey: kCIInputMaskImageKey)
        guard let masked = blend.outputImage else {
            throw UploadPipelineError.maskGenerationFailed
        }

        // Tight crop for nano-banana input.
        guard let bounds = nonTransparentBounds(in: masked) else {
            throw UploadPipelineError.maskGenerationFailed
        }
        let padX = bounds.width * 0.05
        let padY = bounds.height * 0.05
        let padded = bounds.insetBy(dx: -padX, dy: -padY).intersection(masked.extent)
        let cropped = masked.cropped(to: padded)
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -padded.origin.x, y: -padded.origin.y))
        guard let croppedCG = ciContext.createCGImage(translated, from: CGRect(origin: .zero, size: padded.size)) else {
            throw UploadPipelineError.maskGenerationFailed
        }
        let croppedGarment = UIImage(cgImage: croppedCG)

        // Highlight overlay: same size as source, tinted cyan inside the mask,
        // transparent outside. We drop this on top of the source in the UI to
        // show the user what was detected.
        guard let highlightBlend = CIFilter(name: "CIBlendWithMask") else {
            throw UploadPipelineError.maskGenerationFailed
        }
        let cyan = CIImage(color: CIColor(red: 0.18, green: 0.83, blue: 0.96, alpha: 0.55))
            .cropped(to: sourceCI.extent)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: sourceCI.extent)
        highlightBlend.setValue(cyan, forKey: kCIInputImageKey)
        highlightBlend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        highlightBlend.setValue(closedMaskCI, forKey: kCIInputMaskImageKey)
        guard let highlightCI = highlightBlend.outputImage,
              let highlightCG = ciContext.createCGImage(highlightCI, from: sourceCI.extent) else {
            throw UploadPipelineError.maskGenerationFailed
        }
        let highlightOverlay = UIImage(cgImage: highlightCG)

        return FalSegmentationResult(croppedGarment: croppedGarment, highlightOverlay: highlightOverlay)
    }

    /// Scan the alpha channel and return the bounding box of non-transparent pixels.
    /// Mirrors the helper in ImageMaskingService.
    private func nonTransparentBounds(in image: CIImage) -> CGRect? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let cg = ciContext.createCGImage(image, from: extent) else { return nil }
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let alpha = pixels[rowOffset + x * 4 + 3]
                if alpha > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // CIImage uses bottom-left origin; flip Y.
        let flippedMinY = height - 1 - maxY
        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(flippedMinY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
    }

    // MARK: - FAL plumbing

    private func pollUntilComplete<T: Decodable>(
        submit: SamSubmitResponse,
        apiKey: String,
        onUpdate: @escaping @Sendable (FalSegmentationProgress) async -> Void
    ) async throws -> T {
        while true {
            try Task.checkCancellation()
            let status: SamStatusResponse = try await performRawRequest(url: submit.status_url, apiKey: apiKey)
            switch status.status.lowercased() {
            case "completed":
                return try await performRawRequest(url: submit.response_url, apiKey: apiKey)
            case "failed", "error":
                throw UploadPipelineError.requestFailed(status.error?.message ?? "SAM2 failed.")
            default:
                await onUpdate(FalSegmentationProgress(title: "Segmenting", detail: "SAM2 is locating the garment."))
            }
            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    private func loadFalAPIKey() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let k = env["FALAPIKey"], !k.isEmpty { return k }
        if let k = env["FAL_API_KEY"], !k.isEmpty { return k }
        if let k = env["FAL_KEY"], !k.isEmpty { return k }
        if let k = Bundle.main.object(forInfoDictionaryKey: "FALAPIKey") as? String,
           !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return k
        }
        throw UploadPipelineError.missingFalKey
    }

    private func dataURI(for data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func performJSONRequest<T: Decodable, P: Encodable>(
        url: URL, method: String, payload: P, apiKey: String
    ) async throws -> T {
        let body = try JSONEncoder().encode(payload)
        return try await performDataRequest(url: url, method: method, body: body, apiKey: apiKey)
    }

    private func performRawRequest<T: Decodable>(url: URL, apiKey: String) async throws -> T {
        try await performDataRequest(url: url, method: "GET", body: nil, apiKey: apiKey)
    }

    private func performDataRequest<T: Decodable>(
        url: URL, method: String, body: Data?, apiKey: String
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UploadPipelineError.requestFailed("FAL \((response as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))")
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw UploadPipelineError.decodingFailed
        }
        return decoded
    }

    nonisolated private func downloadData(from url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Mask download failed.")
        }
        return data
    }
}

private struct SamRequest: Encodable {
    let image_url: String
    let prompts: [SamPoint]
    let multimask_output: Bool
}

private struct SamPoint: Encodable {
    let x: Int
    let y: Int
    let label: Int
}

private struct SamSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
    let cancel_url: URL?
}

private struct SamStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let error: SamStatusError?
}

private struct SamStatusError: Decodable {
    let message: String?
}

private struct SamResult: Decodable {
    let image: SamMedia?
    let images: [SamMedia]?
    let mask: SamMedia?
    let individual_masks: [SamMedia]?

    var maskURL: URL? {
        individual_masks?.first?.url ?? mask?.url ?? image?.url ?? images?.first?.url
    }
}

private struct SamMedia: Decodable {
    let url: URL
}

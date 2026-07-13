import Foundation
import UIKit

struct FalProductThumbnailProgress: Sendable {
    let title: String
    let detail: String
}

actor FalProductThumbnailService {
    static let shared = FalProductThumbnailService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Generate a clean flat-lay product thumbnail by asking nano-banana to
    /// isolate the named garment out of the full outfit image. We feed the
    /// whole outfit (model + every garment + any background) so the model has
    /// full context for length, cut, and details — then the prompt tells it
    /// which garment to keep and which to discard.
    ///
    /// - Parameters:
    ///   - outfit: the entire outfit image, exactly as the user is viewing it.
    ///   - label: what the user called the item, e.g. "Black jeans". Used to
    ///     disambiguate which garment to isolate.
    func generateThumbnail(
        fromOutfit outfit: UIImage,
        label: String,
        onUpdate: @escaping @Sendable (FalProductThumbnailProgress) async -> Void
    ) async throws -> UIImage {
        guard let jpegData = outfit.jpegData(compressionQuality: 0.9) else {
            throw UploadPipelineError.requestFailed("Could not encode outfit image.")
        }
        let item = label.isEmpty ? "garment" : label
        let prompt = Self.wornGarmentPrompt(item: item)
        // Transparent cutout, tight framing: Quick Add garments live
        // in small carousel slots and need to fill them.
        return try await generate(prompt: prompt, jpegData: jpegData, transparentCutout: true, onUpdate: onUpdate)
    }

    /// Same nano → Bria → tight-crop pipeline, but for a PRODUCT photo
    /// (retailer page snapshot) rather than a garment worn in an outfit.
    /// Used by the wishlist backfill so bot-walled shops' items end up
    /// visually identical to every other product thumbnail.
    func generateCatalogThumbnail(
        fromProduct product: UIImage,
        label: String,
        onUpdate: @escaping @Sendable (FalProductThumbnailProgress) async -> Void = { _ in }
    ) async throws -> UIImage {
        guard let jpegData = product.jpegData(compressionQuality: 0.9) else {
            throw UploadPipelineError.requestFailed("Could not encode product image.")
        }
        let item = label.isEmpty ? "item" : label
        let prompt = Self.catalogProductPrompt(item: item)
        return try await generate(prompt: prompt, jpegData: jpegData, transparentCutout: true, onUpdate: onUpdate)
    }

    private static func catalogProductPrompt(item: String) -> String {
        [
            "Generate a professional flat-lay e-commerce product photograph of the \(item) shown in the input image.",
            "Isolate just that single item — the \(item) — as a clean catalog product shot.",
            "Remove any model, body, skin, hair, hands, background, props, text, logos, watermarks, and any other item that is not the \(item).",
            "Lay the item flat or place it on an invisible mannequin. Studio lighting, clean white background.",
            "Reproduce the exact \(item) from the input — same colour, fabric, cut, length, silhouette, and visible details.",
            "Do not add features that are not clearly visible on the \(item) in the input image.",
            "Orient the item right-side-up: the top at the top, the bottom at the bottom. Never output a rotated, upside-down, or sideways image.",
        ].joined(separator: " ")
    }

    private static func wornGarmentPrompt(item: String) -> String {
        [
            "Generate a professional flat-lay product photograph of just the \(item) worn by the subject in the input image.",
            "Isolate that single garment — the \(item) — and show it as a clean e-commerce catalog product shot.",
            "Remove the model, body, skin, hair, hands, phone, mirror, background, and every other garment that is not the \(item).",
            "Lay the garment flat or place it on an invisible mannequin. Studio lighting, clean white background.",
            "Reproduce the exact \(item) from the input — same colour, fabric, cut, length, sleeve length, neckline, silhouette, and visible details.",
            "If the garment is partially occluded by the model's hand, phone, or hair, infer the natural continuation but stay faithful to the visible portions.",
            "Do not add a hood, collar, pockets, zippers, drawstrings, buttons, prints, patterns, or any other features that are not clearly visible on the \(item) in the input image.",
            "Do not change the garment's colour, length, sleeve length, neckline, or silhouette.",
            "Orient the garment right-side-up: the top of the garment (collar, neckline, opening, or top edge) at the top of the image; the bottom (hem, cuffs, or sole) at the bottom. Never output a rotated, upside-down, or sideways image.",
        ].joined(separator: " ")
    }

    private func generate(
        prompt: String,
        jpegData: Data,
        transparentCutout: Bool,
        onUpdate: @escaping @Sendable (FalProductThumbnailProgress) async -> Void
    ) async throws -> UIImage {
        let apiKey = try loadFalAPIKey()
        await onUpdate(FalProductThumbnailProgress(title: "Generating thumbnail", detail: "Asking nano-banana for a clean product shot."))

        let request = NanoRequest(
            prompt: prompt,
            image_urls: [dataURI(for: jpegData, mimeType: "image/jpeg")]
        )

        let submitURL = AppConfig.falQueueBaseURL.appendingPathComponent("fal-ai/nano-banana/edit")
        let submit: NanoSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: request,
            apiKey: apiKey
        )

        while true {
            try Task.checkCancellation()
            let status: NanoStatusResponse = try await performRawRequest(url: submit.status_url, apiKey: apiKey)
            switch status.status.lowercased() {
            case "completed":
                let result: NanoResult = try await performRawRequest(url: submit.response_url, apiKey: apiKey)
                guard let url = result.images?.first?.url else {
                    throw UploadPipelineError.requestFailed("nano-banana returned no image.")
                }
                let nanoData = try await downloadData(from: url, apiKey: apiKey)
                guard let nanoImage = UIImage(data: nanoData) else {
                    throw UploadPipelineError.decodingFailed
                }

                // Catalog products keep nano's white studio canvas —
                // identical to the server polish's output family.
                guard transparentCutout else { return nanoImage }

                // nano-banana returns the thumbnail with a white studio
                // background. Pipe it through Bria so the saved product image
                // has a transparent background — matches every other product
                // thumbnail in the app.
                await onUpdate(FalProductThumbnailProgress(
                    title: "Generating thumbnail",
                    detail: "Removing the background from the thumbnail."
                ))
                guard let jpegData = nanoImage.jpegData(compressionQuality: 0.92) else {
                    throw UploadPipelineError.requestFailed("Could not encode thumbnail for background removal.")
                }
                let cleanedData = try await FalBackgroundRemovalService.shared.removeBackground(from: jpegData) { _ in }
                guard let cleanedImage = UIImage(data: cleanedData) else {
                    throw UploadPipelineError.decodingFailed
                }
                // Tight-crop to the visible garment so the saved thumbnail
                // matches the framing of bundled product images — otherwise
                // the transparent margin around the garment makes Quick Add
                // products look smaller than other products in the carousel.
                return Self.tightCrop(cleanedImage, paddingFraction: 0.04)
            case "failed", "error":
                throw UploadPipelineError.requestFailed(status.error?.message ?? "nano-banana failed.")
            default:
                await onUpdate(FalProductThumbnailProgress(
                    title: "Generating thumbnail",
                    detail: status.queue_position.map { "Queue position: \($0)." } ?? "nano-banana is generating."
                ))
            }
            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    // MARK: - Tight crop

    /// Centre the garment on a square transparent canvas so it lands cleanly
    /// in the app's 72pt product slots without ever cutting off the garment
    /// itself. We do NOT trim any visible pixels — only the surrounding
    /// transparent margin is replaced with a tighter, *square* canvas.
    nonisolated static func tightCrop(_ rawImage: UIImage, paddingFraction: CGFloat) -> UIImage {
        // Always normalize: redraw via UIKit so the resulting cgImage is
        // in standard top-down layout matching the visual orientation.
        // We don't trust the imageOrientation flag — Bria's outputs have
        // a flag/cgImage mismatch that breaks naive cgImage handling.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = rawImage.scale
        format.opaque = false
        let normalizer = UIGraphicsImageRenderer(size: rawImage.size, format: format)
        let normalized = normalizer.image { _ in
            rawImage.draw(in: CGRect(origin: .zero, size: rawImage.size))
        }

        guard let cg = normalized.cgImage else { return rawImage }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return rawImage }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        // Read pixels for bbox detection. No Y-flip on the read context: a
        // CGContext bitmap stores memory rows top-down (row 0 = visual top
        // of the drawn cgImage). The previous version flipped Y here and
        // it inverted the bbox — the math expected memory rows in cgImage
        // py order (top-down) but got bottom-up, which shifted the bbox
        // off-centre when the result was re-rendered.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let readCtx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return rawImage }
        readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let rowOffset = y * w * 4
            for x in 0..<w {
                if pixels[rowOffset + x * 4 + 3] > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return rawImage }

        // Convert bbox from cgImage pixel coords to PT for the renderer.
        let scale = normalized.scale
        let bboxPT = CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
        let pad = max(bboxPT.width, bboxPT.height) * paddingFraction
        let side = max(bboxPT.width, bboxPT.height) + pad * 2

        // Draw the normalized image into a square canvas, offset so the
        // bbox sits dead-centre. Use UIImage.draw so orientation is
        // applied correctly.
        let outRenderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return outRenderer.image { _ in
            let drawOriginX = side / 2 - bboxPT.midX
            let drawOriginY = side / 2 - bboxPT.midY
            normalized.draw(in: CGRect(x: drawOriginX, y: drawOriginY, width: normalized.size.width, height: normalized.size.height))
        }
    }

    // MARK: - FAL plumbing (mirrors FalSegmentationService)

    /// Legacy stub — FAL key lives server-side; `AIProxyClient`
    /// strips the empty Authorization header and the proxy injects
    /// the real key before forwarding.
    private func loadFalAPIKey() throws -> String { "" }

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
        let (data, response) = try await AIProxyClient.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UploadPipelineError.requestFailed("FAL \((response as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))")
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw UploadPipelineError.decodingFailed
        }
        return decoded
    }

    private func downloadData(from url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await AIProxyClient.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Thumbnail download failed.")
        }
        return data
    }
}

private struct NanoRequest: Encodable {
    let prompt: String
    let image_urls: [String]
}

private struct NanoSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
}

private struct NanoStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let error: NanoStatusError?
}

private struct NanoStatusError: Decodable {
    let message: String?
}

private struct NanoResult: Decodable {
    let images: [NanoMedia]?
}

private struct NanoMedia: Decodable {
    let url: URL
}

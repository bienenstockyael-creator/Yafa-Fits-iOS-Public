import Foundation
import UIKit

struct FalDressAvatarProgress: Sendable {
    let title: String
    let detail: String
}

/// Composes the standardised avatar with up to three garment references
/// (top, bottom, shoes) into a dressed image using a two-pass flow:
///
/// 1. **nano-banana edit** — submits the avatar + all garment references
///    in a single call with a tightly-worded prompt. Fast (~10-15s) and
///    the only FAL model that handles top + bottom + shoes in one shot.
///    Its weakness is identity drift: face and hair don't always survive.
///
/// 2. **Bria** — transparent background, matching how the avatar itself
///    is stored.
///
/// We previously had a face-swap step in between to lock identity, but
/// every FAL face-swap endpoint we tried (Easel, Half-Moon) was either
/// deprecated (HTTP 500) or returned 404. The face-swap slot is left as
/// a TODO — when a working hair-aware face-swap returns to FAL (or we
/// build a SAM-based composite), insert the pass between steps 1 and 2.
/// For now, identity preservation rests on nano-banana's prompt alone.
actor FalDressAvatarService {
    static let shared = FalDressAvatarService()

    private static let nanoEditEndpoint = "fal-ai/nano-banana/edit"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func dress(
        avatar: UIImage,
        topImageURL: URL?,
        bottomImageURL: URL?,
        shoesImageURL: URL?,
        onUpdate: @escaping @Sendable (FalDressAvatarProgress) async -> Void
    ) async throws -> UIImage {
        // Encode at moderate quality + downscale long edge to 1024 to keep
        // base64 payload size down. nano-banana's POST body is the avatar
        // + up to 3 garment images all as data URIs, which can otherwise
        // push past FAL's body-size limit and trigger a 500.
        guard let avatarJPEG = encodeForFAL(avatar) else {
            throw UploadPipelineError.requestFailed("Could not encode avatar.")
        }
        let apiKey = try loadFalAPIKey()

        // Step 1: nano-banana — dress the avatar in one call.
        try Task.checkCancellation()
        await onUpdate(FalDressAvatarProgress(
            title: "Dressing your avatar",
            detail: "Step 1/2: Composing the look."
        ))
        let dressedJPEG: Data
        do {
            dressedJPEG = try await runNanoBananaDress(
                avatarJPEG: avatarJPEG,
                topImageURL: topImageURL,
                bottomImageURL: bottomImageURL,
                shoesImageURL: shoesImageURL,
                apiKey: apiKey,
                onUpdate: onUpdate
            )
        } catch {
            throw labeled(error, step: "Step 1 (composing)")
        }

        // Step 2: Bria — transparent background.
        try Task.checkCancellation()
        await onUpdate(FalDressAvatarProgress(
            title: "Dressing your avatar",
            detail: "Step 2/2: Removing background."
        ))
        let cleanedData: Data
        do {
            cleanedData = try await FalBackgroundRemovalService.shared
                .removeBackground(from: dressedJPEG) { _ in }
        } catch {
            throw labeled(error, step: "Step 2 (bg removal)")
        }
        guard let cleanedImage = UIImage(data: cleanedData) else {
            throw UploadPipelineError.decodingFailed
        }

        // nano-banana → Bria typically returns a tight crop with body
        // filling 100% of the canvas (head at top edge, feet at bottom
        // edge). The closet's avatar styling (frame + scaleEffect)
        // assumes ~80% body framing, so without this step the dressed
        // avatar appears way bigger than the source. recenterToMatch
        // hard-scales by 0.80 and centres the result in a source-sized
        // canvas, producing the same ~80% body framing as the source.
        if let recentered = recenterToMatch(dressed: cleanedImage, source: avatar) {
            return recentered
        }
        return cleanedImage
    }

    /// Forces dressed to render at a fixed 80% scale on a canvas matching
    /// source's pixel dimensions, centred. No bbox detection, no scale
    /// math — just `scale = 0.80` and centre.
    ///
    /// This is the most aggressive possible recenter:
    /// - nano-banana → Bria typically outputs the body filling 100% of
    ///   its canvas (tight crop, no margin around head/feet). That's the
    ///   "dressed too big / head + feet clipped" we keep seeing.
    /// - Standardised avatars typically have body filling ~80% of canvas
    ///   (margin around head and feet). That's the framing we want to
    ///   match.
    /// - Multiplying dressed by 0.80 takes "100% body" → "80% body" by
    ///   construction. Centred drawing puts the body in the middle of
    ///   the source canvas, with 10% margin above and 10% margin below.
    ///
    /// If a particular dressed output isn't 100% body (e.g. nano-banana
    /// already gave us a loose framing), this scales it down further than
    /// needed and the body looks small in the closet — that's a knob to
    /// tune (raise the 0.80 to 0.90 or 1.0). Critically, this version
    /// **cannot** produce the over-scale / clipped-head-and-feet bug
    /// because the scale is hard-coded.
    private func recenterToMatch(dressed: UIImage, source: UIImage) -> UIImage? {
        guard let sourceCg = source.cgImage,
              let dressedCg = dressed.cgImage else { return nil }

        let sourceW = CGFloat(sourceCg.width)
        let sourceH = CGFloat(sourceCg.height)
        let dressedW = CGFloat(dressedCg.width)
        let dressedH = CGFloat(dressedCg.height)

        // Hard-coded scale — see doc comment above for the rationale.
        let scale: CGFloat = 0.80

        let scaledW = dressedW * scale
        let scaledH = dressedH * scale

        // Centre the scaled image inside the source canvas.
        let drawX = (sourceW - scaledW) / 2
        let drawY = (sourceH - scaledH) / 2

        let dressedScale1 = UIImage(
            cgImage: dressedCg,
            scale: 1,
            orientation: .up
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: sourceW, height: sourceH),
            format: format
        )
        return renderer.image { _ in
            dressedScale1.draw(in: CGRect(
                x: drawX,
                y: drawY,
                width: scaledW,
                height: scaledH
            ))
        }
    }

    /// Returns the rectangle bounding the non-transparent pixels of
    /// `cgImage`, in the image's own pixel coordinate space. Same
    /// approach used by `FalProductThumbnailService.tightCrop`.
    private func alphaBbox(of cgImage: CGImage) -> CGRect? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let rowOffset = y * w * 4
            for x in 0..<w {
                // Threshold > 0 catches anti-aliased edges with low alpha
                // values (Bria can leave faint halos around the body).
                if pixels[rowOffset + x * 4 + 3] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func labeled(_ error: Error, step: String) -> Error {
        let original = (error as? UploadPipelineError)?.errorDescription ?? error.localizedDescription
        return UploadPipelineError.requestFailed("\(step) failed — \(original)")
    }

    // MARK: - nano-banana dressing pass

    private func runNanoBananaDress(
        avatarJPEG: Data,
        topImageURL: URL?,
        bottomImageURL: URL?,
        shoesImageURL: URL?,
        apiKey: String,
        onUpdate: @escaping @Sendable (FalDressAvatarProgress) async -> Void
    ) async throws -> Data {
        // Build the prompt + image list together so the prompt's positional
        // references (`image 2`, `image 3`...) line up exactly with the
        // garment images we attach.
        var imageURIs: [String] = [dataURI(for: avatarJPEG, mimeType: "image/jpeg")]
        var topIndex: Int?
        var bottomIndex: Int?
        var shoesIndex: Int?

        if let url = topImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            imageURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            topIndex = imageURIs.count
        }
        if let url = bottomImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            imageURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            bottomIndex = imageURIs.count
        }
        if let url = shoesImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            imageURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            shoesIndex = imageURIs.count
        }

        let prompt = buildDressPrompt(
            topIndex: topIndex,
            bottomIndex: bottomIndex,
            shoesIndex: shoesIndex
        )

        let request = NanoRequest(prompt: prompt, image_urls: imageURIs)
        let submitURL = AppConfig.falQueueBaseURL
            .appendingPathComponent(Self.nanoEditEndpoint)
        let submit: QueueSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: request,
            apiKey: apiKey
        )

        while true {
            try Task.checkCancellation()
            let status: QueueStatusResponse = try await performRawRequest(
                url: submit.status_url, apiKey: apiKey
            )
            switch status.status.lowercased() {
            case "completed":
                let result: NanoResult = try await performRawRequest(
                    url: submit.response_url, apiKey: apiKey
                )
                guard let imageURL = result.images?.first?.url else {
                    throw UploadPipelineError.requestFailed("nano-banana returned no image.")
                }
                return try await downloadData(from: imageURL, apiKey: apiKey)
            case "failed", "error":
                throw UploadPipelineError.requestFailed(
                    status.error?.message ?? "nano-banana failed."
                )
            default:
                await onUpdate(FalDressAvatarProgress(
                    title: "Dressing your avatar",
                    detail: status.queue_position
                        .map { "Step 1/3: queue \($0)." }
                        ?? "Step 1/3: Composing the look."
                ))
            }
            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    private func buildDressPrompt(topIndex: Int?, bottomIndex: Int?, shoesIndex: Int?) -> String {
        var replacementRules: [String] = []
        if let i = topIndex {
            replacementRules.append("Replace the top with the garment from image \(i) (match colour, pattern, and length).")
        }
        if let i = bottomIndex {
            replacementRules.append("Replace the bottom with the garment from image \(i) (match colour, pattern, and length).")
        }
        if let i = shoesIndex {
            replacementRules.append("Replace the shoes with the footwear from image \(i).")
        }

        // Short and focused. Two non-negotiables up front:
        //   1. Same person — keep image 1's face/hair/body.
        //   2. Same framing — full body, same crop, same pose; this stops
        //      nano-banana from zooming the output into a portrait crop.
        var lines: [String] = [
            "Edit image 1: keep the same person and the same framing. Full body head-to-feet, standing facing the camera, arms relaxed, white studio background.",
            "Keep image 1's face, eyes, nose, mouth, hair (length, colour, texture, style), skin tone, and body shape exactly.",
        ]
        lines.append(contentsOf: replacementRules)
        return lines.joined(separator: " ")
    }

    // MARK: - FAL plumbing

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

    /// JPEG-encode at a size + quality safe for FAL's POST body limit.
    /// Long edge capped at 1024px and quality at 0.85 — at this size the
    /// avatar/garment is ~150-300KB JPEG, ~200-400KB base64 — well under
    /// the limit even with four images concatenated into one body.
    ///
    /// CRITICAL: composites onto a white canvas FIRST. JPEG can't carry
    /// alpha, and UIImage's default flatten is black, which makes
    /// nano-banana see a body-on-black source and tends to push it toward
    /// a tighter portrait crop in the output. White matches the
    /// standardised studio look and preserves framing better.
    private func encodeForFAL(_ image: UIImage) -> Data? {
        let whiteBacked = compositeOntoWhite(image)
        let maxEdge: CGFloat = 1024
        let longest = max(whiteBacked.size.width, whiteBacked.size.height)
        guard longest > 0 else { return nil }
        if longest <= maxEdge {
            return whiteBacked.jpegData(compressionQuality: 0.85)
        }
        let scale = maxEdge / longest
        let newSize = CGSize(width: whiteBacked.size.width * scale, height: whiteBacked.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            whiteBacked.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// Flattens a UIImage onto a white canvas, preserving its dimensions
    /// and aspect. Used to give nano-banana a clean studio backdrop on
    /// every input regardless of whether the source PNG had alpha.
    private func compositeOntoWhite(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }

    private func downloadGarment(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Failed to fetch garment image.")
        }
        return data
    }

    /// Downloads a garment image and re-encodes it through `encodeForFAL`
    /// so it stays under the body-size budget alongside the other images.
    private func downloadAndShrinkGarment(from url: URL) async throws -> Data {
        let raw = try await downloadGarment(from: url)
        guard let image = UIImage(data: raw) else { return raw }
        return encodeForFAL(image) ?? raw
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
            throw UploadPipelineError.requestFailed(
                "FAL \((response as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))"
            )
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw UploadPipelineError.decodingFailed
        }
        return decoded
    }

    private func downloadData(from url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Dressed avatar download failed.")
        }
        return data
    }
}

// MARK: - Wire formats

private struct NanoRequest: Encodable {
    let prompt: String
    let image_urls: [String]
}

private struct QueueSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
}

private struct QueueStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let error: QueueStatusError?
}

private struct QueueStatusError: Decodable {
    let message: String?
}

private struct NanoResult: Decodable {
    let images: [NanoMedia]?
}

private struct NanoMedia: Decodable {
    let url: URL
}

import Foundation
import UIKit

/// Composes the standardised avatar with up to three garment references
/// (top, bottom, shoes) into a dressed image using OpenAI's
/// `gpt-image-2-2026-04-21` for the dressing pass, then reuses FAL Bria
/// for background removal and the same alpha-recenter logic as
/// `FalDressAvatarService`.
///
/// Parallel implementation to `FalDressAvatarService` — toggle which one
/// runs via `AppConfig.useOpenAIDressModel` or the in-app header
/// switcher in the Virtual Closet. gpt-image-2 generally has better
/// identity preservation than nano-banana but is slower (~20-40s) and
/// costs more per image.
///
/// Auth: looks for `OPENAI_API_KEY` (env), falls back to `OpenAIAPIKey`
/// in Info.plist.
actor OpenAIDressAvatarService {
    static let shared = OpenAIDressAvatarService()

    private static let editsPath = "images/edits"

    private let session: URLSession

    init(session: URLSession = .shared) {
        // gpt-image-1 can take 20-40s per generation; use a session with
        // a generous timeout so the request doesn't get cancelled mid-flight.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    func dress(
        avatar: UIImage,
        topImageURL: URL?,
        bottomImageURL: URL?,
        shoesImageURL: URL?,
        onUpdate: @escaping @Sendable (FalDressAvatarProgress) async -> Void
    ) async throws -> UIImage {
        guard let avatarJPEG = encodeForAPI(avatar) else {
            throw UploadPipelineError.requestFailed("Could not encode avatar.")
        }
        let apiKey = try loadOpenAIAPIKey()

        // Step 1: gpt-image-1 dress pass.
        try Task.checkCancellation()
        await onUpdate(FalDressAvatarProgress(
            title: "Dressing your avatar",
            detail: "Step 1/2: Composing the look (this can take 20-40s)."
        ))
        let dressedJPEG: Data
        do {
            dressedJPEG = try await runOpenAIDress(
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

        // Step 2: Bria background removal — reuses the existing FAL service.
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

        // Same recenter strategy as the FAL service — gpt-image-1 also
        // tends to output a tight body crop, and the closet's avatar
        // styling expects ~80% body framing.
        if let recentered = recenterToMatch(dressed: cleanedImage, source: avatar) {
            return recentered
        }
        return cleanedImage
    }

    // MARK: - gpt-image-1 dress pass

    private func runOpenAIDress(
        avatarJPEG: Data,
        topImageURL: URL?,
        bottomImageURL: URL?,
        shoesImageURL: URL?,
        apiKey: String,
        onUpdate: @escaping @Sendable (FalDressAvatarProgress) async -> Void
    ) async throws -> Data {
        // Build the image list + prompt together so the prompt's positional
        // references (`image 2`, `image 3`...) line up with the actual
        // garment image order.
        var blobs: [(filename: String, data: Data)] = [("avatar.jpg", avatarJPEG)]
        var topIndex: Int?, bottomIndex: Int?, shoesIndex: Int?

        if let url = topImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            blobs.append(("top.jpg", data))
            topIndex = blobs.count
        }
        if let url = bottomImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            blobs.append(("bottom.jpg", data))
            bottomIndex = blobs.count
        }
        if let url = shoesImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            blobs.append(("shoes.jpg", data))
            shoesIndex = blobs.count
        }

        let prompt = buildDressPrompt(
            topIndex: topIndex,
            bottomIndex: bottomIndex,
            shoesIndex: shoesIndex
        )

        // Construct multipart body. gpt-image-1 accepts an array of
        // input images via repeated `image[]` form fields (up to 16).
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        appendField(name: "model", value: "gpt-image-2-2026-04-21", to: &body, boundary: boundary)
        appendField(name: "prompt", value: prompt, to: &body, boundary: boundary)
        appendField(name: "size", value: "1024x1536", to: &body, boundary: boundary)
        appendField(name: "n", value: "1", to: &body, boundary: boundary)
        for blob in blobs {
            appendFile(
                name: "image[]",
                filename: blob.filename,
                contentType: "image/jpeg",
                data: blob.data,
                to: &body,
                boundary: boundary
            )
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = AppConfig.openAIBaseURL.appendingPathComponent(Self.editsPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        await onUpdate(FalDressAvatarProgress(
            title: "Dressing your avatar",
            detail: "Step 1/2: gpt-image-1 working..."
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadPipelineError.requestFailed("Invalid response from OpenAI.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UploadPipelineError.requestFailed(
                "OpenAI \(http.statusCode): \(text.prefix(500))"
            )
        }

        let result = try JSONDecoder().decode(OpenAIImagesResponse.self, from: data)
        guard let b64 = result.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64) else {
            throw UploadPipelineError.requestFailed("OpenAI returned no image data.")
        }
        return imageData
    }

    private func buildDressPrompt(topIndex: Int?, bottomIndex: Int?, shoesIndex: Int?) -> String {
        var rules: [String] = []
        if let i = topIndex {
            rules.append("Replace the top with the garment from image \(i) (match colour, pattern, and length).")
        }
        if let i = bottomIndex {
            rules.append("Replace the bottom with the garment from image \(i) (match colour, pattern, and length).")
        }
        if let i = shoesIndex {
            rules.append("Replace the shoes with the footwear from image \(i).")
        }

        var lines: [String] = [
            "Edit image 1: keep the same person and the same framing. Full body head-to-feet, standing facing the camera, arms relaxed, white studio background.",
            "Keep image 1's face, eyes, nose, mouth, hair (length, colour, texture, style), skin tone, and body shape exactly.",
        ]
        lines.append(contentsOf: rules)
        return lines.joined(separator: " ")
    }

    // MARK: - Recenter (mirrors FalDressAvatarService.recenterToMatch)

    private func recenterToMatch(dressed: UIImage, source: UIImage) -> UIImage? {
        guard let sourceCg = source.cgImage,
              let dressedCg = dressed.cgImage else { return nil }
        let sourceW = CGFloat(sourceCg.width)
        let sourceH = CGFloat(sourceCg.height)
        let dressedW = CGFloat(dressedCg.width)
        let dressedH = CGFloat(dressedCg.height)
        let scale: CGFloat = 0.80
        let scaledW = dressedW * scale
        let scaledH = dressedH * scale
        let drawX = (sourceW - scaledW) / 2
        let drawY = (sourceH - scaledH) / 2
        let dressedScale1 = UIImage(cgImage: dressedCg, scale: 1, orientation: .up)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: sourceW, height: sourceH),
            format: format
        )
        return renderer.image { _ in
            dressedScale1.draw(in: CGRect(x: drawX, y: drawY, width: scaledW, height: scaledH))
        }
    }

    // MARK: - Image encoding (mirrors FalDressAvatarService helpers)

    /// JPEG-encode at 1024-long-edge / quality 0.85. gpt-image-1 caps
    /// each input at 4MB; this stays well under that.
    private func encodeForAPI(_ image: UIImage) -> Data? {
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

    private func downloadAndShrinkGarment(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Failed to fetch garment image.")
        }
        guard let image = UIImage(data: data) else { return data }
        return encodeForAPI(image) ?? data
    }

    // MARK: - Multipart helpers

    private func appendField(name: String, value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        to body: inout Data,
        boundary: String
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    // MARK: - Auth

    private func loadOpenAIAPIKey() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let k = env["OPENAI_API_KEY"], !k.isEmpty { return k }
        if let k = env["OpenAIAPIKey"], !k.isEmpty { return k }
        if let k = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String,
           !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return k
        }
        throw UploadPipelineError.requestFailed(
            "Missing OPENAI_API_KEY — add to env vars or OpenAIAPIKey in Info.plist."
        )
    }

    private func labeled(_ error: Error, step: String) -> Error {
        let original = (error as? UploadPipelineError)?.errorDescription ?? error.localizedDescription
        return UploadPipelineError.requestFailed("\(step) failed — \(original)")
    }
}

// MARK: - Wire format

private struct OpenAIImagesResponse: Decodable {
    let data: [OpenAIImageData]
}

private struct OpenAIImageData: Decodable {
    let b64_json: String?
}

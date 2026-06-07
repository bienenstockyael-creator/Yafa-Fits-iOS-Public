import Foundation
import UIKit

/// Composes the standardised avatar with up to three garment references
/// (top, bottom, shoes) into a dressed image using OpenAI's gpt-image-2
/// model, routed through FAL's hosted endpoint (`openai/gpt-image-2/edit`).
/// Then reuses FAL Bria for background removal and the same alpha-recenter
/// logic as `FalDressAvatarService`.
///
/// Parallel implementation to `FalDressAvatarService` — toggle which one
/// runs via `AppConfig.useOpenAIDressModel` or the in-app header
/// switcher in the Virtual Closet. gpt-image-2 generally has better
/// identity preservation than nano-banana but is slower (~20-40s) and
/// costs more per image.
///
/// Auth: uses the same FAL key as every other FAL service in this app.
actor OpenAIDressAvatarService {
    static let shared = OpenAIDressAvatarService()

    private static let editsPath = "openai/gpt-image-2/edit"

    private let session: URLSession

    init(session: URLSession = .shared) {
        // gpt-image-2 generations can take 20-40s; use a session with
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
        let apiKey = try loadFalAPIKey()

        // Step 1: gpt-image-2 dress pass via FAL.
        try Task.checkCancellation()
        await onUpdate(FalDressAvatarProgress(
            title: "Dressing your avatar",
            detail: "Step 1/2: Composing the look (this can take 20-40s)."
        ))
        let dressedData: Data
        do {
            dressedData = try await runFalDress(
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
                .removeBackground(from: dressedData) { _ in }
        } catch {
            throw labeled(error, step: "Step 2 (bg removal)")
        }
        guard let cleanedImage = UIImage(data: cleanedData) else {
            throw UploadPipelineError.decodingFailed
        }

        // Same recenter strategy as FalDressAvatarService — gpt-image-2 also
        // tends to output a tight body crop, and the closet's avatar
        // styling expects ~80% body framing.
        if let recentered = recenterToMatch(dressed: cleanedImage, source: avatar) {
            return recentered
        }
        return cleanedImage
    }

    // MARK: - FAL gpt-image-2 dress pass

    private func runFalDress(
        avatarJPEG: Data,
        topImageURL: URL?,
        bottomImageURL: URL?,
        shoesImageURL: URL?,
        apiKey: String,
        onUpdate: @escaping @Sendable (FalDressAvatarProgress) async -> Void
    ) async throws -> Data {
        // Build the image list + prompt together so the prompt's positional
        // references (`image 2`, `image 3`...) line up with the actual
        // garment image order in image_urls.
        var dataURIs: [String] = [dataURI(for: avatarJPEG, mimeType: "image/jpeg")]
        var topIndex: Int?, bottomIndex: Int?, shoesIndex: Int?

        if let url = topImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            dataURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            topIndex = dataURIs.count
        }
        if let url = bottomImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            dataURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            bottomIndex = dataURIs.count
        }
        if let url = shoesImageURL {
            let data = try await downloadAndShrinkGarment(from: url)
            dataURIs.append(dataURI(for: data, mimeType: "image/jpeg"))
            shoesIndex = dataURIs.count
        }

        let prompt = buildDressPrompt(
            topIndex: topIndex,
            bottomIndex: bottomIndex,
            shoesIndex: shoesIndex
        )

        let payload = GPTImageEditRequest(
            prompt: prompt,
            image_urls: dataURIs,
            image_size: GPTImageSize(width: 1024, height: 1536),
            num_images: 1,
            quality: "high",
            output_format: "png"
        )

        let submitURL = AppConfig.falQueueBaseURL.appendingPathComponent(Self.editsPath)
        let submit: GPTImageSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: payload,
            apiKey: apiKey
        )

        while true {
            try Task.checkCancellation()
            let status: GPTImageStatusResponse = try await performRawRequest(url: submit.status_url, apiKey: apiKey)
            switch status.status.lowercased() {
            case "completed":
                let result: GPTImageResult = try await performRawRequest(url: submit.response_url, apiKey: apiKey)
                guard let url = result.images?.first?.url else {
                    throw UploadPipelineError.requestFailed("FAL gpt-image-2 returned no image.")
                }
                return try await downloadData(from: url, apiKey: apiKey)
            case "failed", "error":
                throw UploadPipelineError.requestFailed(status.error?.message ?? "FAL gpt-image-2 failed.")
            default:
                await onUpdate(FalDressAvatarProgress(
                    title: "Dressing your avatar",
                    detail: status.queue_position.map { "Queue position: \($0)." } ?? "Step 1/2: gpt-image-2 working..."
                ))
            }
            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
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

    /// JPEG-encode at 1024-long-edge / quality 0.85. Keeps each base64
    /// payload small enough to embed comfortably in the FAL JSON body.
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

    // MARK: - FAL plumbing (mirrors FalProductThumbnailService)

    /// Legacy stub — FAL/OpenAI keys live server-side;
    /// `AIProxyClient` strips the empty Authorization header and
    /// the proxy injects the real key before forwarding.
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
            throw UploadPipelineError.requestFailed("Dressed image download failed.")
        }
        return data
    }

    private func labeled(_ error: Error, step: String) -> Error {
        let original = (error as? UploadPipelineError)?.errorDescription ?? error.localizedDescription
        return UploadPipelineError.requestFailed("\(step) failed — \(original)")
    }
}

// MARK: - Wire format

private struct GPTImageEditRequest: Encodable {
    let prompt: String
    let image_urls: [String]
    let image_size: GPTImageSize
    let num_images: Int
    let quality: String
    let output_format: String
}

private struct GPTImageSize: Encodable {
    let width: Int
    let height: Int
}

private struct GPTImageSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
}

private struct GPTImageStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let error: GPTImageStatusError?
}

private struct GPTImageStatusError: Decodable {
    let message: String?
}

private struct GPTImageResult: Decodable {
    let images: [GPTImageMedia]?
}

private struct GPTImageMedia: Decodable {
    let url: URL
}

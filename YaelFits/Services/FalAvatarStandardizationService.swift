import Foundation
import UIKit

struct FalAvatarStandardizationProgress: Sendable {
    let title: String
    let detail: String
}

/// Takes a user-supplied reference photo and returns a "clean" avatar:
/// neutral white tee + white shorts, soft studio lighting, white background,
/// preserving the user's face/body proportions. The standardized image is
/// the canonical avatar reused across every Virtual Closet generation, so
/// outfits applied later can be mixed-and-matched against a stable subject.
actor FalAvatarStandardizationService {
    static let shared = FalAvatarStandardizationService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func standardize(
        from photo: UIImage,
        onUpdate: @escaping @Sendable (FalAvatarStandardizationProgress) async -> Void
    ) async throws -> UIImage {
        guard let jpegData = photo.jpegData(compressionQuality: 0.9) else {
            throw UploadPipelineError.requestFailed("Could not encode reference photo.")
        }
        let apiKey = try loadFalAPIKey()

        let prompt = [
            "Edit this photograph of the same person — do NOT generate a different person.",
            "Identity is critical: keep the exact same face, facial features, eye shape, eye colour, nose, lips, jawline, eyebrows, skin tone, freckles, and any unique markings.",
            "Keep the exact same hair: same length, same texture, same colour, same volume, same parting. If the hair is long, keep it long. If curly, keep it curly. If tied up, keep it tied up.",
            "Keep the exact same body shape, height, weight, build, and proportions. Do not slim, stretch, or alter the body.",
            "The only allowed changes are: clothing, background, lighting, and pose.",
            "Replace the current outfit with a plain white short-sleeve crew-neck t-shirt and plain white mid-thigh shorts. No prints, logos, patterns, embroidery, or text. Plain white sneakers on the feet.",
            "Remove the original background entirely. Output the person isolated on a clean white seamless background, no walls, no floor, no furniture, no objects, no other people.",
            "Soft, even, neutral studio lighting on the subject.",
            "Pose: standing facing the camera straight on, full body from head to feet, arms relaxed at their sides, neutral relaxed expression. If the input shows a mirror selfie or a phone in hand, remove the phone and the mirror — but keep every facial feature identical to the input.",
            "No accessories, no hats, no sunglasses, no jewellery, no phone, no mirror, no bags.",
        ].joined(separator: " ")

        await onUpdate(FalAvatarStandardizationProgress(
            title: "Standardising your avatar",
            detail: "Asking nano-banana for a clean studio photo."
        ))

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

                // nano-banana returns a white-background composite. Pipe it
                // through Bria so the saved avatar is on a clean transparent
                // background — every Closet "dress" composite stacks on top
                // of this without a visible studio backdrop.
                await onUpdate(FalAvatarStandardizationProgress(
                    title: "Standardising your avatar",
                    detail: "Removing the background."
                ))
                guard let standardJpeg = nanoImage.jpegData(compressionQuality: 0.92) else {
                    throw UploadPipelineError.requestFailed("Could not encode avatar for background removal.")
                }
                let cleanedData = try await FalBackgroundRemovalService.shared.removeBackground(from: standardJpeg) { _ in }
                guard let cleanedImage = UIImage(data: cleanedData) else {
                    throw UploadPipelineError.decodingFailed
                }
                return cleanedImage
            case "failed", "error":
                throw UploadPipelineError.requestFailed(status.error?.message ?? "nano-banana failed.")
            default:
                await onUpdate(FalAvatarStandardizationProgress(
                    title: "Standardising your avatar",
                    detail: status.queue_position.map { "Queue position: \($0)." } ?? "nano-banana is generating."
                ))
            }
            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    // MARK: - FAL plumbing (mirrors FalProductThumbnailService)

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

    private func downloadData(from url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadPipelineError.requestFailed("Avatar download failed.")
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

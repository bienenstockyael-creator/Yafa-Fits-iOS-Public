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

    /// Generate a clean flat-lay product thumbnail from a cropped garment image
    /// using FAL's nano-banana edit endpoint.
    ///
    /// - Parameters:
    ///   - garment: image of a single clothing item, ideally pre-segmented and
    ///     cropped (transparent background outside the item is fine — nano-banana
    ///     handles it well).
    ///   - label: what the user called the item, e.g. "Striped Sweater". Used
    ///     in the prompt so the model knows the garment type.
    func generateThumbnail(
        from garment: UIImage,
        label: String,
        onUpdate: @escaping @Sendable (FalProductThumbnailProgress) async -> Void
    ) async throws -> UIImage {
        guard let pngData = garment.pngData() else {
            throw UploadPipelineError.requestFailed("Could not encode garment image.")
        }
        let apiKey = try loadFalAPIKey()

        let prompt = [
            "Professional flat-lay product photograph of this single \(label.isEmpty ? "garment" : label).",
            "Clean white background, studio lighting, no body, no model, no skin showing.",
            "The garment laid flat or on an invisible mannequin, e-commerce catalog style.",
        ].joined(separator: " ")

        await onUpdate(FalProductThumbnailProgress(title: "Generating thumbnail", detail: "Asking nano-banana for a clean product shot."))

        let request = NanoRequest(
            prompt: prompt,
            image_urls: [dataURI(for: pngData, mimeType: "image/png")]
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
                let data = try await downloadData(from: url, apiKey: apiKey)
                guard let image = UIImage(data: data) else {
                    throw UploadPipelineError.decodingFailed
                }
                return image
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

    // MARK: - FAL plumbing (mirrors FalSegmentationService)

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

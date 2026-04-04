import Foundation

struct FalBackgroundRemovalProgress: Sendable {
    let title: String
    let detail: String
}

actor FalBackgroundRemovalService {
    static let shared = FalBackgroundRemovalService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func removeBackground(
        from imageData: Data,
        onUpdate: @escaping @Sendable (FalBackgroundRemovalProgress) async -> Void
    ) async throws -> Data {
        let apiKey = try loadFalAPIKey()
        let requestBody = FalBackgroundRemovalRequest(
            image_url: dataURI(for: imageData, mimeType: "image/jpeg")
        )

        await onUpdate(
            FalBackgroundRemovalProgress(
                title: "Submitting to fal Bria",
                detail: "Uploading the source photo for fal background removal."
            )
        )

        let submitURL = AppConfig.falQueueBaseURL.appendingPathComponent(AppConfig.falBackgroundRemovalModelPath)
        let submitResponse: FalBackgroundRemovalSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: requestBody,
            apiKey: apiKey
        )

        var knownLogs: [String] = []

        while true {
            try Task.checkCancellation()

            let statusResponse: FalBackgroundRemovalStatusResponse = try await performRawRequest(
                url: submitResponse.status_url,
                apiKey: apiKey
            )

            let latestLogs = Array(
                statusResponse.logs?
                    .compactMap(\.message)
                    .filter { !$0.isEmpty }
                    .suffix(4) ?? []
            )
            if !latestLogs.isEmpty {
                knownLogs = latestLogs
            }

            switch statusResponse.status.lowercased() {
            case "in_queue", "queued":
                let detail = statusResponse.queue_position.map {
                    "Waiting for an available runner. Queue position: \($0)."
                } ?? "Waiting for an available runner."
                await onUpdate(
                    FalBackgroundRemovalProgress(
                        title: "Queued at fal Bria",
                        detail: detail
                    )
                )

            case "in_progress", "running":
                await onUpdate(
                    FalBackgroundRemovalProgress(
                        title: "Removing background with fal Bria",
                        detail: knownLogs.last ?? "fal Bria is preparing the cutout."
                    )
                )

            case "completed":
                let resultResponse: FalBackgroundRemovalResult = try await performRawRequest(
                    url: submitResponse.response_url,
                    apiKey: apiKey
                )
                guard let imageURL = resultResponse.image.firstURL else {
                    throw UploadPipelineError.maskGenerationFailed
                }

                await onUpdate(
                    FalBackgroundRemovalProgress(
                        title: "Downloading fal Bria result",
                        detail: "Pulling the removed-background PNG back into the app."
                    )
                )

                return try await downloadImageData(from: imageURL)

            case "failed", "error":
                let message = statusResponse.error?.message ?? "fal Bria background removal failed."
                throw UploadPipelineError.requestFailed(message)

            default:
                break
            }

            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    private func loadFalAPIKey() throws -> String {
        let env = ProcessInfo.processInfo.environment

        if let envKey = env["FALAPIKey"], !envKey.isEmpty {
            return envKey
        }
        if let envKey = env["FAL_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let envKey = env["FAL_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let plistKey = Bundle.main.object(forInfoDictionaryKey: "FALAPIKey") as? String,
           !plistKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plistKey
        }

        throw UploadPipelineError.missingFalKey
    }

    private func dataURI(for data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func performJSONRequest<T: Decodable, Payload: Encodable>(
        url: URL,
        method: String,
        payload: Payload,
        apiKey: String
    ) async throws -> T {
        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)
        return try await performDataRequest(url: url, method: method, body: body, apiKey: apiKey)
    }

    private func performRawRequest<T: Decodable>(url: URL, apiKey: String) async throws -> T {
        try await performDataRequest(url: url, method: "GET", body: nil, apiKey: apiKey)
    }

    private func performDataRequest<T: Decodable>(
        url: URL,
        method: String,
        body: Data?,
        apiKey: String
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
        try validateFal(response: response, data: data)

        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw UploadPipelineError.decodingFailed
        }
        return decoded
    }

    private func validateFal(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadPipelineError.requestFailed("The fal response was invalid.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(FalBackgroundRemovalErrorPayload.self, from: data),
               let detail = payload.detail ?? payload.error ?? payload.message {
                throw UploadPipelineError.requestFailed(detail)
            }

            let bodyText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = bodyText?.isEmpty == false ? bodyText! : "Request failed with status \(httpResponse.statusCode)."
            throw UploadPipelineError.requestFailed(message)
        }
    }

    private func downloadImageData(from remoteURL: URL) async throws -> Data {
        let (data, response) = try await session.data(from: remoteURL)
        try validateFal(response: response, data: data)
        return data
    }
}

private struct FalBackgroundRemovalRequest: Encodable {
    let image_url: String
}

private struct FalBackgroundRemovalSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
    let cancel_url: URL?
    let queue_position: Int?
}

private struct FalBackgroundRemovalStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let logs: [FalBackgroundRemovalLogLine]?
    let error: FalBackgroundRemovalStatusError?
}

private struct FalBackgroundRemovalLogLine: Decodable {
    let message: String?
}

private struct FalBackgroundRemovalStatusError: Decodable {
    let message: String?
}

private struct FalBackgroundRemovalResult: Decodable {
    let image: FalBackgroundRemovalImagePayload
}

private enum FalBackgroundRemovalImagePayload: Decodable {
    case single(FalBackgroundRemovalMedia)
    case multiple([FalBackgroundRemovalMedia])

    var firstURL: URL? {
        switch self {
        case let .single(media):
            return media.url
        case let .multiple(media):
            return media.first?.url
        }
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let media = try? singleValue.decode(FalBackgroundRemovalMedia.self) {
            self = .single(media)
            return
        }
        if let media = try? singleValue.decode([FalBackgroundRemovalMedia].self) {
            self = .multiple(media)
            return
        }
        throw DecodingError.dataCorruptedError(in: singleValue, debugDescription: "Unsupported image payload.")
    }
}

private struct FalBackgroundRemovalMedia: Decodable {
    let url: URL
}

private struct FalBackgroundRemovalErrorPayload: Decodable {
    let detail: String?
    let error: String?
    let message: String?
}

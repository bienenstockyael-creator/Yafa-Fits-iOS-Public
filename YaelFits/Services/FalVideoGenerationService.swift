import Foundation

struct FalGenerationProgress: Sendable {
    let title: String
    let detail: String
    let requestId: String?
    let logLines: [String]
}

actor FalVideoGenerationService {
    static let shared = FalVideoGenerationService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateRotationVideo(
        from greenScreenPNGData: Data,
        prompt: String,
        onUpdate: @escaping @Sendable (FalGenerationProgress) async -> Void
    ) async throws -> URL {
        let apiKey = try loadAPIKey()
        let sourceImageDataURI = dataURI(for: greenScreenPNGData, mimeType: "image/png")
        let requestBody = KlingImageToVideoRequest(
            prompt: prompt,
            image_url: sourceImageDataURI,
            tail_image_url: sourceImageDataURI,
            duration: UploadConfig.falVideoDuration
        )

        await onUpdate(
            FalGenerationProgress(
                title: "Submitting to Kling 2.5",
                detail: "Uploading the green-screen source image as both the start and end frame for a 10-second rotation.",
                requestId: nil,
                logLines: []
            )
        )

        let submitURL = AppConfig.falQueueBaseURL.appendingPathComponent(AppConfig.falModelPath)
        let submitResponse: FalQueueSubmitResponse = try await performJSONRequest(
            url: submitURL,
            method: "POST",
            payload: requestBody,
            apiKey: apiKey
        )

        var knownLogs: [String] = []

        while true {
            try Task.checkCancellation()

            let statusResponse: FalQueueStatusResponse = try await performRawRequest(
                url: submitResponse.status_url,
                apiKey: apiKey
            )

            let status = statusResponse.status.lowercased()
            let latestLogs = Array(
                statusResponse.logs?
                    .compactMap(\.message)
                    .filter { !$0.isEmpty }
                    .suffix(4) ?? []
            )
            if !latestLogs.isEmpty {
                knownLogs = latestLogs
            }

            switch status {
            case "in_queue", "queued":
                let detail = statusResponse.queue_position.map {
                    "Waiting for an available runner. Queue position: \($0)."
                } ?? "Waiting for an available runner."
                await onUpdate(
                    FalGenerationProgress(
                        title: "Queued",
                        detail: detail,
                        requestId: submitResponse.request_id,
                        logLines: knownLogs
                    )
                )

            case "in_progress", "running":
                await onUpdate(
                    FalGenerationProgress(
                        title: "Generating 10-second 360 video",
                        detail: knownLogs.last ?? "Kling is generating the 10-second rotation.",
                        requestId: submitResponse.request_id,
                        logLines: knownLogs
                    )
                )

            case "completed":
                let resultResponse: KlingImageToVideoResponse = try await performRawRequest(
                    url: submitResponse.response_url,
                    apiKey: apiKey
                )
                guard let remoteVideoURL = resultResponse.video.firstURL else {
                    throw UploadPipelineError.missingVideo
                }

                await onUpdate(
                    FalGenerationProgress(
                        title: "Downloading result",
                        detail: "Pulling the generated video back into the app.",
                        requestId: submitResponse.request_id,
                        logLines: knownLogs
                    )
                )

                return try await downloadVideo(from: remoteVideoURL)

            case "failed", "error":
                let message = statusResponse.error?.message ?? "Kling generation failed."
                throw UploadPipelineError.requestFailed(message)

            default:
                break
            }

            try await Task.sleep(for: .seconds(UploadConfig.falPollingIntervalSeconds))
        }
    }

    private func loadAPIKey() throws -> String {
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
        try validate(response: response, data: data)

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(T.self, from: data) else {
            throw UploadPipelineError.decodingFailed
        }
        return decoded
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadPipelineError.requestFailed("The FAL response was invalid.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(FalErrorPayload.self, from: data),
               let detail = payload.detail ?? payload.error ?? payload.message {
                throw UploadPipelineError.requestFailed(detail)
            }

            let bodyText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = bodyText?.isEmpty == false ? bodyText! : "Request failed with status \(httpResponse.statusCode)."
            throw UploadPipelineError.requestFailed(message)
        }
    }

    private func downloadVideo(from remoteURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        try validate(response: response, data: Data())

        let fileExtension = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}

private struct KlingImageToVideoRequest: Encodable {
    let prompt: String
    let image_url: String
    let tail_image_url: String
    let duration: String
}

private struct FalQueueSubmitResponse: Decodable {
    let request_id: String
    let response_url: URL
    let status_url: URL
    let cancel_url: URL?
    let queue_position: Int?
}

private struct FalQueueStatusResponse: Decodable {
    let status: String
    let queue_position: Int?
    let logs: [FalLogLine]?
    let error: FalStatusError?
}

private struct FalLogLine: Decodable {
    let message: String?
}

private struct FalStatusError: Decodable {
    let message: String?
}

private struct KlingImageToVideoResponse: Decodable {
    let video: GeneratedVideoPayload
}

private enum GeneratedVideoPayload: Decodable {
    case single(FalMedia)
    case multiple([FalMedia])

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
        if let media = try? singleValue.decode(FalMedia.self) {
            self = .single(media)
            return
        }
        if let media = try? singleValue.decode([FalMedia].self) {
            self = .multiple(media)
            return
        }
        throw DecodingError.dataCorruptedError(in: singleValue, debugDescription: "Unsupported video payload.")
    }
}

private struct FalMedia: Decodable {
    let url: URL
}

private struct FalErrorPayload: Decodable {
    let detail: String?
    let error: String?
    let message: String?
}

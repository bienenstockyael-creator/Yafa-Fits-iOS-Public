import Foundation
import Supabase

/// Routes outbound FAL/OpenAI HTTP requests through the
/// `fal-proxy` Supabase Edge Function instead of sending them
/// directly. The proxy injects the server-side API key, so the
/// iOS app no longer needs to ship `FALAPIKey` / `OpenAIAPIKey`
/// in its bundle.
///
/// Drop-in replacement for `URLSession.shared.data(for:)` at the
/// HTTP layer. Each FAL service keeps building its own
/// `URLRequest` exactly as before (same target URL, same JSON
/// payload). The only change at call sites is swapping
/// `URLSession.shared.data(for: request)` for
/// `AIProxyClient.shared.data(for: request)`.
///
/// Requests whose host is NOT in `proxiedHosts` pass through
/// unchanged — useful when the same service occasionally hits a
/// non-AI URL (e.g. downloading a public image not behind an API
/// key).
final class AIProxyClient: @unchecked Sendable {
    static let shared = AIProxyClient()

    /// Hosts whose traffic must be routed through the proxy.
    /// Mirrors the allow-list inside the Edge Function — kept in
    /// sync by convention. Anything not on this list passes
    /// through `URLSession.shared` directly.
    private static let proxiedHosts: Set<String> = [
        "queue.fal.run",
        "fal.run",
        "fal.media",
        "v3.fal.media",
        "api.openai.com",
    ]

    /// The deployed Edge Function URL. Built from `SupabaseConfig`
    /// so it tracks whichever project the app is pointed at.
    private static let proxyURL: URL = SupabaseConfig.url
        .appendingPathComponent("functions/v1/fal-proxy")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sends `request` either directly (non-proxied hosts) or
    /// through the proxy (FAL/OpenAI hosts). The returned `(Data,
    /// URLResponse)` mirrors what `URLSession.data(for:)` would
    /// give back — same shape so call sites stay structurally
    /// identical.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let host = request.url?.host,
              Self.proxiedHosts.contains(host) else {
            // Not a proxied host — straight pass-through.
            return try await session.data(for: request)
        }
        return try await proxiedData(for: request)
    }

    private func proxiedData(for original: URLRequest) async throws -> (Data, URLResponse) {
        // Fetch the caller's Supabase JWT. The proxy uses it to
        // verify the request is from an authenticated user before
        // forwarding upstream.
        let jwt: String
        do {
            jwt = try await supabase.auth.session.accessToken
        } catch {
            throw AIProxyError.notAuthenticated
        }

        // Build the proxy payload. Forward the headers as-is
        // EXCEPT the Authorization header — that would carry the
        // FAL/OpenAI key the caller pre-set, but the proxy strips
        // it anyway and injects the real one server-side, so we
        // drop it here to save bytes + avoid logging it anywhere
        // in transit.
        guard let targetURL = original.url?.absoluteString else {
            throw AIProxyError.invalidRequest
        }
        var forwardHeaders: [String: String] = [:]
        if let original = original.allHTTPHeaderFields {
            for (key, value) in original where key.lowercased() != "authorization" {
                forwardHeaders[key] = value
            }
        }

        // Body handling. FAL/OpenAI request bodies are JSON, so
        // we re-parse the bytes into a JSON value and embed that
        // in the proxy payload. This lets the proxy validate /
        // re-encode it on its end. GET requests have no body.
        var bodyValue: Any? = nil
        if let body = original.httpBody, !body.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                bodyValue = json
            } else if let text = String(data: body, encoding: .utf8) {
                bodyValue = text
            } else {
                throw AIProxyError.unsupportedBodyEncoding
            }
        }

        var payload: [String: Any] = [
            "url": targetURL,
            "method": original.httpMethod ?? "POST",
            "headers": forwardHeaders,
        ]
        if let bodyValue {
            payload["body"] = bodyValue
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])

        var proxyRequest = URLRequest(url: Self.proxyURL)
        proxyRequest.httpMethod = "POST"
        proxyRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        proxyRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        proxyRequest.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        proxyRequest.httpBody = payloadData
        // Asset downloads (mask images, generated outfit frames)
        // can be a few MB. Match the original request's timeout
        // so a slow FAL response doesn't get cut short by the
        // proxy hop.
        proxyRequest.timeoutInterval = original.timeoutInterval

        return try await session.data(for: proxyRequest)
    }
}

enum AIProxyError: Error, LocalizedError {
    case notAuthenticated
    case invalidRequest
    case unsupportedBodyEncoding

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in is required to call AI services."
        case .invalidRequest:
            return "Request is missing a valid URL."
        case .unsupportedBodyEncoding:
            return "Request body could not be forwarded to the AI proxy."
        }
    }
}

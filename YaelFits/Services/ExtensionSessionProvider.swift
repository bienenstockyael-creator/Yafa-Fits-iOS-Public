import Foundation
import Supabase

// App-side: provisions the Share Extension's dedicated session.
//
// The app (already signed in) asks `mint-extension-session` for a SEPARATE
// session for the same user, then stashes it in the App Group. The extension
// uses + refreshes that on its own, so neither side can log the other out.
//
// Called from AuthManager: on sign-in (provision), on launch if missing, and
// cleared on sign-out.
enum ExtensionSessionProvider {

    private struct MintResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_at: TimeInterval
        let user_id: String
    }

    /// Mint a fresh extension session and store it in the App Group.
    static func provision() async {
        do {
            let jwt = try await supabase.auth.session.accessToken
            let url = YafaShared.supabaseURL.appendingPathComponent("functions/v1/mint-extension-session")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            request.setValue(YafaShared.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "(no body)"
                print("[ExtensionSession] mint failed: \(body)")
                return
            }
            let r = try JSONDecoder().decode(MintResponse.self, from: data)
            ExtensionSessionStore.save(ExtensionSession(
                accessToken: r.access_token,
                refreshToken: r.refresh_token,
                expiresAt: r.expires_at,
                userId: r.user_id
            ))
            print("[ExtensionSession] provisioned for \(r.user_id)")
        } catch {
            print("[ExtensionSession] provision error: \(error)")
        }
    }

    /// Provision only if the App Group has no session yet (called on launch).
    static func provisionIfMissing() async {
        if ExtensionSessionStore.load() == nil {
            await provision()
        }
    }

    static func clear() {
        ExtensionSessionStore.clear()
    }
}

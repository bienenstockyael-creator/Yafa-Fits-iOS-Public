import Foundation

// Shared between the main app (Yafa) and the Share Extension (YafaShare).
// IMPORTANT: this file's Target Membership must include BOTH targets.
//
// The extension can't use the Supabase SDK (its UIApplication references aren't
// extension-safe, and it would bloat the extension). So the app mints a
// dedicated session via the `mint-extension-session` Edge Function and stashes
// it here, in the App Group container. The extension reads it, refreshes it
// when stale, and writes the rotated tokens back — all without touching the
// app's own login.

enum YafaShared {
    static let appGroup = "group.com.yafa.Yafa"

    // Public client values — mirror SupabaseConfig (the anon key is a public,
    // RLS-scoped key, safe to embed). Duplicated here because the extension
    // can't see app-only types.
    static let supabaseURL = URL(string: "https://dqvwutzoakfmnhbsefsw.supabase.co")!
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRxdnd1dHpvYWtmbW5oYnNlZnN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUzNDQzMDUsImV4cCI6MjA5MDkyMDMwNX0.PWe0-qve1pz9dZilQ1FUwFphcvqXy6N-vr4qj5pKRvI"
}

/// The minted session the extension uses. Codable JSON in App Group defaults.
struct ExtensionSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval   // unix seconds
    var userId: String

    /// True when the access token is still good for at least `margin` seconds.
    func isFresh(margin: TimeInterval = 90) -> Bool {
        expiresAt - Date().timeIntervalSince1970 > margin
    }
}

/// Read/write the extension session in the shared App Group container.
enum ExtensionSessionStore {
    private static let key = "yafa.extensionSession"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: YafaShared.appGroup) }

    static func load() -> ExtensionSession? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExtensionSession.self, from: data)
    }

    static func save(_ session: ExtensionSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults?.set(data, forKey: key)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}

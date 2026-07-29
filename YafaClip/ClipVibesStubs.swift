import Foundation

// Clip-local stand-ins for the app's service layer, letting the
// REAL VibeButton + VibesEffectHost stack compile into the clip
// unchanged. A clip has no account and carries no SDKs, so a vibe
// here is playful: the full burst (wave shader, particles, hero
// morph, haptics) fires exactly as in the app — it just never
// reaches the backend.

enum Analytics {
    enum AnalyticsValue {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
    }

    static func log(_ event: String, properties: [String: AnalyticsValue] = [:]) {}
}

enum VibesService {
    enum GiveResult {
        case success(remainingThisWeek: Int)
        case quotaExhausted
        case alreadyVibed(remainingThisWeek: Int)
        case selfVibe
        case outfitNotFound
        case unauthenticated
        case networkError(Error)
    }

    // Always succeeds so the vibed state sticks for the clip session.
    static func giveVibe(outfitId: String) async -> GiveResult {
        .success(remainingThisWeek: 3)
    }
}

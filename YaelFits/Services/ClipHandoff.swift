import Foundation

/// The clip → full-app handoff, carried through the shared App Group
/// container. The clip WRITES a record every time it loads a shared
/// fit; the full app READS it on first launch after an install that
/// came through the clip, so onboarding can:
///   - open with the recognition screen ("@x shared this fit with you")
///   - pre-check the "Follow @x" row
///   - personalize the invite gate with the creator
///   - attribute the install for funnel analytics
///
/// Compiled into BOTH the app and the App Clip targets.
struct ClipHandoff: Codable {
    let slug: String
    let outfitId: String
    let creatorUserId: String
    let creatorUsername: String
    let creatorAvatarURL: String?
    let invokedAt: Date
}

enum ClipHandoffStore {
    private static let suiteName = "group.com.yafa.Yafa"
    private static let key = "yafa.clipHandoff"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Latest-wins: each fit the clip loads overwrites the record, so
    /// the app resumes from whatever the viewer saw last.
    static func save(_ handoff: ClipHandoff) {
        guard let data = try? JSONEncoder().encode(handoff) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> ClipHandoff? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ClipHandoff.self, from: data)
    }

    /// Called by the app once the handoff has been consumed (or the
    /// user completes onboarding without it) so a stale record can't
    /// re-trigger the recognition flow.
    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}

/// The user's consent to follow the creator once they're in — set by
/// the pre-checked "Follow @x" row on the sign-up screen, consumed
/// after the gate + onboarding complete. Deliberately separate from
/// ClipHandoff: the handoff is what the CLIP saw; the intent is what
/// the USER agreed to.
enum ClipFollowIntent {
    private static let key = "yafa.pendingClipFollowCreatorId"

    static func set(creatorUserId: String) {
        UserDefaults.standard.set(creatorUserId, forKey: key)
    }

    static func creatorId() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// One-shot flag guaranteeing clip-installed users still land on the
/// Find Your People surface even though the pending follow makes
/// their following list non-empty — the creator follow must not
/// short-circuit discovery.
enum ClipDiscoveryPending {
    private static let key = "yafa.clipInstallDiscoveryPending"
    static func mark() { UserDefaults.standard.set(true, forKey: key) }
    static func isPending() -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

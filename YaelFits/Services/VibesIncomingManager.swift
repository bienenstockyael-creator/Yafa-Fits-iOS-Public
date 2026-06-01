import Foundation

/// Watches the vibes table for new vibes received by the
/// current user and surfaces them as in-app toasts.
///
/// Implementation: 30-second poll. Real-time push (via APNs or
/// Supabase Realtime) is the future direction; polling is the
/// pragmatic V1. The session anchors at app launch so the user
/// only sees toasts for vibes that arrive WHILE the app is
/// foregrounded — historical vibes stay quiet.
///
/// Lifecycle: call `start(for:)` when the user authenticates
/// (in `YaelFitsApp`'s `.task(id: authManager.userId)`). Call
/// `stop()` on sign-out.
@MainActor
@Observable
final class VibesIncomingManager {
    /// Most recently arrived vibe, if any. Toast UI watches
    /// this and slides in when it changes. Cleared to nil
    /// after the toast's dwell time so the next vibe can
    /// re-trigger the UI.
    var latest: IncomingVibe?

    /// Total received count at the start of the most recent
    /// poll cycle. Used to detect a 5-vibe milestone crossing
    /// so the UI can show a richer celebration toast.
    private(set) var previousTotal: Int = 0

    struct IncomingVibe: Identifiable {
        let id: UUID
        let outfitId: String
        let giver: Profile
        let receivedAt: Date
        /// True if THIS vibe's arrival pushed the user across
        /// a 5-vibe milestone (i.e., earned them a free 3D gen).
        let crossedMilestone: Bool
    }

    private static let pollInterval: TimeInterval = 30
    private var pollTask: Task<Void, Never>?
    private var sessionStart: Date = .distantPast
    private var lastSeenAt: Date = .distantPast

    func start(for userId: UUID) {
        stop()
        sessionStart = Date()
        lastSeenAt = sessionStart
        previousTotal = 0
        pollTask = Task { [weak self] in
            // Initial baseline: stamp the current received count
            // so milestone math doesn't fire for vibes that
            // arrived before this session.
            let initial = await VibesService.receivedCount(userId: userId)
            await MainActor.run { self?.previousTotal = initial }

            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pollInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                await self?.poll(for: userId)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        latest = nil
    }

    /// Manually clear the latest toast (e.g., after its
    /// dwell time expires or the user taps to dismiss).
    func dismissLatest() {
        latest = nil
    }

    private func poll(for userId: UUID) async {
        let since = lastSeenAt

        // Fetch new vibes since the last poll.
        struct VibeRow: Decodable {
            let id: UUID
            let giver_id: UUID
            let outfit_id: String
            let created_at: Date
        }
        let rows: [VibeRow]
        do {
            rows = try await supabase
                .from("vibes")
                .select("id, giver_id, outfit_id, created_at")
                .eq("receiver_id", value: userId.uuidString)
                .gt("created_at", value: ISO8601DateFormatter().string(from: since))
                .order("created_at", ascending: false)
                .limit(5)
                .execute()
                .value
        } catch {
            return
        }

        guard let mostRecent = rows.first else {
            // No new vibes — bump lastSeenAt so we don't
            // refetch the same empty window forever.
            lastSeenAt = Date()
            return
        }

        // Resolve the giver's profile for the toast UI.
        let giverProfile: Profile?
        do {
            let profiles = try await SocialService.getProfiles(
                userIds: Set([mostRecent.giver_id])
            )
            giverProfile = profiles.first
        } catch {
            giverProfile = nil
        }
        guard let giver = giverProfile else {
            lastSeenAt = mostRecent.created_at
            return
        }

        // Detect milestone crossing.
        let newTotal = await VibesService.receivedCount(userId: userId)
        let crossed = (previousTotal / 5) < (newTotal / 5)

        let vibe = IncomingVibe(
            id: mostRecent.id,
            outfitId: mostRecent.outfit_id,
            giver: giver,
            receivedAt: mostRecent.created_at,
            crossedMilestone: crossed
        )

        await MainActor.run {
            self.latest = vibe
            self.previousTotal = newTotal
        }
        lastSeenAt = mostRecent.created_at
    }
}

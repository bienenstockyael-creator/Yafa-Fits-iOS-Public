import Foundation

/// Which bucket a 3D credit came from, mirroring the
/// `generation_jobs.credit_source` enum on the server.
enum CreditSource: String, Sendable {
    case free
    case paid
    case pro
    case none
}

/// Wraps the Supabase RPCs that manage 3D generation credits.
///
/// Lifecycle: `reserve` debits a credit at job-submit time (before FAL
/// runs) so concurrent uploads can't double-spend the last credit.
/// `commit` confirms consumption when the user Accepts the result.
/// `release` refunds the credit on Reject / Cancel / pipeline failure.
///
/// All three are idempotent: re-reserve returns the existing source,
/// commit is a no-op (audit only), release no-ops once credit_source
/// has been cleared.
actor CreditService {
    static let shared = CreditService()

    private struct JobParams: Encodable {
        let p_job_id: String
    }

    func reserve(jobId: UUID) async throws -> CreditSource {
        let raw: String = try await supabase
            .rpc("reserve_3d_credit", params: JobParams(p_job_id: jobId.uuidString))
            .execute()
            .value
        return CreditSource(rawValue: raw) ?? .none
    }

    func commit(jobId: UUID) async throws {
        try await supabase
            .rpc("commit_3d_credit", params: JobParams(p_job_id: jobId.uuidString))
            .execute()
    }

    func release(jobId: UUID) async throws {
        try await supabase
            .rpc("release_3d_credit", params: JobParams(p_job_id: jobId.uuidString))
            .execute()
    }

    /// Current free + paid balances for a user, used by the
    /// profile settings page to surface "X gens left" without
    /// the user having to start a generation to find out.
    ///
    /// Calls `refresh_free_credits_if_due` first so a monthly
    /// reset that's "owed" gets applied before we read — that
    /// way the surfaced number is always current.
    struct Balance: Decodable, Sendable {
        let gen_credits_free_balance: Int
        let gen_credits_paid_balance: Int
    }

    func balance(userId: UUID) async throws -> Balance {
        struct UserParams: Encodable { let p_user_id: String }
        try? await supabase
            .rpc(
                "refresh_free_credits_if_due",
                params: UserParams(p_user_id: userId.uuidString)
            )
            .execute()
        let row: Balance = try await supabase
            .from("profiles")
            .select("gen_credits_free_balance, gen_credits_paid_balance")
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value
        return row
    }
}

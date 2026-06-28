import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

@Observable
class AuthManager {
    var session: Session?
    var isLoading = true
    var isResettingPassword = false
    private var currentNonce: String?

    var isAuthenticated: Bool { session != nil && !isResettingPassword }

    var userId: UUID? { session?.user.id }

    var userEmail: String? { session?.user.email }

    /// Whether the signed-in user authenticated with Sign in with Apple. Apple
    /// supplies the name via the Authentication Services framework, and ONLY on
    /// the very first authorization per Apple ID — so the app must never REQUIRE
    /// a SIWA user to type their name afterward (App Store Guideline 4.0.0).
    /// Onboarding uses this to skip the name step for these users.
    var isAppleUser: Bool {
        if let ids = session?.user.identities,
           ids.contains(where: { $0.provider == "apple" }) {
            return true
        }
        if case .string("apple")? = session?.user.appMetadata["provider"] {
            return true
        }
        return false
    }

    func initialize() async {
        do {
            session = try await supabase.auth.session
        } catch {
            session = nil
        }
        isLoading = false

        // Make sure the Share Extension has a usable session on every launch
        // (covers installs/updates where it was never provisioned).
        if session != nil {
            Task { await ExtensionSessionProvider.provisionIfMissing() }
        }

        for await (event, session) in supabase.auth.authStateChanges {
            guard [.signedIn, .signedOut, .tokenRefreshed].contains(event) else { continue }
            await MainActor.run {
                self.session = session
            }
            // Keep the Share Extension's dedicated session in step with login
            // state. (tokenRefreshed is a no-op — the extension self-refreshes.)
            switch event {
            case .signedIn:  Task { await ExtensionSessionProvider.provision() }
            case .signedOut: ExtensionSessionProvider.clear()
            default: break
            }
        }
    }

    // MARK: - Email Auth

    /// Signs the user up. Returns `true` when Supabase requires email
    /// confirmation (no session yet — caller should route to OTP
    /// verification). Returns `false` when the user is signed in
    /// immediately. Throws `AuthError.emailAlreadyRegistered` when the
    /// email belongs to an already-confirmed account so the caller can
    /// route to Sign In instead of triggering a no-op OTP.
    ///
    /// Supabase v2 deliberately obfuscates "email already registered"
    /// to prevent enumeration: `signUp` returns success with no session
    /// AND no error in *both* cases — new email AND existing confirmed
    /// email. The documented way to tell them apart is `user.identities`:
    /// new/unconfirmed users get a populated array, already-confirmed
    /// users get an empty array. We use that signal here.
    ///
    /// On a retry for an email with an unconfirmed `auth.users` row
    /// (first attempt landed in spam, user closed the app mid-flow),
    /// `signUp` also returns no session — but identities is populated.
    /// In that case we fire an explicit `resend(type: .signup)` so the
    /// user actually receives a code; `try?` so a transient resend
    /// rate-limit doesn't block them from reaching the verification view.
    func signUp(email: String, password: String) async throws -> Bool {
        do {
            let response = try await supabase.auth.signUp(email: email, password: password)
            if let session = response.session {
                await MainActor.run { self.session = session }
                await SocialService.ensureProfile(userId: session.user.id)
                return false
            }
            if (response.user.identities ?? []).isEmpty {
                throw AuthError.emailAlreadyRegistered
            }
            try? await supabase.auth.resend(email: email, type: .signup)
            return true
        } catch let error as AuthError {
            throw error
        } catch {
            // Older SDK path: signUp threw "User already registered"
            // instead of returning the obfuscated response. Map to the
            // same typed error so the UI handles both paths identically.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already") && (msg.contains("registered") || msg.contains("exists")) {
                throw AuthError.emailAlreadyRegistered
            }
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        await MainActor.run {
            self.session = session
        }
        await SocialService.ensureProfile(userId: session.user.id)
    }

    func sendOTP(email: String) async throws {
        try await supabase.auth.signInWithOTP(email: email)
    }

    func verifyOTP(email: String, otp: String) async throws {
        let response = try await supabase.auth.verifyOTP(email: email, token: otp, type: .magiclink)
        if let userId = response.session?.user.id {
            await SocialService.ensureProfile(userId: userId)
        }
    }

    func verifySignupOTP(email: String, otp: String) async throws {
        let response = try await supabase.auth.verifyOTP(email: email, token: otp, type: .signup)
        if let userId = response.session?.user.id {
            await SocialService.ensureProfile(userId: userId)
        }
    }

    func resendSignupOTP(email: String) async throws {
        try await supabase.auth.resend(email: email, type: .signup)
    }

    func updatePassword(_ newPassword: String) async throws {
        try await supabase.auth.update(user: .init(password: newPassword))
    }

    // MARK: - Apple Sign In

    func prepareAppleSignIn() -> String {
        let nonce = randomNonce()
        currentNonce = nonce
        return sha256(nonce)
    }

    /// Handles Sign in with Apple. Pass `expectingExistingUser: true` when
    /// invoked from the Sign In tab — if no profile exists for the just-
    /// authenticated Apple ID (i.e., Supabase had to freshly create the
    /// account), we sign back out and throw `noExistingAppleAccount` so
    /// the caller can prompt the user to sign up first / use email instead.
    /// This catches the duplicate-account trap where a user with an
    /// existing email/password account taps "Sign in with Apple" and
    /// accidentally creates a second account.
    func handleAppleSignIn(
        _ result: Result<ASAuthorization, Error>,
        expectingExistingUser: Bool = false
    ) async throws {
        let authorization = try result.get()

        guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = appleCredential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              let nonce = currentNonce else {
            throw AuthError.appleSignInFailed
        }

        let session = try await supabase.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: identityToken,
                nonce: nonce
            )
        )

        // Duplicate guard — only check when the user came from Sign In.
        // A returning Apple user has a profile row already; a freshly-
        // created account does not yet (we haven't called ensureProfile).
        if expectingExistingUser {
            let existing = try? await SocialService.getProfile(userId: session.user.id)
            if existing == nil {
                // Apple just created a brand-new auth.users entry. Reverse
                // it locally so the user isn't left signed in to a fresh
                // empty account, and tell the caller what happened.
                try? await supabase.auth.signOut()
                await MainActor.run {
                    self.session = nil
                    self.currentNonce = nil
                }
                throw AuthError.noExistingAppleAccount
            }
        }

        // Ensure profile row exists, pre-populate name from Apple if provided.
        // Email is passed through so the auto-username fallback works even
        // when Apple sends no name (which is the case for every sign-in
        // after the first).
        let fullName = appleCredential.fullName
        let displayName = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        await SocialService.ensureProfile(
            userId: session.user.id,
            displayName: displayName.isEmpty ? nil : displayName,
            email: session.user.email
        )
        // Apple sends the full name ONLY on the very first authorization, and
        // `ensureProfile` no-ops when the new-user DB trigger already created
        // the row — so the name it just handed us would be lost. Persist it
        // explicitly here, BEFORE publishing the session, so onboarding can
        // skip the name step using the name the Authentication Services
        // framework already provided rather than asking for it again
        // (App Store Guideline 4.0.0 — Sign in with Apple).
        if !displayName.isEmpty {
            try? await SocialService.updateDisplayName(
                userId: session.user.id,
                displayName: displayName
            )
        }
        await MainActor.run {
            self.session = session
            self.currentNonce = nil
        }
    }

    // MARK: - Sign Out

    func signOut() async throws {
        try await supabase.auth.signOut()
        await MainActor.run {
            self.session = nil
        }
    }

    // MARK: - Account Deletion

    /// Permanently deletes the signed-in user's account. Calls the
    /// `delete-user` Edge Function, which removes the auth user under
    /// the service role; ON DELETE CASCADE wipes all their content.
    /// On success the local session is cleared so the app returns to
    /// the sign-in screen.
    func deleteAccount() async throws {
        let url = SupabaseConfig.url
            .appendingPathComponent("functions/v1/delete-user")
        let jwt = try await supabase.auth.session.accessToken

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw AuthError.accountDeletionFailed(body)
        }

        // Account is gone server-side — clear the local session. The
        // server already revoked it, so signOut may no-op/throw; ignore.
        try? await supabase.auth.signOut()
        await MainActor.run {
            self.session = nil
        }
    }

    // MARK: - Helpers

    private func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                precondition(status == errSecSuccess)
                return random
            }
            for random in randoms {
                guard remainingLength > 0 else { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum AuthError: LocalizedError {
    case appleSignInFailed
    case emailAlreadyRegistered
    case noExistingAppleAccount
    case accountDeletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleSignInFailed:
            return "Apple Sign In failed. Please try again."
        case .emailAlreadyRegistered:
            return "This email is already registered. Sign in below."
        case .noExistingAppleAccount:
            return "No existing account found with this Apple ID. Tap Sign Up to create one, or sign in with your email and password."
        case .accountDeletionFailed:
            return "We couldn't delete your account. Please try again, or contact support if the problem continues."
        }
    }
}

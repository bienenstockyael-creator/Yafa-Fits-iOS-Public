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

    func initialize() async {
        do {
            session = try await supabase.auth.session
        } catch {
            session = nil
        }
        isLoading = false

        for await (event, session) in supabase.auth.authStateChanges {
            guard [.signedIn, .signedOut, .tokenRefreshed].contains(event) else { continue }
            await MainActor.run {
                self.session = session
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

    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async throws {
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

        await MainActor.run {
            self.session = session
            self.currentNonce = nil
        }
        // Ensure profile row exists, pre-populate name from Apple if provided
        let fullName = appleCredential.fullName
        let displayName = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        await SocialService.ensureProfile(
            userId: session.user.id,
            displayName: displayName.isEmpty ? nil : displayName
        )
    }

    // MARK: - Sign Out

    func signOut() async throws {
        try await supabase.auth.signOut()
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

    var errorDescription: String? {
        switch self {
        case .appleSignInFailed:
            return "Apple Sign In failed. Please try again."
        case .emailAlreadyRegistered:
            return "This email is already registered. Sign in below."
        }
    }
}

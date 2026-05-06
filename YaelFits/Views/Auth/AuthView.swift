import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @Environment(AuthManager.self) private var auth

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showPasswordReset = false
    @State private var showSignupVerification = false

    var body: some View {
        ZStack {
            AppPalette.pageBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)

                    logoSection

                    Color.clear.frame(height: LayoutMetrics.xLarge)

                    if showPasswordReset {
                        PasswordResetView(email: email) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPasswordReset = false
                            }
                        }
                    } else if showSignupVerification {
                        SignupVerificationView(email: email) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSignupVerification = false
                            }
                        }
                    } else {
                        modePicker
                        Color.clear.frame(height: LayoutMetrics.large)
                        formSection
                        Color.clear.frame(height: LayoutMetrics.medium)
                        divider
                        Color.clear.frame(height: LayoutMetrics.medium)
                        appleSignInButton
                        forgotPasswordLink
                    }

                    Color.clear.frame(height: LayoutMetrics.xLarge)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding + 8)
            }
        }
    }

    // MARK: - Logo

    private var logoSection: some View {
        VStack(spacing: LayoutMetrics.small) {
            Group {
                if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
                   let data = try? Data(contentsOf: logoURL),
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 48)
                        .colorMultiply(.black)
                        .opacity(0.82)
                } else {
                    Text("YAFA")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(AppPalette.textPrimary.opacity(0.82))
                }
            }

            if let subtitle = headerSubtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
            }
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(spacing: LayoutMetrics.small) {
            TextField("", text: $email, prompt: Text("Email").foregroundStyle(AppPalette.textFaint))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            SecureField("", text: $password, prompt: Text("Password").foregroundStyle(AppPalette.textFaint))
                .textContentType(isSignUp ? .newPassword : .password)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }

            Button(action: submitEmail) {
                Group {
                    if isSubmitting {
                        ProgressView().tint(AppPalette.textMuted)
                    } else {
                        Text(isSignUp ? "SIGN UP" : "SIGN IN")
                            .font(.system(size: submitActive ? 12 : 11, weight: submitActive ? .semibold : .medium))
                            .tracking(1.8)
                            .foregroundStyle(submitActive ? AppPalette.textPrimary : AppPalette.textFaint)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .appCapsule(shadowRadius: submitActive ? 8 : 0, shadowY: submitActive ? 4 : 0)
                .animation(.easeInOut(duration: 0.2), value: submitActive)
            }
            .disabled(isSubmitting || !submitActive)
            .buttonStyle(.plain)
            .padding(.top, LayoutMetrics.xSmall)
        }
    }

    // MARK: - Forgot password

    private var forgotPasswordLink: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showPasswordReset = true
                errorMessage = nil
            }
        } label: {
            Text("Forgot password?")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
        }
        .buttonStyle(.plain)
        .padding(.top, LayoutMetrics.medium)
        .opacity(isSignUp ? 0 : 1)
        .allowsHitTesting(!isSignUp)
    }

    // MARK: - Apple Sign In

    private var appleSignInButton: some View {
        SignInWithAppleButton(isSignUp ? .signUp : .signIn) { request in
            let nonce = auth.prepareAppleSignIn()
            request.requestedScopes = [.email, .fullName]
            request.nonce = nonce
        } onCompletion: { result in
            isSubmitting = true
            errorMessage = nil
            Task {
                do {
                    try await auth.handleAppleSignIn(result)
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isSubmitting = false
                    }
                }
            }
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .cornerRadius(25)
    }

    // MARK: - Mode picker (Sign In / Sign Up)

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { signUp in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSignUp = signUp
                        showPasswordReset = false
                        errorMessage = nil
                    }
                } label: {
                    Text(signUp ? "Sign Up" : "Sign In")
                        .font(.system(size: 13, weight: isSignUp == signUp ? .semibold : .regular))
                        .foregroundStyle(isSignUp == signUp ? AppPalette.textPrimary : AppPalette.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            isSignUp == signUp
                                ? AppPalette.groupedBackground
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppPalette.cardBorder.opacity(0.5), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - Divider

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(AppPalette.cardBorder).frame(height: 0.5)
            Text("OR")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textFaint)
            Rectangle().fill(AppPalette.cardBorder).frame(height: 0.5)
        }
    }

    // MARK: - Actions

    private func submitEmail() {
        guard !email.isEmpty, !password.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                if isSignUp {
                    let needsVerification = try await auth.signUp(email: email, password: password)
                    await MainActor.run {
                        isSubmitting = false
                        if needsVerification {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSignupVerification = true
                            }
                        }
                    }
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch AuthError.emailAlreadyRegistered {
                // Flip the form to Sign In with email pre-filled so the
                // user can continue without retyping. Preserves password
                // too in case it's the right one.
                await MainActor.run {
                    isSubmitting = false
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSignUp = false
                    }
                    errorMessage = AuthError.emailAlreadyRegistered.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private var submitActive: Bool {
        !email.isEmpty && !password.isEmpty
    }

    private var headerSubtitle: String? {
        if showPasswordReset { return "Reset your password" }
        if showSignupVerification { return nil }
        return isSignUp ? "Create your account" : "Welcome back"
    }
}

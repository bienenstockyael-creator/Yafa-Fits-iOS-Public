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
    @State private var isPasswordVisible = false

    #if DEBUG
    /// Mirrors the AppStorage flag YaelFitsApp uses to gate the welcome
    /// tour. Setting it to false causes YaelFitsApp to switch back to
    /// the tour view (no rebuild, no reinstall needed).
    #endif

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
                        if !isSignUp {
                            // Only on the Sign In tab — nudge users with an
                            // existing email account away from accidentally
                            // creating a second account via Apple.
                            Text("If you already have an email account, sign in above.")
                                .font(.system(size: 11))
                                .foregroundStyle(AppPalette.textFaint)
                                .multilineTextAlignment(.center)
                                .padding(.top, LayoutMetrics.xSmall)
                                .padding(.horizontal, LayoutMetrics.medium)
                        }
                        forgotPasswordLink
                        agreementFooter
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

            ZStack(alignment: .trailing) {
                Group {
                    if isPasswordVisible {
                        TextField("", text: $password, prompt: Text("Password").foregroundStyle(AppPalette.textFaint))
                            .textContentType(isSignUp ? .newPassword : .password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("", text: $password, prompt: Text("Password").foregroundStyle(AppPalette.textFaint))
                            .textContentType(isSignUp ? .newPassword : .password)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .padding(.trailing, password.isEmpty ? 16 : 44)  // room for eye when filled
                .frame(height: 50)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

                // Eye icon — only shown when there's something to reveal.
                if !password.isEmpty {
                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(AppPalette.textMuted)
                            .frame(width: 44, height: 50)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: password.isEmpty)

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
                        ProgressView().tint(submitActive ? .white : AppPalette.textMuted)
                    } else {
                        Text(isSignUp ? "SIGN UP" : "SIGN IN")
                            .font(.system(size: submitActive ? 12 : 11, weight: submitActive ? .semibold : .medium))
                            .tracking(1.8)
                            .foregroundStyle(submitActive ? Color.white : AppPalette.textFaint)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Group {
                        if submitActive {
                            Capsule(style: .continuous).fill(Color.black)
                        } else {
                            Color.clear
                        }
                    }
                )
                // Fall back to the standard glass capsule when inactive
                // so the unfilled state still has the same chrome as
                // every other button in the auth flow.
                .appCapsule(shadowRadius: submitActive ? 8 : 0, shadowY: submitActive ? 4 : 0)
                .animation(.easeInOut(duration: 0.2), value: submitActive)
            }
            .disabled(isSubmitting || !submitActive)
            .buttonStyle(SolidPressButtonStyle())
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
        .buttonStyle(SolidPressButtonStyle())
        .padding(.top, LayoutMetrics.medium)
        .opacity(isSignUp ? 0 : 1)
        .allowsHitTesting(!isSignUp)
    }

    // MARK: - Apple Sign In

    /// Terms/Privacy agreement shown under the auth controls. Required
    /// for a UGC app (App Store Guideline 1.2) — by continuing, the user
    /// agrees to the Terms (Apple's standard EULA) and Privacy Policy.
    private var agreementFooter: some View {
        VStack(spacing: 3) {
            Text("By continuing, you agree to our")
                .foregroundStyle(AppPalette.textFaint)
            HStack(spacing: 4) {
                if let terms = URL(string: AppConfig.termsOfServiceURL) {
                    Link("Terms of Service", destination: terms)
                        .foregroundStyle(AppPalette.textMuted)
                }
                Text("and").foregroundStyle(AppPalette.textFaint)
                if let privacy = URL(string: AppConfig.privacyPolicyURL) {
                    Link("Privacy Policy", destination: privacy)
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
        }
        .font(.system(size: 11))
        .multilineTextAlignment(.center)
        .padding(.top, LayoutMetrics.large)
        .padding(.horizontal, LayoutMetrics.medium)
    }

    private var appleSignInButton: some View {
        SignInWithAppleButton(isSignUp ? .signUp : .signIn) { request in
            let nonce = auth.prepareAppleSignIn()
            request.requestedScopes = [.email, .fullName]
            request.nonce = nonce
        } onCompletion: { result in
            isSubmitting = true
            errorMessage = nil
            // Tell the AuthManager which tab we came from. On Sign In,
            // it will reject a fresh Apple account creation (duplicate
            // guard) and show an error instead of creating an orphan.
            let expectingExistingUser = !isSignUp
            Task {
                do {
                    try await auth.handleAppleSignIn(result, expectingExistingUser: expectingExistingUser)
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
                .buttonStyle(SolidPressButtonStyle())
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

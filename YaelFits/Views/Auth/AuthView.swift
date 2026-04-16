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

    var body: some View {
        ZStack {
            AppPalette.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                logoSection

                Spacer().frame(height: 24)

                if !showPasswordReset {
                    modePicker
                    Spacer().frame(height: 24)
                } else {
                    Spacer().frame(height: 40)
                }

                if showPasswordReset {
                    PasswordResetView(email: email) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPasswordReset = false
                        }
                    }
                } else {
                    formSection

                    Spacer().frame(height: 20)

                    divider

                    Spacer().frame(height: 20)

                    appleSignInButton

                    if !isSignUp {
                        forgotPasswordLink
                    }
                }

                Spacer()
            }
            .padding(.horizontal, LayoutMetrics.screenPadding + 8)
        }
    }

    // MARK: - Logo

    private var logoSection: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
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

            Text(showPasswordReset ? "Reset your password" : (isSignUp ? "Create your account" : "Welcome back"))
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textMuted)
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            TextField("", text: $email, prompt: Text("Email").foregroundStyle(AppPalette.textFaint))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            SecureField("", text: $password, prompt: Text("Password").foregroundStyle(AppPalette.textFaint))
                .textContentType(isSignUp ? .newPassword : .password)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }

            Button {
                submitEmail()
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().tint(AppPalette.textMuted)
                    } else {
                        Text(isSignUp ? "SIGN UP" : "SIGN IN")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.8)
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .appCapsule(shadowRadius: 8, shadowY: 4)
            }
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.45 : 1)
            .buttonStyle(.plain)
            .padding(.top, 4)
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
        .padding(.top, 8)
    }

    // MARK: - Apple Sign In

    private var appleSignInButton: some View {
        SignInWithAppleButton(.signIn) { request in
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
        .frame(height: 48)
        .cornerRadius(24)
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

    // MARK: - Divider & toggle

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

    private var toggleSection: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSignUp.toggle()
                showPasswordReset = false
                errorMessage = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text(isSignUp ? "Already have an account?" : "Don't have an account?")
                    .foregroundStyle(AppPalette.textMuted)
                Text(isSignUp ? "Sign in" : "Sign up")
                    .foregroundStyle(AppPalette.textPrimary)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func submitEmail() {
        guard !email.isEmpty, !password.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                if isSignUp {
                    try await auth.signUp(email: email, password: password)
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

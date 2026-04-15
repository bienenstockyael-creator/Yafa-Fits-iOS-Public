import SwiftUI

struct PasswordResetView: View {
    @Environment(AuthManager.self) private var auth
    let email: String
    let onBack: () -> Void

    enum Step { case enterEmail, enterCode, setPassword }

    @State private var editableEmail: String
    @State private var step: Step = .enterEmail
    @State private var otpCode = ""
    @State private var newPassword = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(email: String, onBack: @escaping () -> Void) {
        self.email = email
        self.onBack = onBack
        self._editableEmail = State(initialValue: email)
    }

    var body: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            switch step {
            case .enterEmail:
                emailStep
            case .enterCode:
                codeStep
            case .setPassword:
                passwordStep
            }
        }
    }

    // MARK: - Steps

    private var emailStep: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            inputField(text: $editableEmail, prompt: "Email", keyboard: .emailAddress)
            messageRow
            submitButton(label: "SEND CODE", disabled: editableEmail.isEmpty) {
                sendCode()
            }
            backButton
        }
    }

    private var codeStep: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            Text("Enter the 6-digit code sent to \(editableEmail)")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("", text: $otpCode, prompt: Text("000000").foregroundStyle(AppPalette.textFaint))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            messageRow
            submitButton(label: "VERIFY", disabled: otpCode.count < 6) {
                verifyCode()
            }
            backButton
        }
    }

    private var passwordStep: some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            SecureField("", text: $newPassword, prompt: Text("New password").foregroundStyle(AppPalette.textFaint))
                .textContentType(.newPassword)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            messageRow
            submitButton(label: "SET PASSWORD", disabled: newPassword.count < 6) {
                setPassword()
            }
        }
    }

    // MARK: - Shared components

    private func inputField(text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(AppPalette.textFaint))
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textStrong)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)
    }

    private func submitButton(label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSubmitting {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .appCapsule(shadowRadius: 8, shadowY: 4)
        }
        .disabled(isSubmitting || disabled)
        .opacity(disabled ? 0.45 : 1)
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var messageRow: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }

    private var backButton: some View {
        Button {
            auth.isResettingPassword = false
            onBack()
        } label: {
            Text("Back to sign in")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func sendCode() {
        errorMessage = nil
        isSubmitting = true
        auth.isResettingPassword = true

        Task {
            do {
                try await auth.sendOTP(email: editableEmail)
                await MainActor.run {
                    isSubmitting = false
                    withAnimation(.easeInOut(duration: 0.2)) { step = .enterCode }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func verifyCode() {
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await auth.verifyOTP(email: editableEmail, otp: otpCode)
                await MainActor.run {
                    isSubmitting = false
                    withAnimation(.easeInOut(duration: 0.2)) { step = .setPassword }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func setPassword() {
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await auth.updatePassword(newPassword)
                await MainActor.run {
                    auth.isResettingPassword = false
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

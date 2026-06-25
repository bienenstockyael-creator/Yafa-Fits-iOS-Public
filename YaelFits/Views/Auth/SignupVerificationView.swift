import SwiftUI

struct SignupVerificationView: View {
    @Environment(AuthManager.self) private var auth
    let email: String
    let onBack: () -> Void

    @State private var otpCode = ""
    @State private var isSubmitting = false
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        VStack(spacing: LayoutMetrics.medium) {
            Text("Enter the 6-digit code sent to\n\(email)")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LayoutMetrics.small)

            TextField("", text: $otpCode, prompt: Text("000000").foregroundStyle(AppPalette.textFaint))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .tracking(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppPalette.textStrong)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)

            messageRow

            submitButton

            HStack(spacing: 0) {
                secondaryButton(label: "RESEND CODE", busy: isResending, action: resendCode)
                    .disabled(isResending)
                Spacer()
                secondaryButton(label: "BACK", busy: false, action: onBack)
            }
            .padding(.top, LayoutMetrics.small)
        }
    }

    @ViewBuilder
    private var messageRow: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else if let infoMessage {
            Text(infoMessage)
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private var submitButton: some View {
        let active = otpCode.count >= 6
        return Button(action: verifyCode) {
            Group {
                if isSubmitting {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("VERIFY")
                        .font(.system(size: active ? 12 : 11, weight: active ? .semibold : .medium))
                        .tracking(1.8)
                        .foregroundStyle(active ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .appCapsule(shadowRadius: active ? 8 : 0, shadowY: active ? 4 : 0)
            .animation(.easeInOut(duration: 0.2), value: active)
        }
        .disabled(isSubmitting || !active)
        .buttonStyle(SolidPressButtonStyle())
        .padding(.top, LayoutMetrics.xxSmall)
    }

    private func secondaryButton(label: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(AppPalette.textMuted).controlSize(.small)
                } else {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(AppPalette.cardBorder.opacity(0.5), in: Capsule())
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func verifyCode() {
        errorMessage = nil
        infoMessage = nil
        isSubmitting = true

        Task {
            do {
                try await auth.verifySignupOTP(email: email, otp: otpCode)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func resendCode() {
        errorMessage = nil
        infoMessage = nil
        isResending = true

        Task {
            do {
                try await auth.resendSignupOTP(email: email)
                await MainActor.run {
                    infoMessage = "New code sent to \(email)"
                    isResending = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isResending = false
                }
            }
        }
    }
}

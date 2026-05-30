import SwiftUI

/// In-context phone-collection sheet shown after the user grants
/// contact access — but only if their profile has no phone yet.
/// Pattern matches what Instagram/TikTok/Snapchat do: don't add
/// phone friction to sign-up, ask in the one place where the
/// feature actually needs it.
///
/// Submitting writes the SHA-256 hash of their normalized phone
/// to their profile so friends matching contacts can find them
/// in reverse. Skip leaves them able to find others but not be
/// found.
///
/// Styled to match the rest of the app's sheets:
///   - `presentationBackground(AppPalette.groupedBackground)`
///     (set by the caller — sheet modifiers can't be inside the
///     content view).
///   - Light color scheme forced so the dark text palette stays
///     readable even when the user has Dark Mode on.
///   - Text field uses the same `appCard` chrome + textFaint
///     placeholder pattern as the auth form.
struct PhoneCapturePromptView: View {
    let onSubmit: (String) async -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phoneInput: String = ""
    @State private var isSubmitting = false
    @FocusState private var phoneFocused: Bool

    private var canSubmit: Bool {
        !isSubmitting && PhoneNumber.normalizeToE164(phoneInput) != nil
    }

    var body: some View {
        VStack(spacing: LayoutMetrics.medium) {
            VStack(spacing: LayoutMetrics.xxSmall) {
                Text("Be findable")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text("Add your phone number so friends with you in their contacts can find you on Yafa too.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, LayoutMetrics.large)
            .padding(.horizontal, LayoutMetrics.large)

            TextField(
                "",
                text: $phoneInput,
                prompt: Text("Phone number")
                    .foregroundStyle(AppPalette.textFaint)
            )
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .focused($phoneFocused)
            .font(.system(size: 16))
            .foregroundStyle(AppPalette.textStrong)
            .padding(.horizontal, LayoutMetrics.small)
            .frame(height: 52)
            .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)
            .padding(.horizontal, LayoutMetrics.large)

            Button(action: submit) {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Save")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    Capsule().fill(
                        canSubmit
                            ? AppPalette.textStrong
                            : AppPalette.textStrong.opacity(0.35)
                    )
                )
            }
            .disabled(!canSubmit)
            .padding(.horizontal, LayoutMetrics.large)

            Button("Not now") {
                onSkip()
                dismiss()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(AppPalette.textPrimary)
            .padding(.bottom, LayoutMetrics.large)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPalette.groupedBackground)
        .preferredColorScheme(.light)
        .onAppear { phoneFocused = true }
    }

    private func submit() {
        guard let e164 = PhoneNumber.normalizeToE164(phoneInput) else { return }
        isSubmitting = true
        Task {
            await onSubmit(e164)
            await MainActor.run {
                isSubmitting = false
                dismiss()
            }
        }
    }
}

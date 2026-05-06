import SwiftUI

/// Full-screen onboarding flow shown after signup. Multi-step container —
/// currently only profile setup, but designed so future steps (avatar,
/// notifications, intro) can slot in by extending `Step`.
struct OnboardingView: View {
    let userId: UUID
    var existingDisplayName: String?
    var onComplete: () -> Void

    enum Step { case profile }

    @State private var step: Step = .profile

    var body: some View {
        ZStack {
            AppPalette.pageBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)

                    logoSection

                    Color.clear.frame(height: LayoutMetrics.xLarge)

                    switch step {
                    case .profile:
                        ProfileStep(
                            userId: userId,
                            existingDisplayName: existingDisplayName,
                            onComplete: onComplete
                        )
                    }

                    Color.clear.frame(height: LayoutMetrics.xLarge)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding + 8)
            }
        }
    }

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

            Text(stepSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textMuted)
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .profile: return "Set up your profile"
        }
    }
}

// MARK: - Profile step

private struct ProfileStep: View {
    let userId: UUID
    var existingDisplayName: String?
    var onComplete: () -> Void

    @State private var displayName = ""
    @State private var username = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field { case displayName, username }

    var body: some View {
        VStack(spacing: LayoutMetrics.small) {
            field(
                placeholder: "Display name",
                text: $displayName,
                capitalization: .words,
                focus: .displayName,
                nextFocus: .username
            )

            field(
                placeholder: "Username",
                text: $username,
                capitalization: .never,
                focus: .username,
                nextFocus: nil
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }

            submitButton
                .padding(.top, LayoutMetrics.xSmall)
        }
        .onAppear {
            if let existing = existingDisplayName, !existing.isEmpty, displayName.isEmpty {
                displayName = existing
            }
        }
        .onChange(of: username) { _, newValue in
            let sanitized = Profile.sanitizeUsername(newValue)
            if sanitized != newValue { username = sanitized }
        }
    }

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var submitButton: some View {
        Button(action: save) {
            Group {
                if isSaving {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("CONTINUE")
                        .font(.system(size: canSubmit ? 12 : 11, weight: canSubmit ? .semibold : .medium))
                        .tracking(1.8)
                        .foregroundStyle(canSubmit ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .appCapsule(shadowRadius: canSubmit ? 8 : 0, shadowY: canSubmit ? 4 : 0)
            .animation(.easeInOut(duration: 0.2), value: canSubmit)
        }
        .disabled(!canSubmit || isSaving)
        .buttonStyle(.plain)
    }

    private func save() {
        focusedField = nil
        errorMessage = nil
        isSaving = true

        Task {
            var profile = Profile(id: userId)
            profile.displayName = displayName.trimmingCharacters(in: .whitespaces)
            let sanitized = Profile.sanitizeUsername(username)
            profile.username = sanitized.isEmpty ? nil : sanitized

            do {
                try await SocialService.updateProfile(profile)
                await MainActor.run { onComplete() }
            } catch {
                await MainActor.run {
                    let msg = error.localizedDescription
                    errorMessage = msg.contains("duplicate") || msg.contains("unique")
                        ? "That username is already taken. Try another."
                        : msg
                    isSaving = false
                }
            }
        }
    }

    private func field(
        placeholder: String,
        text: Binding<String>,
        capitalization: TextInputAutocapitalization,
        focus: Field,
        nextFocus: Field?
    ) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(AppPalette.textFaint))
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textStrong)
            .autocorrectionDisabled()
            .textInputAutocapitalization(capitalization)
            .focused($focusedField, equals: focus)
            .submitLabel(nextFocus == nil ? .done : .next)
            .onSubmit {
                if let next = nextFocus { focusedField = next }
                else { focusedField = nil }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .appCard(cornerRadius: 14, shadowRadius: 6, shadowY: 3)
    }
}

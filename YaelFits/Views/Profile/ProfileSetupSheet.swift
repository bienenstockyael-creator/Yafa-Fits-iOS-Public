import SwiftUI

/// Shown to new users who haven't set a display name yet.
struct ProfileSetupSheet: View {
    let userId: UUID
    var existingDisplayName: String?
    var onComplete: () -> Void

    @State private var displayName = ""
    @State private var username = ""
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focusedField: Field?

    enum Field { case displayName, username }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.large) {
                    VStack(spacing: LayoutMetrics.xSmall) {
                        Text("Welcome to Yafa")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppPalette.textStrong)
                        Text("Set up your profile to get started.")
                            .font(.system(size: 14))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .padding(.top, LayoutMetrics.xLarge)

                    VStack(spacing: LayoutMetrics.medium) {
                        field(label: "DISPLAY NAME",
                              text: $displayName,
                              placeholder: "e.g. Yael",
                              capitalization: .words,
                              focus: .displayName,
                              nextFocus: .username)

                        field(label: "USERNAME",
                              text: $username,
                              placeholder: "e.g. yaelfits",
                              capitalization: .never,
                              focus: .username,
                              nextFocus: nil)

                        if let error {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }

                    Button {
                        focusedField = nil
                        Task { await save() }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(AppPalette.textMuted)
                            } else {
                                Text("LET'S GO")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .tracking(2)
                                    .foregroundStyle(canSave ? AppPalette.textPrimary : AppPalette.textFaint)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .appCapsule(shadowRadius: 8, shadowY: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave || isSaving)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.xLarge)
            }
            .background(AppPalette.pageBackground)
            .navigationBarHidden(true)
            .onTapGesture { focusedField = nil }
        }
        .interactiveDismissDisabled()
        .onChange(of: username) { _, newValue in
            let sanitized = Profile.sanitizeUsername(newValue)
            if sanitized != newValue { username = sanitized }
        }
        .onAppear {
            if let existing = existingDisplayName, !existing.isEmpty, displayName.isEmpty {
                displayName = existing
            }
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        isSaving = true
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
                self.error = msg.contains("duplicate") || msg.contains("unique")
                    ? "That username is already taken. Try another."
                    : msg
                isSaving = false
            }
        }
    }

    private func field(label: String, text: Binding<String>,
                       placeholder: String,
                       capitalization: TextInputAutocapitalization,
                       focus: Field,
                       nextFocus: Field?) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
            TextField("", text: text, prompt:
                Text(placeholder).foregroundColor(AppPalette.textSecondary)
            )
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(capitalization)
            .focused($focusedField, equals: focus)
            .submitLabel(nextFocus == nil ? .done : .next)
            .onSubmit {
                if let next = nextFocus { focusedField = next }
                else { focusedField = nil }
            }
            .padding(.horizontal, LayoutMetrics.xSmall)
            .frame(height: 48)
            .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        }
    }
}

import PhotosUI
import SwiftUI

/// First-launch setup walkthrough. Presented as a full-screen
/// cover from `RootView` whenever the signed-in user's profile
/// has `isOnboarded == false`. Walks through four steps:
///
///   1. Display name (required)
///   2. Username (required, uniqueness-checked)
///   3. Photo + header style (optional)
///   4. Phone number (optional)
///
/// On Finish (whether all fields filled or last two skipped),
/// writes `is_onboarded = true` on the server and dismisses.
/// On the way through, each step saves its own field to the
/// server as the user advances — so a crash mid-flow doesn't
/// lose the username they already picked.
///
/// Visual language matches the app's existing sheet family
/// (`ShareCardComposer`, `ProfileHeaderCustomizeSheet`): caps
/// monospaced title, capsule primary button, soft chrome.
struct OnboardingFlow: View {
    @Environment(OutfitStore.self) private var store
    @Environment(AuthManager.self) private var auth

    /// Called once the server confirms `is_onboarded = true`.
    /// Parent (RootView) uses this to dismiss the full-screen
    /// cover and let the rest of the app render.
    let onFinish: () -> Void

    @State private var currentStep: Step = .name

    // Per-step field state, declared at flow scope so values
    // survive back/forward navigation between steps.
    @State private var displayName: String = ""
    @State private var username: String = ""
    @State private var phone: String = ""

    // Photo + style state. Photo gets uploaded via the existing
    // AvatarService at crop-confirm time; style is committed on
    // step-3 Continue.
    @State private var pendingAvatarImage: UIImage?
    @State private var pendingOriginalImage: UIImage?
    @State private var pendingHeaderStyle: ProfileHeaderStyle = .minimal
    @State private var pendingAccentHex: String = ProfileHeaderAccentColor.defaultHex
    /// Background-removed cutout PNG for the bust preview.
    /// Generated on demand when the user lands on the bust card
    /// in the style carousel. Same `FalBackgroundRemovalService`
    /// path the customize sheet uses.
    @State private var pendingCutoutImage: UIImage?
    @State private var isProcessingCutout = false

    // Photo picker + cropper plumbing (same pattern as
    // ProfileHeader / ProfileHeaderCustomizeSheet).
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingCropImage: IdentifiableImage?

    // Username uniqueness state. Debounced — fires ~400ms after
    // typing stops to avoid hammering the server on every keystroke.
    @State private var usernameAvailable: Bool? = nil
    @State private var usernameCheckTask: Task<Void, Never>?

    // Per-step "saving" guard so the user can't double-tap
    // Continue mid-network and end up with two parallel writes.
    @State private var isAdvancing = false

    /// Drives the text field's keyboard + cursor blink. Set
    /// true when a text-input step appears so the cursor shows
    /// from the start (rather than the user needing to tap the
    /// prompt to bring up the keyboard).
    @FocusState private var isInputFocused: Bool

    enum Step: Int, CaseIterable {
        case name, username, photo, phone

        /// Required steps have no "Skip" button — the user must
        /// fill the field to proceed. Optional steps get Skip.
        var isSkippable: Bool {
            switch self {
            case .name, .username: return false
            case .photo, .phone:   return true
            }
        }
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)

                Spacer(minLength: 0)

                // Photo step gets its own layout (mirrors the
                // existing ProfileHeaderCustomizeSheet body —
                // style title + carousel + page dots + color
                // picker). The text-input steps stay with the
                // viewport-centered prompt pattern.
                if currentStep == .photo {
                    stepContent
                } else {
                    // Layered so the PROMPT centers exactly on
                    // the viewport (not the welcome+prompt
                    // combined center). Welcome floats 50pt
                    // above center.
                    ZStack {
                        stepContent
                            .padding(.horizontal, LayoutMetrics.screenPadding)

                        Text("WELCOME TO YAFA")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textFaint)
                            .offset(y: -50)
                    }
                }

                Spacer(minLength: 0)

                primaryButton
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
            }
        }
        .onAppear {
            prefillFromExistingProfile()
            // Focus the input so the keyboard + cursor show
            // immediately. Step 3 (photo) doesn't need focus,
            // but the FocusState binding has no effect there.
            isInputFocused = currentStep != .photo
        }
        .onChange(of: currentStep) { _, newValue in
            // Re-focus on every text step transition. The
            // .photo step deliberately blurs to dismiss the
            // keyboard, since there's no text input there.
            isInputFocused = newValue != .photo
        }
        .onChange(of: pendingHeaderStyle) { _, newValue in
            // User landed on bust in the carousel — kick off
            // FAL bg-removal so the preview shows the actual
            // cutout instead of the circle-clipped fallback.
            // No-op if we've already processed it this session
            // OR if there's no photo yet (which also means no
            // bust card visible).
            if newValue == .bust { Task { await ensureCutoutAvailable() } }
        }
        // Clamp Dynamic Type — the inline 24pt prompt + the
        // 360pt carousel both fit comfortably on every iPhone
        // at default text size, but accessibility-tier text
        // would overflow either the prompt's centering or the
        // carousel's preview cards. Capping at .accessibility1
        // (~150% scale) gives users a real bump for legibility
        // without breaking the fixed layout.
        .dynamicTypeSize(.large ... .accessibility1)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    pendingCropImage = IdentifiableImage(image: image)
                }
            }
        }
        .fullScreenCover(item: $pendingCropImage) { wrapper in
            AvatarCropView(image: wrapper.image) { cropped in
                pendingCropImage = nil
                selectedPhoto = nil
                pendingAvatarImage = cropped
                pendingOriginalImage = wrapper.image
                // New photo invalidates the prior cutout — the
                // background-removed silhouette was derived from
                // the OLD pixels and would composite incorrectly
                // on the new ones. If user is currently on bust,
                // re-trigger the FAL call.
                pendingCutoutImage = nil
                if pendingHeaderStyle == .bust {
                    Task { await ensureCutoutAvailable() }
                }
                // Upload happens at step-3 Continue, not here —
                // user might still pick a different photo before
                // advancing, no point spending bandwidth on
                // intermediate picks.
            } onCancel: {
                pendingCropImage = nil
                selectedPhoto = nil
            }
        }
        .onChange(of: username) { _, _ in
            scheduleUsernameCheck()
        }
    }

    // MARK: - Header (back / title / skip)

    /// Minimal top bar — just back (left) and skip (right).
    /// The "WELCOME TO YAFA" label moved into the centered
    /// content stack so the title lives next to the question
    /// it's introducing rather than floating at the top.
    private var header: some View {
        HStack {
            if currentStep != .name {
                Button { goBack() } label: {
                    AppIcon(glyph: .chevronLeft, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            Spacer()

            if currentStep.isSkippable {
                Button { Task { await advance(skipping: true) } } label: {
                    Text("SKIP")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 50, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isAdvancing)
            } else {
                Color.clear.frame(width: 50, height: 36)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .name:     nameStep
        case .username: usernameStep
        case .photo:    photoStep
        case .phone:    phoneStep
        }
    }

    private var nameStep: some View {
        inlinePrompt(
            question: "What's your full name?",
            text: $displayName,
            contentType: .name,
            autocaps: .words
        )
    }

    private var usernameStep: some View {
        VStack(spacing: LayoutMetrics.small) {
            inlinePrompt(
                question: "Pick a @handle",
                text: $username,
                contentType: .username,
                autocaps: .never
            )
            .onChange(of: username) { _, new in
                // Live sanitize: lowercase + strip disallowed
                // chars as the user types so they can't end up
                // with an invalid handle in the field.
                let cleaned = sanitizeUsername(new)
                if cleaned != new {
                    username = cleaned
                }
            }

            // Availability hint sits just under the prompt.
            // Reserved height keeps the layout stable as the
            // text appears/disappears.
            usernameAvailabilityHint
                .frame(height: 16)
        }
    }

    /// Shared text-input view for the three text-entry steps
    /// (name / username / phone). Renders as a large inline
    /// prompt rather than a card-wrapped TextField — the
    /// question itself is the placeholder, fading into the
    /// user's typed value as they enter it. Auto-focused so
    /// the keyboard + cursor appear immediately.
    ///
    /// `keyboard` defaults to `.default`; phone overrides to
    /// `.phonePad`. `contentType` lets iOS offer name /
    /// username / phone-number autofill.
    @ViewBuilder
    private func inlinePrompt(
        question: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        autocaps: TextInputAutocapitalization = .never,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(
            "",
            text: text,
            prompt: Text(question)
                .foregroundColor(AppPalette.textMuted.opacity(0.55))
        )
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(AppPalette.textStrong)
        .multilineTextAlignment(.center)
        .autocorrectionDisabled()
        .textContentType(contentType)
        .textInputAutocapitalization(autocaps)
        .keyboardType(keyboard)
        .focused($isInputFocused)
        .padding(.horizontal, LayoutMetrics.large)
    }

    @ViewBuilder
    private var usernameAvailabilityHint: some View {
        if username.count >= 3, let available = usernameAvailable {
            if available {
                HStack(spacing: 4) {
                    AppIcon(glyph: .check, size: 10, color: AppPalette.textPrimary)
                    Text("@\(username) is available")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.textMuted)
                }
            } else {
                Text("@\(username) is already taken")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
    }

    /// Photo step renders the same body as
    /// `ProfileHeaderCustomizeSheet` (minus the xmark header):
    /// style-name caps title, swipeable carousel of
    /// `ProfileHeaderStylePreview` cards, page dots, and a
    /// color picker that only shows for the bust style.
    ///
    /// Two visual states:
    ///   * No photo yet — single tap-to-add circle. The
    ///     carousel needs a real `UIImage` to render previews,
    ///     so the empty state is a simpler affordance until the
    ///     user picks.
    ///   * Photo picked — full carousel.
    @ViewBuilder
    private var photoStep: some View {
        if let avatar = pendingAvatarImage {
            photoStepCarousel(avatar: avatar)
        } else {
            photoStepEmpty
        }
    }

    private var photoStepEmpty: some View {
        // Layered like the text-input steps: the CIRCLE sits at
        // viewport center, the caps title floats above it via
        // offset so the welcome doesn't push the circle below
        // the visual center.
        ZStack {
            Button { showPhotoPicker = true } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 180, height: 180)
                        .overlay(
                            Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 1)
                        )
                        .appCircle(shadowRadius: 10, shadowY: 4)

                    // Plus glyph centered in the circle — caps
                    // title above explains the action, so the
                    // glyph alone is enough inside.
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add profile picture")

            // Caps title 120pt above the circle's center —
            // ~half the circle height (90) + 30pt gap.
            Text("ADD YOUR PROFILE PICTURE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .offset(y: -120)
        }
    }

    private func photoStepCarousel(avatar: UIImage) -> some View {
        VStack(spacing: 0) {
            // Style-name caps label above the carousel. Updates
            // as the user swipes — same pattern as
            // ProfileHeaderCustomizeSheet.styleNameTitle.
            Text(pendingHeaderStyle.displayName.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.2), value: pendingHeaderStyle)

            // Swipeable preview carousel. Each preview tap
            // re-opens the photo picker so the user can change
            // their photo without leaving this step.
            TabView(selection: $pendingHeaderStyle) {
                ForEach(ProfileHeaderStyle.allCases, id: \.self) { style in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ProfileHeaderStylePreview(
                            style: style,
                            accentColor: ProfileHeaderAccentColor.color(for: pendingAccentHex),
                            username: username.isEmpty ? "yafa" : username,
                            displayName: displayName.isEmpty ? "Your name" : displayName,
                            bio: nil,
                            avatarImage: avatar,
                            cutoutImage: pendingCutoutImage,
                            isProcessingCutout: isProcessingCutout && style == .bust,
                            onTapAvatar: { showPhotoPicker = true }
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .tag(style)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 360)

            // Accent color picker sits DIRECTLY under the
            // preview card so the user sees their color change
            // reflected immediately in the bust above. Diverges
            // from the customize sheet's order (which puts
            // color last) on purpose — onboarding hierarchy is
            // photo → color → progress, not photo → progress
            // → color.
            HStack(spacing: 14) {
                ForEach(ProfileHeaderAccentColor.palette, id: \.self) { hex in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        pendingAccentHex = hex
                    } label: {
                        Circle()
                            .fill(ProfileHeaderAccentColor.color(for: hex))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        AppPalette.textSecondary,
                                        lineWidth: hex == pendingAccentHex ? 1.5 : 0
                                    )
                                    .padding(-3.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ProfileHeaderAccentColor.accessibilityName(for: hex))
                    .accessibilityAddTraits(hex == pendingAccentHex ? .isSelected : [])
                }
            }
            .frame(height: 24)
            .padding(.top, 8)
            .opacity(pendingHeaderStyle == .bust ? 1 : 0)
            .allowsHitTesting(pendingHeaderStyle == .bust)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Highlighter color")

            // Capsule page-dot indicator: selected style is a
            // wide pill, others are tiny dots. Tappable so the
            // user can jump straight to a style instead of
            // swiping through the carousel.
            HStack(spacing: 6) {
                ForEach(ProfileHeaderStyle.allCases, id: \.self) { style in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            pendingHeaderStyle = style
                        }
                    } label: {
                        Capsule(style: .continuous)
                            .fill(style == pendingHeaderStyle ? AppPalette.textPrimary : AppPalette.textFaint)
                            .frame(
                                width: style == pendingHeaderStyle ? 18 : 6,
                                height: 6
                            )
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(style.displayName) style")
                    .accessibilityAddTraits(style == pendingHeaderStyle ? .isSelected : [])
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.78), value: pendingHeaderStyle)
            .padding(.top, 14)

            // Swipeability hint below the dots — last visual
            // element before CONTINUE so it doesn't compete
            // with the preview itself.
            Text("Swipe to choose your look")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textMuted)
                .padding(.top, 8)
        }
    }

    private var phoneStep: some View {
        inlinePrompt(
            question: "Your phone number",
            text: $phone,
            contentType: .telephoneNumber,
            keyboard: .phonePad
        )
    }

    // MARK: - Primary action

    private var primaryButton: some View {
        Button { Task { await advance(skipping: false) } } label: {
            Group {
                if isAdvancing {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text(currentStep == .phone ? "FINISH" : "CONTINUE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(canAdvance ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .appCapsule(
                shadowRadius: canAdvance ? 6 : 0,
                shadowY: canAdvance ? 3 : 0
            )
        }
        .buttonStyle(.plain)
        .disabled(!canAdvance || isAdvancing)
        .accessibilityLabel(currentStep == .phone ? "Finish" : "Continue")
    }

    /// Whether the user can tap Continue/Finish. Required steps
    /// gate on field validity; optional steps gate on either
    /// having a value OR using the (separate) Skip button. We
    /// keep the primary button active on optional steps too so
    /// the user can advance with content via the same big CTA.
    private var canAdvance: Bool {
        switch currentStep {
        case .name:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .username:
            return sanitizeUsername(username).count >= 3 && (usernameAvailable ?? false)
        case .photo, .phone:
            // Always allowed — Skip and Continue both lead to
            // advancing; the difference is just whether we
            // persist the in-flight field.
            return true
        }
    }

    // MARK: - Advance / back

    /// Persists the current step's field (unless skipping) and
    /// transitions to the next step — or finishes the flow if
    /// we're on the last step.
    private func advance(skipping: Bool) async {
        guard !isAdvancing else { return }
        await MainActor.run { isAdvancing = true }
        defer { Task { await MainActor.run { isAdvancing = false } } }

        if !skipping {
            do { try await persistCurrentStep() }
            catch { /* swallow: kick the user forward anyway */ }
        }

        if let next = Step(rawValue: currentStep.rawValue + 1) {
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentStep = next
                }
            }
        } else {
            await finish()
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: currentStep.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            currentStep = previous
        }
    }

    /// Writes the current step's field to the server. Each step
    /// persists separately so a crash mid-flow doesn't lose
    /// fields the user already filled. The final `setOnboardingComplete`
    /// fires once from `finish()`.
    private func persistCurrentStep() async throws {
        guard let userId = auth.userId,
              var profile = store.currentProfile
        else { return }
        switch currentStep {
        case .name:
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            profile.displayName = trimmed
            try await SocialService.updateProfile(profile)
            await MainActor.run {
                store.currentProfile?.displayName = trimmed
            }

        case .username:
            let cleaned = sanitizeUsername(username)
            guard cleaned.count >= 3 else { return }
            profile.username = cleaned
            try await SocialService.updateProfile(profile)
            await MainActor.run {
                store.currentProfile?.username = cleaned
            }

        case .photo:
            // No-op if user didn't pick a photo. If they did,
            // upload the avatar + (for bust) the cutout PNG,
            // then commit the style choice.
            guard let cropped = pendingAvatarImage else { return }
            let avatarURL = try await AvatarService.uploadAvatar(cropped, userId: userId)

            // If bust and we have a cutout ready, upload it so
            // the user's profile renders the real silhouette
            // from launch instead of falling back to the
            // circle-clipped avatar.
            var cutoutURL: String? = nil
            if pendingHeaderStyle == .bust, let cutout = pendingCutoutImage {
                cutoutURL = try? await AvatarService
                    .uploadAvatarCutout(cutout, userId: userId)
            }

            try await SocialService.updateHeaderCustomization(
                userId: userId,
                style: pendingHeaderStyle,
                accentColorHex: pendingHeaderStyle == .minimal ? nil : pendingAccentHex,
                cutoutURL: cutoutURL
            )
            await MainActor.run {
                store.currentAvatarImage = cropped
                if let cutout = pendingCutoutImage {
                    store.currentAvatarCutoutImage = cutout
                }
                store.currentProfile?.avatarUrl = avatarURL
                store.currentProfile?.avatarCutoutUrl = cutoutURL
                store.currentProfile?.headerStyle = pendingHeaderStyle.rawValue
                store.currentProfile?.headerAccentColor =
                    pendingHeaderStyle == .minimal ? nil : pendingAccentHex
            }

        case .phone:
            // Hash the phone number client-side (E.164 normalize
            // + SHA-256) then send the hash — same path
            // `ProfileView.saveProfile` uses. Bail silently if
            // empty (user advanced via Continue without typing)
            // or if hashing fails (invalid format) — phone is
            // optional, so a bad value just doesn't save.
            let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let hash = ContactsService.hashOwnPhoneNumber(trimmed)
            else { return }
            try await SocialService.updatePhoneHash(userId: userId, hash: hash)
            await MainActor.run {
                store.currentProfile?.phoneE164Hash = hash
                store.currentProfile?.phoneIsSet = true
            }
        }
    }

    /// Final step — flip is_onboarded server-side, then let the
    /// parent dismiss the cover. Local state mirror first so the
    /// app behind the cover doesn't reappear with stale
    /// `isOnboarded == false`.
    private func finish() async {
        guard let userId = auth.userId else { return }
        await MainActor.run {
            store.currentProfile?.isOnboarded = true
        }
        try? await SocialService.setOnboardingComplete(userId: userId)
        await MainActor.run { onFinish() }
    }

    // MARK: - Helpers

    /// Caps Profile's shared sanitizer at 30 chars (Instagram-style
    /// handle length limit). Profile.sanitizeUsername handles the
    /// lowercase + allowed-char filtering; we just clamp length.
    private func sanitizeUsername(_ raw: String) -> String {
        String(Profile.sanitizeUsername(raw).prefix(30))
    }

    /// Runs FAL background removal on the user's pre-crop
    /// original (or cropped fallback) so the bust preview shows
    /// the real cutout instead of the circle-clipped avatar.
    /// Idempotent — bails early if already processed or in
    /// flight or there's no source image yet.
    private func ensureCutoutAvailable() async {
        guard pendingCutoutImage == nil,
              !isProcessingCutout,
              let source = pendingOriginalImage ?? pendingAvatarImage,
              let jpegData = source.jpegData(compressionQuality: 0.92)
        else { return }

        await MainActor.run { isProcessingCutout = true }
        defer { Task { await MainActor.run { isProcessingCutout = false } } }

        do {
            let resultData = try await FalBackgroundRemovalService.shared
                .removeBackground(from: jpegData) { _ in }
            await MainActor.run {
                pendingCutoutImage = UIImage(data: resultData)
            }
        } catch {
            // Silent — preview falls back to circle-clipped
            // avatar. User can re-try by toggling away and back
            // to bust in the carousel.
        }
    }

    /// Hydrates the form from any partial profile data already on
    /// file — e.g. SIWA seeds display name in the new-user trigger.
    /// If a user lands in onboarding with an existing display name,
    /// we shouldn't make them retype it. Username gets pre-filled
    /// too even though the trigger usually generates one; user
    /// is free to overwrite.
    private func prefillFromExistingProfile() {
        if displayName.isEmpty, let existing = store.currentProfile?.displayName, !existing.isEmpty {
            displayName = existing
        }
        if username.isEmpty, let existing = store.currentProfile?.username, !existing.isEmpty {
            username = existing
            scheduleUsernameCheck()
        }
    }

    /// Debounced uniqueness check — ~400ms after the user stops
    /// typing. Avoids one server call per keystroke; matches
    /// what most signup forms do.
    private func scheduleUsernameCheck() {
        usernameCheckTask?.cancel()
        usernameAvailable = nil
        let candidate = sanitizeUsername(username)
        guard candidate.count >= 3 else { return }
        usernameCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let available = await SocialService.isUsernameAvailable(candidate)
            if Task.isCancelled { return }
            await MainActor.run {
                // Only commit the result if the candidate still
                // matches what's in the field — the user might
                // have kept typing during the network call.
                if candidate == sanitizeUsername(username) {
                    usernameAvailable = available
                }
            }
        }
    }

}

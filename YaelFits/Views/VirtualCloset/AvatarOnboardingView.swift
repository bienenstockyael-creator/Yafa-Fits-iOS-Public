import PhotosUI
import SwiftUI
import UIKit

/// First-run flow for the Virtual Closet. Walks the user through:
/// 1. Pick or take a clean reference photo (full-body, minimal clothing).
/// 2. Run it through nano-banana to standardise lighting + dress them in
///    plain white tee + white shorts so every Closet outfit lands on the
///    same canonical avatar.
/// 3. Accept (saves the avatar and proceeds to the closet) or retake.
struct AvatarOnboardingView: View {
    var onAccept: (UIImage) -> Void
    var onClose: () -> Void

    @State private var phase: Phase = .pick
    @State private var sourcePhoto: UIImage?
    @State private var standardizedAvatar: UIImage?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var statusDetail: String = ""
    @State private var generationError: String?

    enum Phase {
        case pick
        case preview          // user chose a photo, can confirm or retake
        case generating
        case review           // standardized avatar ready for accept
        case error
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                stage
                Spacer(minLength: 0)
                instructions
                primaryControls
            }
            .padding(.bottom, LayoutMetrics.medium)
        }
        .photosPicker(
            isPresented: Binding(
                get: { phase == .pick && photoPickerItem == nil && presentingPhotoPicker },
                set: { if !$0 { presentingPhotoPicker = false } }
            ),
            selection: $photoPickerItem,
            matching: .images
        )
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCaptureView { image in
                showsCamera = false
                if let image { adopt(photo: image) }
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedPhoto(newItem) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("CREATE YOUR AVATAR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
    }

    // MARK: - Stage (the big visual area)

    @ViewBuilder
    private var stage: some View {
        switch phase {
        case .pick:
            placeholderStage
        case .preview:
            if let sourcePhoto {
                stageImage(sourcePhoto)
            }
        case .generating:
            ZStack {
                if let sourcePhoto {
                    stageImage(sourcePhoto)
                        .opacity(0.45)
                }
                VStack(spacing: 12) {
                    ProgressView().tint(AppPalette.textPrimary).controlSize(.large)
                    Text(statusDetail.isEmpty ? "Generating your avatar…" : statusDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
        case .review:
            if let standardizedAvatar {
                stageImage(standardizedAvatar)
            }
        case .error:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(generationError ?? "Something went wrong.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.large)
            }
        }
    }

    private var placeholderStage: some View {
        VStack(alignment: .center, spacing: LayoutMetrics.medium) {
            Text("UPLOAD A FULL-BODY PHOTO")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)

            Text("Plain background, soft lighting, minimal clothing. We'll re-dress your avatar in a neutral white outfit so you can mix-and-match.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutMetrics.large)

            HStack(spacing: LayoutMetrics.small) {
                Button {
                    presentingPhotoPicker = true
                } label: {
                    uploadSourceCard(icon: .image, title: "Camera Roll")
                }
                .buttonStyle(.plain)

                Button {
                    showsCamera = true
                } label: {
                    uploadSourceCard(icon: .camera, title: "Camera")
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, LayoutMetrics.screenPadding)

            Text("MINIMAL CLOTHING · CLEAN BACKGROUND")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private func uploadSourceCard(icon: AppIconGlyph, title: String) -> some View {
        VStack(spacing: LayoutMetrics.small) {
            AppIcon(glyph: icon, size: 24, color: AppPalette.iconPrimary)
                .frame(width: 52, height: 52)
                .appCircle(shadowRadius: 0, shadowY: 0)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(LayoutMetrics.medium)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius, shadowRadius: 0, shadowY: 0)
    }

    private func stageImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 320, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
            .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    // MARK: - Instructional copy

    @ViewBuilder
    private var instructions: some View {
        switch phase {
        case .preview:
            Text("LOOKS GOOD? GENERATE TO CONTINUE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.top, LayoutMetrics.small)
        case .review:
            Text("ACCEPT TO START MIXING")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.top, LayoutMetrics.small)
        default:
            EmptyView()
        }
    }

    // MARK: - Primary controls

    @ViewBuilder
    private var primaryControls: some View {
        switch phase {
        case .pick:
            EmptyView()  // picker buttons live inside placeholderStage now
        case .preview:
            HStack(spacing: LayoutMetrics.small) {
                secondaryButton(title: "Retake") {
                    sourcePhoto = nil
                    photoPickerItem = nil
                    phase = .pick
                }
                primaryButton(title: "Generate Avatar") {
                    Task { await runStandardization() }
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.medium)
        case .review:
            HStack(spacing: LayoutMetrics.small) {
                secondaryButton(title: "Try Again") {
                    Task { await runStandardization() }
                }
                primaryButton(title: "Use This Avatar") {
                    if let standardizedAvatar {
                        onAccept(standardizedAvatar)
                    }
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.medium)
        case .error:
            HStack(spacing: LayoutMetrics.small) {
                secondaryButton(title: "Start Over") {
                    sourcePhoto = nil
                    standardizedAvatar = nil
                    photoPickerItem = nil
                    generationError = nil
                    phase = .pick
                }
                primaryButton(title: "Try Again") {
                    Task { await runStandardization() }
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.medium)
        case .generating:
            EmptyView()
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppPalette.textStrong)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .appRoundedRect(cornerRadius: 16, shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Photo picker plumbing

    @State private var presentingPhotoPicker = false

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                photoPickerItem = nil
                adopt(photo: image)
            }
        } catch {
            await MainActor.run {
                photoPickerItem = nil
                generationError = error.localizedDescription
                phase = .error
            }
        }
    }

    private func adopt(photo: UIImage) {
        sourcePhoto = photo
        phase = .preview
    }

    // MARK: - Generation

    private func runStandardization() async {
        guard let sourcePhoto else { return }
        await MainActor.run {
            phase = .generating
            statusDetail = "nano-banana is generating."
        }
        do {
            let avatar = try await FalAvatarStandardizationService.shared.standardize(
                from: sourcePhoto
            ) { progress in
                await MainActor.run { statusDetail = progress.detail }
            }
            await MainActor.run {
                standardizedAvatar = avatar
                phase = .review
            }
        } catch {
            await MainActor.run {
                generationError = error.localizedDescription
                phase = .error
            }
        }
    }
}

import AVFoundation
import AVKit
import UserNotifications
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

struct UploadPipelineView: View {
    @Environment(OutfitStore.self) private var store

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var previewPlayer: AVQueuePlayer?
    @State private var previewLooper: AVPlayerLooper?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .center, spacing: LayoutMetrics.large) {
                    if isInitialUploadState {
                        Spacer(minLength: 0)
                    }

                    if isInitialUploadState {
                        titleBlock
                    }

                    if showsPipelineLoader {
                        pipelineLoader
                    }

                    if let error = job?.error {
                        errorBanner(error)
                    }

                    if !showsPipelineLoader {
                        stepContent
                    }

                    if isInitialUploadState {
                        Spacer(minLength: 0)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(
                        0,
                        geometry.size.height - LayoutMetrics.uploadTopInset - LayoutMetrics.bottomOverlayInset
                    )
                )
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.uploadTopInset)
                .padding(.bottom, LayoutMetrics.bottomOverlayInset)
            }
            .scrollDisabled(true)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { image in
                showingCamera = false
                guard let image else { return }
                handleCameraCapture(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        presentError(UploadPipelineError.invalidImage)
                    }
                    return
                }
                await MainActor.run {
                    beginPipeline(with: data)
                    selectedPhoto = nil
                }
            }
        }
        .onDisappear {
            previewPlayer?.pause()
        }
    }

    private var job: PipelineJob? {
        store.uploadJob
    }

    private var currentStep: PipelineStep {
        job?.step ?? .upload
    }

    private var showsPipelineLoader: Bool {
        job?.isProcessing == true
    }

    private var isInitialUploadState: Bool {
        currentStep == .upload && job == nil
    }

    private var stepContent: some View {
        Group {
            switch currentStep {
            case .upload:
                uploadStep
            case .generate:
                generateStep
            case .review:
                reviewStep
            case .complete:
                completeStep
            }
        }
    }

    private var titleBlock: some View {
        Text("UPLOAD TODAY'S FIT")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
            .frame(maxWidth: .infinity)
    }

    private var pipelineLoader: some View {
        GeometryReader { geo in
            ZStack {
                // Stars fill the whole stage
                GenerationStarField()

                // Stage label with shimmer — centred vertically and horizontally
                VStack(spacing: LayoutMetrics.small) {
                    Spacer()
                    ShimmerText(
                        text: currentStageLabel,
                        font: .system(size: 9, weight: .bold, design: .monospaced),
                        tracking: 2
                    )
                    .multilineTextAlignment(.center)

                    Text(disclaimerText)
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LayoutMetrics.xLarge)
                        .animation(.easeInOut(duration: 0.4), value: currentStageLabel)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentStageLabel: String {
        let stage = job?.loaderStage ?? .removingBackground
        switch stage {
        case .removingBackground:
            return "REMOVING BACKGROUND"
        case .creatingInteractiveFit:
            return "CREATING YOUR INTERACTIVE FIT"
        case .compressing:
            return "COMPRESSING"
        }
    }

    private var disclaimerText: String {
        let stage = job?.loaderStage ?? .removingBackground
        switch stage {
        case .removingBackground:
            return "Cutting you out of the background like the main character you are."
        case .creatingInteractiveFit:
            return "Good things take a few minutes. Sit tight — we'll notify you the second your fit is ready."
        case .compressing:
            return "Almost there. Squeezing your fit into its final form."
        }
    }

    private var uploadStep: some View {
        VStack(alignment: .center, spacing: LayoutMetrics.medium) {
            HStack(spacing: LayoutMetrics.small) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    sourceButton(
                        icon: .image,
                        title: "Camera Roll"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        presentError(UploadPipelineError.unsupportedCamera)
                        return
                    }
                    showingCamera = true
                } label: {
                    sourceButton(
                        icon: .camera,
                        title: "Camera"
                    )
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)

            Text("FULL BODY · CENTERED")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var generateStep: some View {
        Group {
            if job?.isProcessing == true {
                Color.clear.frame(height: 0)
            } else if job?.error != nil {
                pipelineRecoveryCard
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            Text("Your interactive fit is ready for review")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(AppPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            interactiveOutfitReviewCard

            VStack(spacing: LayoutMetrics.xSmall) {
                Button {
                    finalizeCurrentVideo(publishToFeed: false)
                } label: {
                    Text("Accept")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)

                Button {
                    finalizeCurrentVideo(publishToFeed: true)
                } label: {
                    Text("Accept + Publish to Public")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)

                Button {
                    retakeCurrentOutfit()
                } label: {
                    Text("Retake")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(LayoutMetrics.small)
        .appCard()
    }

    private var completeStep: some View {
        VStack(spacing: LayoutMetrics.small) {
            VStack(spacing: LayoutMetrics.xSmall) {
                AppIcon(glyph: .circleCheck, size: 20, color: AppPalette.iconActive)

                Text(job?.publishedToFeed == true ? "Saved and published" : "Saved to archive")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: LayoutMetrics.xSmall) {
                Button {
                    resetPipeline()
                } label: {
                    Text("Create Another")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)

                Button {
                    store.selectedOutfitId = nil
                    store.currentView = job?.publishedToFeed == true ? .feed : .list
                } label: {
                    Text(job?.publishedToFeed == true ? "View Public" : "View Archive")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    private func previewTile(title: String, data: Data, height: CGFloat = 220) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppPalette.textMuted)

            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(LayoutMetrics.xSmall)
        .frame(width: height == 220 ? 170 : nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRoundedRect(cornerRadius: 20, shadowRadius: 0, shadowY: 0)
    }

    private var interactiveOutfitReviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.22))

                if let reviewOutfit = job?.stagedOutfit {
                    RotatableOutfitImage(
                        outfit: reviewOutfit,
                        height: 300,
                        draggable: true,
                        eagerLoad: true
                    )
                    .id("\(reviewOutfit.id)-\(reviewOutfit.rotationReversed ? 1 : 0)")
                    .padding(.horizontal, LayoutMetrics.small)
                    .padding(.vertical, LayoutMetrics.medium)
                } else {
                    VStack(spacing: LayoutMetrics.xxSmall) {
                        AppIcon(glyph: .circleAlert, size: 26, color: AppPalette.iconPrimary)
                        Text("Preparing the final outfit sequence.")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppPalette.textMuted)
                }

                Button {
                    toggleRotationDirection()
                } label: {
                    Text(job?.isRotationReversed == true ? "Use Original" : "Reverse Rotation")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(AppPalette.textMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .appCapsule(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, LayoutMetrics.small)
                .padding(.bottom, LayoutMetrics.small)
            }
            .frame(height: 330)
        }
        .padding(LayoutMetrics.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRoundedRect(cornerRadius: 20, shadowRadius: 0, shadowY: 0)
    }

    private func sourceButton(icon: AppIconGlyph, title: String) -> some View {
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

    private var pipelineRecoveryCard: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            Text("Something interrupted the generation.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)

            Button {
                resetPipeline()
            } label: {
                Text("Start Over")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .appRoundedRect(cornerRadius: 18, shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(LayoutMetrics.medium)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius, shadowRadius: 0, shadowY: 0)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.xxSmall) {
            AppIcon(glyph: .circleAlert, size: 14, color: .red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.92))
        }
        .padding(LayoutMetrics.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func handleCameraCapture(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 1) else {
            presentError(UploadPipelineError.invalidImage)
            return
        }
        beginPipeline(with: imageData)
    }

    private func beginPipeline(with imageData: Data) {
        store.cancelUploadTask()
        resetPreviewPlayer()
        discardUnacceptedStagedOutfitIfNeeded()
        endGenerationBackgroundActivity()

        let newJob = PipelineJob(outfitNum: nextOutfitNumber())
        newJob.loaderStage = .removingBackground
        newJob.sourceImage = imageData
        newJob.step = .generate
        newJob.isProcessing = true
        newJob.error = nil
        newJob.progress = nil
        newJob.publishedToFeed = false
        newJob.statusTitle = "Preparing cutout comparison"
        newJob.statusDetail = "Running Apple and fal Bria background removal on the same source image."
        newJob.logLines = []
        store.uploadJob = newJob

        Task {
            let weather = await UploadWeatherService.shared.fetchCurrentWeather()
            await MainActor.run {
                guard store.uploadJob?.id == newJob.id else { return }
                newJob.uploadWeather = weather
            }
        }

        beginGenerationBackgroundActivity()
        let task = Task {
            await processAndGenerate(job: newJob, imageData: imageData)
        }
        store.replaceUploadTask(with: task)
    }

    private func regenerateCurrentVideo() {
        guard let job, let greenScreenData = job.greenScreenImage else {
            presentError(UploadPipelineError.invalidImage)
            return
        }

        store.cancelUploadTask()
        resetPreviewPlayer()
        LocalOutfitStore.shared.clearPendingReview()
        endGenerationBackgroundActivity()

        if let stagedOutfit = job.stagedOutfit {
            LocalOutfitStore.shared.deleteOutfitData(for: stagedOutfit)
        }

        job.step = .generate
        job.loaderStage = .creatingInteractiveFit
        job.isRotationReversed = false
        job.error = nil
        job.isProcessing = true
        job.videoURL = nil
        job.stagedOutfit = nil
        job.progress = nil
        job.logLines = []
        job.statusTitle = "Submitting to Kling 2.5"
        job.statusDetail = "Regenerating a 10-second orbit from the saved green-screen composite."

        beginGenerationBackgroundActivity()
        let task = Task {
            await generateVideo(job: job, greenScreenData: greenScreenData)
        }
        store.replaceUploadTask(with: task)
    }

    private func finalizeCurrentVideo(publishToFeed: Bool) {
        guard let job, let outfit = job.stagedOutfit else {
            presentError(UploadPipelineError.emptyExport)
            return
        }

        var finalizedOutfit = outfit
        finalizedOutfit.isRotationReversed = job.isRotationReversed
        if finalizedOutfit.weather == nil {
            finalizedOutfit.weather = job.uploadWeather
        }

        store.addOutfit(finalizedOutfit)
        if publishToFeed {
            store.publishOutfitToFeed(finalizedOutfit)
        }
        job.resultOutfitId = finalizedOutfit.id
        job.resultFrameCount = finalizedOutfit.frameCount
        job.publishedToFeed = publishToFeed
        job.step = .complete
        job.isProcessing = false
        job.progress = nil
        job.statusTitle = publishToFeed ? "Saved and published" : "Complete"
        job.statusDetail = publishToFeed
            ? "The new outfit is now in your archive and public feed."
            : "The new outfit is now in the archive."
        store.cancelUploadTask()
        LocalOutfitStore.shared.clearPendingReview()
        endGenerationBackgroundActivity()

        if let userId = store.userId {
            Task {
                try? await OutfitService.saveArchiveOutfit(finalizedOutfit, userId: userId, isPublic: publishToFeed)
            }
        }

        Task.detached(priority: .utility) {
            await FrameLoader.shared.preloadFirstFrames(outfits: [finalizedOutfit])
        }
    }

    private func retakeCurrentOutfit() {
        guard job?.greenScreenImage != nil else {
            resetPipeline()
            return
        }
        regenerateCurrentVideo()
    }

    private func toggleRotationDirection() {
        guard let job, var stagedOutfit = job.stagedOutfit else { return }
        let newValue = !job.isRotationReversed
        job.isRotationReversed = newValue
        stagedOutfit.isRotationReversed = newValue
        job.stagedOutfit = stagedOutfit
        persistPendingReviewIfNeeded(for: job)
    }

    private func processAndGenerate(job: PipelineJob, imageData: Data) async {
        do {
            let preparedAssets = try await ImageMaskingService.shared.prepareUploadAssets(
                from: imageData,
                using: .falBria
            ) { title, detail in
                await MainActor.run {
                    job.statusTitle = title
                    job.statusDetail = detail
                }
            }

            await MainActor.run {
                job.cutoutImage = preparedAssets.cutoutPNGData
                job.greenScreenImage = preparedAssets.greenScreenPNGData
                job.maskingBackend = .falBria
                job.loaderStage = .creatingInteractiveFit
                job.statusTitle = "Submitting to Kling 2.5"
                job.statusDetail = "Sending the cutout to Kling 2.5 for a 10-second orbit."
            }

            await generateVideo(job: job, greenScreenData: preparedAssets.greenScreenPNGData)
        } catch is CancellationError {
            await MainActor.run {
                endGenerationBackgroundActivity()
            }
            return
        } catch {
            await MainActor.run {
                job.isProcessing = false
                job.error = readableError(error)
                store.uploadTask = nil
                endGenerationBackgroundActivity()
            }
        }
    }

    private func generateVideo(job: PipelineJob, greenScreenData: Data) async {
        do {
            let videoURL = try await FalVideoGenerationService.shared.generateRotationVideo(
                from: greenScreenData,
                prompt: job.prompt
            ) { progress in
                await MainActor.run {
                    job.requestId = progress.requestId
                    job.statusTitle = progress.title
                    job.statusDetail = progress.detail
                    job.logLines = progress.logLines
                    job.progress = nil
                }
            }

            await MainActor.run {
                job.videoURL = videoURL
                job.loaderStage = .compressing
                job.isProcessing = true
                job.progress = 0
                job.error = nil
                job.statusTitle = "Compressing"
                job.statusDetail = "Building the final interactive frame sequence."
            }

            let outfit = try await VideoFrameSequenceExporter.shared.exportSequence(
                from: videoURL,
                referenceGreenScreenPNGData: greenScreenData,
                outfitNumber: job.outfitNum
            ) { progress, detail in
                await MainActor.run {
                    job.loaderStage = .compressing
                    job.progress = progress
                    job.statusTitle = "Compressing"
                    job.statusDetail = detail
                }
            }

            await MainActor.run {
                job.isRotationReversed = false
                var stagedOutfit = outfit
                stagedOutfit.isRotationReversed = false
                if stagedOutfit.weather == nil {
                    stagedOutfit.weather = job.uploadWeather
                }
                job.stagedOutfit = stagedOutfit
                job.step = .review
                job.isProcessing = false
                job.progress = nil
                job.error = nil
                job.statusTitle = "Ready"
                job.statusDetail = "Your interactive fit is ready."
                store.uploadTask = nil
                persistPendingReviewIfNeeded(for: job)
                store.generationReadyForReview = true
                endGenerationBackgroundActivity()
                sendGenerationCompleteNotificationIfNeeded()
            }
        } catch is CancellationError {
            await MainActor.run {
                endGenerationBackgroundActivity()
            }
            return
        } catch {
            await MainActor.run {
                job.isProcessing = false
                job.progress = nil
                job.error = readableError(error)
                store.uploadTask = nil
                endGenerationBackgroundActivity()
            }
        }
    }

    private func configurePreviewPlayer(with url: URL) {
        resetPreviewPlayer()
        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        previewPlayer = player
        previewLooper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    private func resetPreviewPlayer() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewLooper = nil
    }

    private func resetPipeline() {
        store.cancelUploadTask()
        resetPreviewPlayer()
        discardUnacceptedStagedOutfitIfNeeded()
        selectedPhoto = nil
        store.uploadJob = nil
        LocalOutfitStore.shared.clearPendingReview()
        endGenerationBackgroundActivity()
    }

    private func discardUnacceptedStagedOutfitIfNeeded() {
        guard let stagedOutfit = job?.stagedOutfit,
              job?.resultOutfitId == nil else {
            return
        }
        job?.stagedOutfit = nil
        LocalOutfitStore.shared.deleteOutfitData(for: stagedOutfit)
        LocalOutfitStore.shared.clearPendingReview()
    }

    private func nextOutfitNumber() -> Int {
        let maxExisting = store.outfits.compactMap(\.outfitNumber).max() ?? 0
        return max(maxExisting + 1, LocalOutfitStore.shared.nextOutfitNum())
    }

    private func persistPendingReviewIfNeeded(for job: PipelineJob) {
        guard let review = PersistedPipelineReview(job: job) else {
            LocalOutfitStore.shared.clearPendingReview()
            return
        }

        LocalOutfitStore.shared.savePendingReview(review)
    }

    private func beginGenerationBackgroundActivity() {
        GenerationBackgroundActivity.shared.begin()
    }

    private func endGenerationBackgroundActivity() {
        GenerationBackgroundActivity.shared.end()
    }

    private func sendGenerationCompleteNotificationIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your interactive fit is ready ✨"
        content.body = "Tap to review and add it to your archive."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "generation-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func presentError(_ error: Error) {
        let existingJob = job ?? PipelineJob(outfitNum: nextOutfitNumber())
        existingJob.error = readableError(error)
        store.uploadJob = existingJob
    }

    private func readableError(_ error: Error) -> String {
        if let uploadError = error as? UploadPipelineError,
           let description = uploadError.errorDescription {
            return description
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

@MainActor
private final class GenerationBackgroundActivity {
    static let shared = GenerationBackgroundActivity()

    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "com.yafa.generation") { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard taskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.modalPresentationStyle = .fullScreen
        picker.showsCameraControls = true
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onImagePicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImagePicked(nil)
        }
    }
}

private struct LoopingVideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .clear
        configure(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        configure(uiViewController, coordinator: context.coordinator)
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()
        uiViewController.player = nil
        coordinator.player = nil
        coordinator.looper = nil
        coordinator.currentURL = nil
    }

    private func configure(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()

        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: item)

        player.isMuted = true
        controller.player = player

        coordinator.player = player
        coordinator.looper = looper
        coordinator.currentURL = url

        player.play()
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var currentURL: URL?
    }
}

private struct CameraGuideOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let aspect = UploadConfig.compositionDimensions.height / UploadConfig.compositionDimensions.width
            let maxGuideWidth = min(geometry.size.width * 0.9, 390)
            let maxGuideHeight = geometry.size.height * 0.8
            let guideWidth = min(maxGuideWidth, maxGuideHeight / aspect)
            let guideHeight = guideWidth * aspect
            let guideY = geometry.size.height * 0.51
            let frameRect = CGRect(
                x: (geometry.size.width - guideWidth) / 2,
                y: guideY - guideHeight / 2,
                width: guideWidth,
                height: guideHeight
            )

            ZStack {
                CropFrameFocusShape(frameRect: frameRect, cornerRadius: 32)
                    .fill(Color.black.opacity(0.26), style: FillStyle(eoFill: true))

                ZStack {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.white.opacity(0.32), lineWidth: 1.25)
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 6)
                                .blur(radius: 18)
                        }

                    FrameCornersShape()
                        .stroke(Color.white.opacity(0.96), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .overlay {
                            FrameCornersShape()
                                .stroke(Color.white.opacity(0.34), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                                .blur(radius: 16)
                        }

                    Rectangle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 2.5, height: guideHeight * 0.56)
                        .overlay {
                            Rectangle()
                                .fill(Color.white.opacity(0.42))
                                .blur(radius: 14)
                        }

                    Rectangle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: guideWidth * 0.38, height: 2.5)
                        .overlay {
                            Rectangle()
                                .fill(Color.white.opacity(0.42))
                                .blur(radius: 14)
                        }

                    Circle()
                        .fill(Color.white.opacity(0.98))
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .fill(Color.white.opacity(0.44))
                                .frame(width: 26, height: 26)
                                .blur(radius: 9)
                        }
                }
                .frame(width: guideWidth, height: guideHeight)
                .position(x: geometry.size.width / 2, y: guideY)
            }
        }
        .ignoresSafeArea()
    }
}

private struct CropFrameFocusShape: Shape {
    let frameRect: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: frameRect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}

private struct FrameCornersShape: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.12
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))

        return path
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        uiView.isUserInteractionEnabled = false
    }
}

private final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CameraCaptureViewController: UIImagePickerController, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    private let onImagePicked: (UIImage?) -> Void
    private let overlayView = CameraOverlayContainerView()

    private var capturedImage: UIImage? {
        didSet {
            overlayView.setCapturedImage(capturedImage)
        }
    }

    private var isCapturingPhoto = false {
        didSet {
            overlayView.setCapturing(isCapturingPhoto)
        }
    }

    private var permissionDenied = false {
        didSet {
            overlayView.setPermissionDenied(permissionDenied)
        }
    }

    init(onImagePicked: @escaping (UIImage?) -> Void) {
        self.onImagePicked = onImagePicked
        super.init(nibName: nil, bundle: nil)
        delegate = self
        sourceType = .camera
        cameraDevice = .rear
        cameraCaptureMode = .photo
        showsCameraControls = false
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupOverlay()
        requestCameraAccessIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyFullscreenCameraTransform()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFullscreenCameraTransform()
        view.bringSubviewToFront(overlayView)
    }

    private func setupOverlay() {
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        overlayView.onClose = { [weak self] in
            self?.onImagePicked(nil)
        }
        overlayView.onClear = { [weak self] in
            guard let self else { return }
            self.capturedImage = nil
            self.overlayView.setErrorMessage(nil)
        }
        overlayView.onCapture = { [weak self] in
            self?.capturePhoto()
        }
        overlayView.onUsePhoto = { [weak self] in
            guard let self, let capturedImage = self.capturedImage else { return }
            self.onImagePicked(capturedImage)
        }
        overlayView.onOpenSettings = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionDenied = !granted
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    private func applyFullscreenCameraTransform() {
        let previewHeight = view.bounds.width * (4.0 / 3.0)
        guard previewHeight > 0 else { return }
        let scale = max(view.bounds.height / previewHeight, 1)
        cameraViewTransform = CGAffineTransform(scaleX: scale, y: scale)
    }

    private func capturePhoto() {
        guard !permissionDenied else {
            overlayView.setErrorMessage("Camera access is required to take a photo.")
            return
        }
        guard !isCapturingPhoto else { return }

        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        isCapturingPhoto = true
        overlayView.setErrorMessage(nil)
        takePicture()
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        isCapturingPhoto = false

        guard let image = info[.originalImage] as? UIImage else {
            overlayView.setErrorMessage("Could not capture photo.")
            return
        }

        capturedImage = image
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onImagePicked(nil)
    }
}

private final class CameraOverlayContainerView: UIView {
    var onClose: (() -> Void)?
    var onClear: (() -> Void)?
    var onCapture: (() -> Void)?
    var onUsePhoto: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let capturedImageView = UIImageView()
    private let gradientView = UIView()
    private let guideView = UIKitCameraGuideOverlayView()
    private let closeButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let errorLabel = InsetLabel()
    private let instructionLabel = UILabel()
    private let shutterButton = UIButton(type: .custom)
    private let shutterRingView = UIView()
    private let shutterFillView = UIView()
    private let shutterSpinner = UIActivityIndicatorView(style: .medium)
    private let usePhotoButton = UIButton(type: .system)
    private let permissionCard = UIView()
    private let permissionTitleLabel = UILabel()
    private let permissionDescriptionLabel = UILabel()
    private let permissionButtonsStack = UIStackView()
    private let permissionCloseButton = UIButton(type: .system)
    private let permissionSettingsButton = UIButton(type: .system)
    private let bottomStack = UIStackView()
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupViews()
        setCapturedImage(nil)
        setCapturing(false)
        setPermissionDenied(false)
        setErrorMessage(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = gradientView.bounds
    }

    func setCapturedImage(_ image: UIImage?) {
        let hasCapture = image != nil
        capturedImageView.image = image
        capturedImageView.isHidden = !hasCapture
        clearButton.isEnabled = hasCapture
        clearButton.alpha = hasCapture ? 1 : 0.72
        instructionLabel.isHidden = hasCapture
        shutterButton.isHidden = hasCapture
        usePhotoButton.isHidden = !hasCapture
    }

    func setCapturing(_ capturing: Bool) {
        shutterButton.isEnabled = !capturing
        if capturing {
            shutterSpinner.startAnimating()
        } else {
            shutterSpinner.stopAnimating()
        }
    }

    func setErrorMessage(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = (message?.isEmpty ?? true)
    }

    func setPermissionDenied(_ denied: Bool) {
        permissionCard.isHidden = !denied
        closeButton.isHidden = denied
        clearButton.isHidden = denied
        bottomStack.isHidden = denied
        guideView.isHidden = denied
    }

    private func setupViews() {
        capturedImageView.translatesAutoresizingMaskIntoConstraints = false
        capturedImageView.contentMode = .scaleAspectFill
        capturedImageView.clipsToBounds = true
        capturedImageView.isUserInteractionEnabled = false
        addSubview(capturedImageView)

        gradientView.translatesAutoresizingMaskIntoConstraints = false
        gradientView.isUserInteractionEnabled = false
        addSubview(gradientView)

        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.42).cgColor,
            UIColor.black.withAlphaComponent(0.04).cgColor,
            UIColor.black.withAlphaComponent(0.58).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientView.layer.addSublayer(gradientLayer)

        guideView.translatesAutoresizingMaskIntoConstraints = false
        guideView.isUserInteractionEnabled = false
        addSubview(guideView)

        styleCircleButton(closeButton, systemName: "xmark")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        styleCapsuleButton(clearButton, title: "Clear", foreground: .white, fillColor: UIColor.white.withAlphaComponent(0.16), strokeColor: UIColor.white.withAlphaComponent(0.18))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        addSubview(clearButton)

        bottomStack.axis = .vertical
        bottomStack.alignment = .center
        bottomStack.spacing = LayoutMetrics.medium
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomStack)

        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        errorLabel.textInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        errorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.24)
        errorLabel.layer.cornerRadius = 999
        errorLabel.clipsToBounds = true
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        instructionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        instructionLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        instructionLabel.textAlignment = .center
        instructionLabel.text = "Keep your body centered inside the frame"

        setupShutterButton()

        styleCapsuleButton(usePhotoButton, title: "Use Photo", foreground: UIColor.black.withAlphaComponent(0.84), fillColor: .white, strokeColor: .clear)
        usePhotoButton.translatesAutoresizingMaskIntoConstraints = false
        usePhotoButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        usePhotoButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        usePhotoButton.addTarget(self, action: #selector(usePhotoTapped), for: .touchUpInside)

        bottomStack.addArrangedSubview(errorLabel)
        bottomStack.addArrangedSubview(instructionLabel)
        bottomStack.addArrangedSubview(shutterButton)
        bottomStack.addArrangedSubview(usePhotoButton)

        setupPermissionCard()

        NSLayoutConstraint.activate([
            capturedImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            capturedImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            capturedImageView.topAnchor.constraint(equalTo: topAnchor),
            capturedImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gradientView.topAnchor.constraint(equalTo: topAnchor),
            gradientView.bottomAnchor.constraint(equalTo: bottomAnchor),
            guideView.leadingAnchor.constraint(equalTo: leadingAnchor),
            guideView.trailingAnchor.constraint(equalTo: trailingAnchor),
            guideView.topAnchor.constraint(equalTo: topAnchor),
            guideView.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LayoutMetrics.screenPadding),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LayoutMetrics.screenPadding),
            clearButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            clearButton.heightAnchor.constraint(equalToConstant: 38),
            bottomStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: LayoutMetrics.screenPadding),
            bottomStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -LayoutMetrics.screenPadding),
            bottomStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -28),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            instructionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    private func setupShutterButton() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.widthAnchor.constraint(equalToConstant: 86).isActive = true
        shutterButton.heightAnchor.constraint(equalToConstant: 86).isActive = true
        shutterButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        shutterButton.layer.cornerRadius = 43
        shutterButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        shutterRingView.translatesAutoresizingMaskIntoConstraints = false
        shutterRingView.isUserInteractionEnabled = false
        shutterRingView.layer.cornerRadius = 38
        shutterRingView.layer.borderWidth = 4
        shutterRingView.layer.borderColor = UIColor.white.withAlphaComponent(0.95).cgColor
        shutterButton.addSubview(shutterRingView)

        shutterFillView.translatesAutoresizingMaskIntoConstraints = false
        shutterFillView.isUserInteractionEnabled = false
        shutterFillView.backgroundColor = .white
        shutterFillView.layer.cornerRadius = 30
        shutterButton.addSubview(shutterFillView)

        shutterSpinner.translatesAutoresizingMaskIntoConstraints = false
        shutterSpinner.hidesWhenStopped = true
        shutterSpinner.color = UIColor.black.withAlphaComponent(0.75)
        shutterButton.addSubview(shutterSpinner)

        NSLayoutConstraint.activate([
            shutterRingView.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterRingView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            shutterRingView.widthAnchor.constraint(equalToConstant: 76),
            shutterRingView.heightAnchor.constraint(equalToConstant: 76),
            shutterFillView.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterFillView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            shutterFillView.widthAnchor.constraint(equalToConstant: 60),
            shutterFillView.heightAnchor.constraint(equalToConstant: 60),
            shutterSpinner.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterSpinner.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
        ])
    }

    private func setupPermissionCard() {
        permissionCard.translatesAutoresizingMaskIntoConstraints = false
        permissionCard.backgroundColor = UIColor.black.withAlphaComponent(0.36)
        permissionCard.layer.cornerRadius = 24
        addSubview(permissionCard)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = LayoutMetrics.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        permissionCard.addSubview(stack)

        permissionTitleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        permissionTitleLabel.textColor = .white
        permissionTitleLabel.textAlignment = .center
        permissionTitleLabel.text = "Camera access is off"

        permissionDescriptionLabel.font = .systemFont(ofSize: 14)
        permissionDescriptionLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        permissionDescriptionLabel.numberOfLines = 0
        permissionDescriptionLabel.textAlignment = .center
        permissionDescriptionLabel.text = "Allow camera access in Settings to capture your fit."

        permissionButtonsStack.axis = .horizontal
        permissionButtonsStack.alignment = .fill
        permissionButtonsStack.distribution = .fillEqually
        permissionButtonsStack.spacing = LayoutMetrics.small

        styleCapsuleButton(permissionCloseButton, title: "Close", foreground: .white, fillColor: UIColor.white.withAlphaComponent(0.12), strokeColor: UIColor.clear)
        permissionCloseButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        styleCapsuleButton(permissionSettingsButton, title: "Open Settings", foreground: UIColor.black.withAlphaComponent(0.82), fillColor: .white, strokeColor: .clear)
        permissionSettingsButton.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)

        permissionButtonsStack.addArrangedSubview(permissionCloseButton)
        permissionButtonsStack.addArrangedSubview(permissionSettingsButton)

        stack.addArrangedSubview(permissionTitleLabel)
        stack.addArrangedSubview(permissionDescriptionLabel)
        stack.addArrangedSubview(permissionButtonsStack)

        NSLayoutConstraint.activate([
            permissionCard.centerXAnchor.constraint(equalTo: centerXAnchor),
            permissionCard.centerYAnchor.constraint(equalTo: centerYAnchor),
            permissionCard.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: LayoutMetrics.screenPadding),
            permissionCard.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -LayoutMetrics.screenPadding),
            permissionCard.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.leadingAnchor.constraint(equalTo: permissionCard.leadingAnchor, constant: LayoutMetrics.large),
            stack.trailingAnchor.constraint(equalTo: permissionCard.trailingAnchor, constant: -LayoutMetrics.large),
            stack.topAnchor.constraint(equalTo: permissionCard.topAnchor, constant: LayoutMetrics.large),
            stack.bottomAnchor.constraint(equalTo: permissionCard.bottomAnchor, constant: -LayoutMetrics.large),
            permissionCloseButton.heightAnchor.constraint(equalToConstant: 48),
            permissionSettingsButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func styleCircleButton(_ button: UIButton, systemName: String) {
        let image = UIImage(systemName: systemName)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        button.layer.cornerRadius = 19
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
    }

    private func styleCapsuleButton(_ button: UIButton, title: String, foreground: UIColor, fillColor: UIColor, strokeColor: UIColor) {
        if #available(iOS 15.0, *) {
            var config = button.configuration ?? .plain()
            var attributes = AttributeContainer()
            attributes.font = .systemFont(ofSize: 12, weight: .semibold)

            config.attributedTitle = AttributedString(title, attributes: attributes)
            config.baseForegroundColor = foreground
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.setTitleColor(foreground, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        }

        button.backgroundColor = fillColor
        button.layer.cornerRadius = 19
        button.layer.borderWidth = strokeColor == .clear ? 0 : 1
        button.layer.borderColor = strokeColor.cgColor
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func clearTapped() {
        onClear?()
    }

    @objc private func captureTapped() {
        onCapture?()
    }

    @objc private func usePhotoTapped() {
        onUsePhoto?()
    }

    @objc private func openSettingsTapped() {
        onOpenSettings?()
    }
}

private final class UIKitCameraGuideOverlayView: UIView {
    private let maskLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let cornersLayer = CAShapeLayer()
    private let cornersGlowLayer = CAShapeLayer()
    private let crossLayer = CAShapeLayer()
    private let crossGlowLayer = CAShapeLayer()
    private let centerLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.26).cgColor
        layer.addSublayer(maskLayer)

        outlineLayer.strokeColor = UIColor.white.withAlphaComponent(0.32).cgColor
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.lineWidth = 1.25
        layer.addSublayer(outlineLayer)

        glowLayer.strokeColor = UIColor.white.withAlphaComponent(0.12).cgColor
        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.lineWidth = 6
        layer.addSublayer(glowLayer)

        cornersGlowLayer.strokeColor = UIColor.white.withAlphaComponent(0.34).cgColor
        cornersGlowLayer.fillColor = UIColor.clear.cgColor
        cornersGlowLayer.lineWidth = 10
        cornersGlowLayer.lineCap = .round
        cornersGlowLayer.lineJoin = .round
        layer.addSublayer(cornersGlowLayer)

        cornersLayer.strokeColor = UIColor.white.withAlphaComponent(0.96).cgColor
        cornersLayer.fillColor = UIColor.clear.cgColor
        cornersLayer.lineWidth = 2.4
        cornersLayer.lineCap = .round
        cornersLayer.lineJoin = .round
        layer.addSublayer(cornersLayer)

        crossGlowLayer.strokeColor = UIColor.white.withAlphaComponent(0.42).cgColor
        crossGlowLayer.fillColor = UIColor.clear.cgColor
        crossGlowLayer.lineWidth = 12
        crossGlowLayer.lineCap = .round
        layer.addSublayer(crossGlowLayer)

        crossLayer.strokeColor = UIColor.white.withAlphaComponent(0.96).cgColor
        crossLayer.fillColor = UIColor.clear.cgColor
        crossLayer.lineWidth = 2.5
        crossLayer.lineCap = .round
        layer.addSublayer(crossLayer)

        centerLayer.fillColor = UIColor.white.withAlphaComponent(0.98).cgColor
        centerLayer.shadowColor = UIColor.white.withAlphaComponent(0.44).cgColor
        centerLayer.shadowOpacity = 1
        centerLayer.shadowRadius = 9
        centerLayer.shadowOffset = .zero
        layer.addSublayer(centerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let aspect = UploadConfig.compositionDimensions.height / UploadConfig.compositionDimensions.width
        let maxGuideWidth = min(bounds.width * 0.9, 390)
        let maxGuideHeight = bounds.height * 0.8
        let guideWidth = min(maxGuideWidth, maxGuideHeight / aspect)
        let guideHeight = guideWidth * aspect
        let guideY = bounds.height * 0.51
        let frameRect = CGRect(
            x: (bounds.width - guideWidth) / 2,
            y: guideY - guideHeight / 2,
            width: guideWidth,
            height: guideHeight
        )

        let roundedPath = UIBezierPath(roundedRect: frameRect, cornerRadius: 32)
        let overlayPath = UIBezierPath(rect: bounds)
        overlayPath.append(roundedPath)
        overlayPath.usesEvenOddFillRule = true

        maskLayer.frame = bounds
        maskLayer.path = overlayPath.cgPath

        outlineLayer.frame = bounds
        outlineLayer.path = roundedPath.cgPath

        glowLayer.frame = bounds
        glowLayer.path = roundedPath.cgPath

        let cornersPath = Self.cornersPath(in: frameRect)
        cornersGlowLayer.frame = bounds
        cornersGlowLayer.path = cornersPath.cgPath
        cornersLayer.frame = bounds
        cornersLayer.path = cornersPath.cgPath

        let crossCenter = CGPoint(x: frameRect.midX, y: frameRect.midY)
        let crossPath = UIBezierPath()
        crossPath.move(to: CGPoint(x: crossCenter.x, y: frameRect.minY + guideHeight * 0.22))
        crossPath.addLine(to: CGPoint(x: crossCenter.x, y: frameRect.maxY - guideHeight * 0.22))
        crossPath.move(to: CGPoint(x: frameRect.minX + guideWidth * 0.31, y: crossCenter.y))
        crossPath.addLine(to: CGPoint(x: frameRect.maxX - guideWidth * 0.31, y: crossCenter.y))

        crossGlowLayer.frame = bounds
        crossGlowLayer.path = crossPath.cgPath
        crossLayer.frame = bounds
        crossLayer.path = crossPath.cgPath

        let centerRect = CGRect(x: crossCenter.x - 5, y: crossCenter.y - 5, width: 10, height: 10)
        centerLayer.frame = bounds
        centerLayer.path = UIBezierPath(ovalIn: centerRect).cgPath
    }

    private static func cornersPath(in rect: CGRect) -> UIBezierPath {
        let length = min(rect.width, rect.height) * 0.12
        let path = UIBezierPath()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))

        return path
    }
}

private final class InsetLabel: UILabel {
    var textInsets = UIEdgeInsets.zero

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}

private final class CameraCaptureModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    @Published var capturedImage: UIImage?
    @Published var errorMessage: String?
    @Published var isCaptureReady = false
    @Published var isCapturingPhoto = false
    @Published var authorizationDenied = false

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.yafa.camera.session")
    private var currentInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var isConfigured = false

    func start() {
        sessionQueue.async {
            self.prepareSession()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isCaptureReady = false
            }
        }
    }

    func clearCapture() {
        DispatchQueue.main.async {
            guard self.capturedImage != nil else { return }
            self.capturedImage = nil
            self.errorMessage = nil
        }
        sessionQueue.async {
            self.startSessionIfNeeded()
        }
    }

    func capturePhoto() {
        sessionQueue.async {
            guard !self.isCapturingPhoto else { return }
            guard !self.authorizationDenied else {
                DispatchQueue.main.async {
                    self.errorMessage = "Camera access is required to take a photo."
                }
                return
            }
            guard self.isConfigured else {
                self.prepareSession()
                DispatchQueue.main.async {
                    self.errorMessage = "Camera is still loading. Try again in a moment."
                }
                return
            }
            guard self.session.isRunning else {
                self.startSessionIfNeeded()
                DispatchQueue.main.async {
                    self.errorMessage = "Camera is still getting ready. Try again."
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            DispatchQueue.main.async {
                self.errorMessage = nil
                self.isCapturingPhoto = true
            }
            self.configureVideoConnection()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.errorMessage = error.localizedDescription
            }
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.errorMessage = "Could not capture photo."
            }
            return
        }

        DispatchQueue.main.async {
            self.capturedImage = image
            self.isCapturingPhoto = false
            self.isCaptureReady = false
            self.errorMessage = nil
        }
        sessionQueue.async {
            self.session.stopRunning()
        }
    }

    private func prepareSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSessionIfNeeded()
            startSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.sessionQueue.async {
                    if granted {
                        self.configureSessionIfNeeded()
                        self.startSessionIfNeeded()
                    } else {
                        DispatchQueue.main.async {
                            self.authorizationDenied = true
                            self.isCaptureReady = false
                            self.isCapturingPhoto = false
                            self.errorMessage = "Camera access is required to take a photo."
                        }
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.authorizationDenied = true
                self.isCaptureReady = false
                self.isCapturingPhoto = false
                self.errorMessage = "Camera access is required to take a photo."
            }
        @unknown default:
            DispatchQueue.main.async {
                self.authorizationDenied = true
                self.isCaptureReady = false
                self.isCapturingPhoto = false
                self.errorMessage = "Camera unavailable."
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let input = makeInput(for: currentPosition), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.errorMessage = "Camera unavailable."
                self.isCaptureReady = false
                self.isCapturingPhoto = false
            }
            return
        }

        session.addInput(input)
        currentInput = input

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.errorMessage = "Camera unavailable."
                self.isCaptureReady = false
                self.isCapturingPhoto = false
            }
            return
        }

        session.addOutput(photoOutput)
        configureVideoConnection()
        session.commitConfiguration()

        isConfigured = true
        DispatchQueue.main.async {
            self.authorizationDenied = false
            self.errorMessage = nil
            self.isCapturingPhoto = false
        }
    }

    private func startSessionIfNeeded() {
        guard !session.isRunning else { return }
        session.startRunning()
        DispatchQueue.main.async {
            self.isCaptureReady = self.session.isRunning
            if self.session.isRunning {
                self.errorMessage = nil
            }
        }
    }

    private func makeInput(for position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )

        guard let device = discovery.devices.first else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }

    private func configureVideoConnection() {
        guard let connection = photoOutput.connection(with: .video) else { return }

        let portraitRotationAngle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(portraitRotationAngle) {
            connection.videoRotationAngle = portraitRotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = currentPosition == .front
        }
    }
}

private actor UploadWeatherService {
    static let shared = UploadWeatherService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    func fetchCurrentWeather() async -> Weather? {
        do {
            let location = try await UploadLocationCoordinator().requestLocation()
            return try await fetchWeather(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        } catch {
            return nil
        }
    }

    private func fetchWeather(latitude: CLLocationDegrees, longitude: CLLocationDegrees) async throws -> Weather {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]

        guard let url = components?.url else {
            throw UploadWeatherServiceError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw UploadWeatherServiceError.invalidResponse
        }

        let forecast = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
        let tempC = Int(forecast.current.temperature2m.rounded())
        let tempF = Int((forecast.current.temperature2m * 9 / 5 + 32).rounded())
        let condition = mapCondition(
            code: forecast.current.weatherCode,
            isDay: forecast.current.isDay == 1,
            windSpeed: forecast.current.windSpeed10m,
            temperatureC: tempC
        )

        return Weather(tempF: tempF, tempC: tempC, condition: condition)
    }

    private func mapCondition(
        code: Int,
        isDay: Bool,
        windSpeed: Double,
        temperatureC: Int
    ) -> String {
        if (95 ... 99).contains(code) { return "Stormy" }
        if (71 ... 77).contains(code) || (85 ... 86).contains(code) { return "Snowy" }
        if (51 ... 67).contains(code) || (80 ... 82).contains(code) { return "Rainy" }

        if windSpeed >= 32 {
            return "Windy"
        }
        if windSpeed >= 20 {
            return "Breezy"
        }

        switch code {
        case 0:
            return isDay ? "Sunny" : "Clear"
        case 1, 2:
            return "Partly Cloudy"
        case 3, 45, 48:
            return "Cloudy"
        default:
            return "Cloudy"
        }
    }

    private struct OpenMeteoForecast: Decodable {
        let current: Current
    }

    private struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int
        let isDay: Int
        let windSpeed10m: Double

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
            case windSpeed10m = "wind_speed_10m"
        }
    }
}

@MainActor
private final class UploadLocationCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                resume(with: .failure(UploadWeatherServiceError.locationUnavailable))
            @unknown default:
                resume(with: .failure(UploadWeatherServiceError.locationUnavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            resume(with: .failure(UploadWeatherServiceError.locationUnavailable))
        case .notDetermined:
            break
        @unknown default:
            resume(with: .failure(UploadWeatherServiceError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            resume(with: .failure(UploadWeatherServiceError.locationUnavailable))
            return
        }
        resume(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private enum UploadWeatherServiceError: Error {
    case invalidRequest
    case invalidResponse
    case locationUnavailable
}

import SwiftUI

/// Displays an outfit frame. If `draggable`, horizontal drag rotates through frames.
struct RotatableOutfitImage: View {
    let outfit: Outfit
    var height: CGFloat = FrameConfig.dimensions.height
    var draggable: Bool = false
    var eagerLoad: Bool = false
    var autoRotate: Bool = false
    var playEntranceSequence: Bool = false
    var entranceSequenceActive: Bool = false
    var entranceSequenceDelay: Double = 0
    var preloadFullSequenceOnAppear: Bool = false
    var initialFrameIndex: Int? = nil
    var initialImage: UIImage? = nil
    var syncFrameIndex: Int? = nil
    var syncImage: UIImage? = nil
    var onTapStateCapture: ((Int, UIImage?) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onHorizontalDragChange: ((Bool) -> Void)? = nil
    var onFrameChange: ((Int) -> Void)? = nil
    var onDisplayedFrameChange: ((Int?) -> Void)? = nil
    /// Pulls the drag/tap surface inwards from the left and right edges
    /// so horizontal swipes near the edges fall through to whatever is
    /// behind (e.g. a parent carousel). Default 0 = full-width hit area.
    var horizontalDragInset: CGFloat = 0

    @State private var viewModel: FrameSequenceViewModel
    @State private var thumbnail: UIImage?
    @State private var hasLoadedFrames = false
    @State private var hasStartedDrag = false
    @State private var isPreparingSequence = false
    @State private var isSequenceReady = false
    @State private var hasPlayedEntranceSequence = false
    @State private var entranceTask: Task<Void, Never>?

    init(
        outfit: Outfit,
        height: CGFloat = FrameConfig.dimensions.height,
        draggable: Bool = false,
        eagerLoad: Bool = false,
        autoRotate: Bool = false,
        playEntranceSequence: Bool = false,
        entranceSequenceActive: Bool = false,
        entranceSequenceDelay: Double = 0,
        preloadFullSequenceOnAppear: Bool = false,
        initialFrameIndex: Int? = nil,
        initialImage: UIImage? = nil,
        syncFrameIndex: Int? = nil,
        syncImage: UIImage? = nil,
        onTapStateCapture: ((Int, UIImage?) -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        onHorizontalDragChange: ((Bool) -> Void)? = nil,
        onFrameChange: ((Int) -> Void)? = nil,
        onDisplayedFrameChange: ((Int?) -> Void)? = nil,
        horizontalDragInset: CGFloat = 0
    ) {
        self.outfit = outfit
        self.height = height
        self.draggable = draggable
        self.eagerLoad = eagerLoad
        self.autoRotate = autoRotate
        self.playEntranceSequence = playEntranceSequence
        self.entranceSequenceActive = entranceSequenceActive
        self.entranceSequenceDelay = entranceSequenceDelay
        self.preloadFullSequenceOnAppear = preloadFullSequenceOnAppear
        self.initialFrameIndex = initialFrameIndex
        self.initialImage = initialImage
        self.syncFrameIndex = syncFrameIndex
        self.syncImage = syncImage
        self.onTapStateCapture = onTapStateCapture
        self.onTap = onTap
        self.onHorizontalDragChange = onHorizontalDragChange
        self.onFrameChange = onFrameChange
        self.onDisplayedFrameChange = onDisplayedFrameChange
        self.horizontalDragInset = horizontalDragInset
        self._viewModel = State(
            initialValue: FrameSequenceViewModel(
                outfit: outfit,
                initialFrame: initialFrameIndex ?? 0,
                initialImage: initialImage
            )
        )

        if initialImage != nil {
            self._thumbnail = State(initialValue: nil)
        } else {
            let previewImage: UIImage? =
                (initialFrameIndex ?? 0) == 0 && outfit.resolvedRemoteBaseURL == nil
                    ? LocalOutfitStore.shared.previewImage(for: outfit)
                    : nil
            self._thumbnail = State(initialValue: previewImage)
        }
    }

    private var displayImage: UIImage? {
        viewModel.displayedImage ?? thumbnail
    }

    var body: some View {
        ZStack {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height)
        .contentShape(Rectangle())
        .overlay {
            if draggable || onTap != nil {
                InteractiveTouchSurface(
                    onTap: handleTap,
                    panEnabled: draggable,
                    onHorizontalPanBegan: draggable ? startDragIfNeeded : nil,
                    onHorizontalPanChanged: draggable ? { delta in
                        viewModel.dragChanged(delta: delta)
                    } : nil,
                    onHorizontalPanEnded: draggable ? {
                        viewModel.dragEnded()
                        endDragIfNeeded()
                    } : nil
                )
                .padding(.horizontal, horizontalDragInset)
            }
        }
        .onAppear {
            if (eagerLoad || autoRotate || draggable || playEntranceSequence) && !hasLoadedFrames {
                hasLoadedFrames = true
                viewModel.ensureCurrentFrameLoaded()
            }
            if draggable || autoRotate || preloadFullSequenceOnAppear || playEntranceSequence {
                synchronizeSequenceState(
                    preloadIfNeeded: autoRotate || preloadFullSequenceOnAppear || playEntranceSequence
                )
            }
            syncDisplayedFrameIfNeeded(force: true)
            onFrameChange?(viewModel.currentFrame)
            onDisplayedFrameChange?(viewModel.displayedFrame)
            triggerEntranceIfNeeded(applyDelay: true)
        }
        .onChange(of: eagerLoad) { _, eager in
            if eager && !hasLoadedFrames {
                hasLoadedFrames = true
                viewModel.ensureCurrentFrameLoaded()
            }
        }
        .onChange(of: draggable) { _, isDraggable in
            if isDraggable && viewModel.displayedImage == nil {
                viewModel.loadCurrentFrame()
            }
        }
        .onChange(of: viewModel.currentFrame) { _, frame in
            onFrameChange?(frame)
        }
        .onChange(of: viewModel.displayedFrame) { _, frame in
            onDisplayedFrameChange?(frame)
        }
        .onChange(of: draggable) { _, isDraggable in
            guard isDraggable else { return }
            synchronizeSequenceState(
                preloadIfNeeded: autoRotate || preloadFullSequenceOnAppear || playEntranceSequence
            )
        }
        .onChange(of: preloadFullSequenceOnAppear) { _, shouldPreload in
            guard shouldPreload else { return }
            synchronizeSequenceState(preloadIfNeeded: true)
        }
        .onChange(of: syncFrameIndex) { _, _ in
            syncDisplayedFrameIfNeeded()
        }
        .onChange(of: entranceSequenceActive) { _, isActive in
            guard isActive else {
                entranceTask?.cancel()
                return
            }
            triggerEntranceIfNeeded(applyDelay: true)
        }
        .onDisappear {
            entranceTask?.cancel()
            endDragIfNeeded()
            viewModel.stopAutoRotate()
            viewModel.stopAnimationLoop()
        }
    }

    private func startDragIfNeeded() {
        if !isSequenceReady {
            prepareSequenceIfNeeded()
        }

        if !hasStartedDrag {
            hasStartedDrag = true
            onHorizontalDragChange?(true)
            viewModel.dragBegan()
        }
    }

    private func endDragIfNeeded() {
        guard hasStartedDrag else { return }
        hasStartedDrag = false
        onHorizontalDragChange?(false)
    }

    private func prepareSequenceIfNeeded() {
        guard !isSequenceReady, !isPreparingSequence else {
            if autoRotate, isSequenceReady {
                viewModel.startAutoRotate()
            }
            triggerEntranceIfNeeded(applyDelay: false)
            return
        }

        isPreparingSequence = true

        Task {
            let didLoadSequence = await FrameLoader.shared.preloadFullSequence(for: outfit)
            await MainActor.run {
                isPreparingSequence = false
                isSequenceReady = didLoadSequence

                if didLoadSequence {
                    if !hasLoadedFrames {
                        hasLoadedFrames = true
                        viewModel.ensureCurrentFrameLoaded()
                    }
                    if autoRotate {
                        viewModel.startAutoRotate()
                    }
                    triggerEntranceIfNeeded(applyDelay: false)
                }
            }
        }
    }

    private func synchronizeSequenceState(preloadIfNeeded: Bool) {
        Task { @MainActor in
            isSequenceReady = await FrameLoader.shared.hasFullSequence(for: outfit)
            triggerEntranceIfNeeded(applyDelay: true)

            guard preloadIfNeeded else { return }
            prepareSequenceIfNeeded()
        }
    }

    private func triggerEntranceIfNeeded(applyDelay: Bool) {
        guard playEntranceSequence, entranceSequenceActive, isSequenceReady, !hasPlayedEntranceSequence else {
            return
        }

        hasPlayedEntranceSequence = true
        entranceTask?.cancel()

        entranceTask = Task { @MainActor in
            if applyDelay, entranceSequenceDelay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(entranceSequenceDelay * 1000)))
            }
            guard !Task.isCancelled else { return }
            viewModel.startEntrance()
        }
    }

    private func syncDisplayedFrameIfNeeded(force: Bool = false) {
        guard let syncFrameIndex else { return }
        guard force || syncFrameIndex != viewModel.currentFrame else { return }
        viewModel.setFrame(syncFrameIndex, image: syncImage)
        hasLoadedFrames = true
        onDisplayedFrameChange?(syncImage == nil ? nil : syncFrameIndex)
    }

    private func handleTap() {
        let frozenState = currentRenderedState()
        let frozenFrame = frozenState.frame
        let frozenImage = frozenState.image

        endDragIfNeeded()
        viewModel.stopAutoRotate()
        viewModel.stopAnimationLoop()
        viewModel.setFrame(frozenFrame, image: frozenImage)
        onFrameChange?(frozenFrame)
        onTapStateCapture?(frozenFrame, frozenImage)
        onTap?()
    }

    private func currentRenderedState() -> (frame: Int, image: UIImage?) {
        if let displayedFrame = viewModel.displayedFrame {
            return (displayedFrame, viewModel.displayedImage)
        }

        if let thumbnail {
            return (0, thumbnail)
        }

        return (viewModel.currentFrame, viewModel.displayedImage)
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

import SwiftUI

/// Displays an outfit frame. If `draggable`, horizontal drag rotates through frames.
/// Drag is silently ignored for 2D outfits (frameCount <= 1) so call sites
/// don't have to gate every call.
struct RotatableOutfitImage: View {
    let outfit: Outfit
    var height: CGFloat = FrameConfig.dimensions.height
    private let requestedDraggable: Bool
    var draggable: Bool { requestedDraggable && outfit.frameCount > 1 }
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
    /// Fires at the end of a scrub drag with the full release info
    /// (total translation, excursion range, derived monotonicity).
    /// Carousel-style parents use it to discriminate scrubs (low
    /// monotonicity, even if total is large) from page swipes (high
    /// monotonicity AND large absolute total).
    var onHorizontalDragRelease: ((HorizontalPanRelease) -> Void)? = nil

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
        horizontalDragInset: CGFloat = 0,
        onHorizontalDragRelease: ((HorizontalPanRelease) -> Void)? = nil
    ) {
        self.outfit = outfit
        self.height = height
        self.requestedDraggable = draggable
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
        self.onHorizontalDragRelease = onHorizontalDragRelease
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
            if draggable || onTap != nil || onTapStateCapture != nil {
                InteractiveTouchSurface(
                    onTap: handleTap,
                    panEnabled: draggable,
                    onHorizontalPanBegan: draggable ? startDragIfNeeded : nil,
                    onHorizontalPanChanged: draggable ? { delta in
                        viewModel.dragChanged(delta: delta)
                    } : nil,
                    onHorizontalPanEnded: draggable ? { release in
                        viewModel.dragEnded()
                        endDragIfNeeded()
                        onHorizontalDragRelease?(release)
                    } : nil
                )
                .padding(.horizontal, horizontalDragInset)
            }
        }
        .onAppear {
            // Always make sure the visible frame is loaded for the
            // current cell. `ensureCurrentFrameLoaded` is idempotent
            // (no-op when `displayedImage` is set), so it's safe to
            // call on every appear. Without this, 2D outfits (and any
            // cell mounted after another view already cached the full
            // sequence) stay blank: `synchronizeSequenceState` early-
            // returns when `isSequenceReady` is true and never triggers
            // the per-cell frame load. LazyVGrid mounts only visible
            // cells so this isn't wasteful.
            hasLoadedFrames = true
            viewModel.ensureCurrentFrameLoaded()
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
        .onChange(of: autoRotate) { _, rotate in
            // Auto-rotation can be promoted/demoted at runtime —
            // e.g. a carousel where only the centered outfit spins.
            // Appear-time wiring alone would leave a newly-centered
            // outfit static (the param changes but no one re-kicks
            // the sequence), so react to the flag directly.
            if rotate {
                synchronizeSequenceState(preloadIfNeeded: true)
            } else {
                viewModel.stopAutoRotate()
            }
        }
        .onChange(of: syncFrameIndex) { _, _ in
            syncDisplayedFrameIfNeeded()
        }
        .onChange(of: outfit.isRotationReversed) { _, _ in
            // Push the updated outfit into the viewModel so
            // `resolvedFrameIndex` picks up the new direction
            // immediately. The viewModel's outfit is initialised once
            // in @State; without this sync the review-card "Reverse"
            // toggle has no visible effect until the cell is remounted.
            viewModel.outfit = outfit
            viewModel.loadCurrentFrame()
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

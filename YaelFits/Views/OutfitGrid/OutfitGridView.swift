import SwiftUI
import UIKit

struct OutfitGridView: View {
    @Environment(OutfitStore.self) private var store
    @State private var contentVisible = false
    @State private var playsInitialSequence = false
    @State private var dragHintVisible = true
    @State private var outfitFrames: [String: CGRect] = [:]
    @State private var outfitFrameIndices: [String: Int] = [:]
    @State private var outfitFrameImages: [String: UIImage] = [:]
    @State private var showCarousel = false
    @State private var carouselBackdropVisible = false
    @State private var carouselChromeVisible = false
    @State private var carouselIndex = 0
    @State private var activeCarouselFrameIndex = 0
    @State private var activeCarouselDisplayedFrame: Int?
    @State private var isScrubbing = false
    @State private var heroTransition: HeroTransition?
    @State private var heroOpacity: Double = 1
    @State private var showCurrentCarouselLiveSlide = false
    @State private var showCarouselEntryOverlay = false
    @State private var revealGridOutfitIdDuringHero: String?
    @State private var carouselEntryFrame: CarouselEntryFrame?
    @State private var carouselEntryImage: UIImage?
    @State private var heroFrame: CGRect = .zero
    @State private var carouselTargetFrame: CGRect = .null
    @State private var entranceTask: Task<Void, Never>?
    @State private var carouselTransitionTask: Task<Void, Never>?
    private var displayedOutfits: [Outfit] {
        guard let tag = store.activeTagFilter else { return store.sortedOutfits }
        return store.sortedOutfits.filter { $0.tags?.contains(tag) == true }
    }

    private let heroTransitionDuration: Double = 0.32
    private let heroFadeInDuration: Double = 0.12
    private let heroFadeOutDuration: Double = 0.08
    private let carouselBackdropFadeInDuration: Double = 0.22
    private let carouselBackdropFadeOutDuration: Double = 0.12
    private let carouselChromeFadeInDuration: Double = 0.28
    private let carouselChromeFadeOutDuration: Double = 0.1
    private let initialVisibleCount = 9
    private let columns = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
    ]

    var body: some View {
        ScrollViewReader { reader in
            GeometryReader { geometry in
                let viewportFrame = geometry.frame(in: .global)
                let heroDisplayFrame = displayedHeroFrame(in: viewportFrame)

                ZStack {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: LayoutMetrics.listTopInset)

                            if !displayedOutfits.isEmpty {
                                dragHint
                                    .padding(.top, 28)
                                    .padding(.bottom, 34)
                                    .blurFadeReveal(active: contentVisible, delay: 0.06, blurRadius: 10)
                            }

                            outfitsGrid

                            Color.clear
                                .frame(height: LayoutMetrics.floatingControlsInset)
                        }
                        .padding(.horizontal, LayoutMetrics.small)
                    }
                    .compositingGroup()
                    .scrollDisabled(isScrubbing || showCarousel)
                    .allowsHitTesting(!showCarousel)
                    .overlay {
                        if displayedOutfits.isEmpty {
                            emptyStatePrompt
                                .blurFadeReveal(active: contentVisible, delay: 0.06, blurRadius: 10)
                        }
                    }

                    if showCarousel {
                        CarouselView(
                            outfits: displayedOutfits,
                            currentIndex: $carouselIndex,
                            backdropOpacity: carouselBackdropVisible ? 1 : 0,
                            showsChrome: carouselChromeVisible,
                            showsCurrentLiveSlide: showCurrentCarouselLiveSlide,
                            showsEntryOverlay: showCarouselEntryOverlay,
                            entryFrame: carouselEntryFrame,
                            entryImage: carouselEntryImage,
                            onHeroTargetFrameChange: { frame in
                                carouselTargetFrame = frame
                            },
                            onCurrentFrameChange: { frameIndex in
                                activeCarouselFrameIndex = frameIndex
                                if let entryFrame = carouselEntryFrame,
                                   displayedOutfits[safe: carouselIndex]?.id == entryFrame.outfitId,
                                   frameIndex != entryFrame.frameIndex {
                                    hideCarouselEntryOverlay()
                                }
                            },
                            onCurrentDisplayedFrameChange: { frameIndex in
                                activeCarouselDisplayedFrame = frameIndex
                            },
                            onCurrentScrubBegan: {
                                hideCarouselEntryOverlay()
                            },
                            onDeleteOutfit: { outfit in
                                deleteCarouselOutfit(outfit)
                            },
                            onDismiss: {
                                dismissCarousel(using: reader)
                            }
                        )
                        .compositingGroup()
                        .zIndex(1)
                    }

                    if let heroTransition, !heroDisplayFrame.isNull {
                        HeroOutfitImageView(
                            outfit: heroTransition.outfit,
                            frameIndex: heroTransition.frameIndex,
                            initialImage: heroTransition.image
                        )
                            .opacity(heroOpacity)
                            .frame(width: heroDisplayFrame.width, height: heroDisplayFrame.height)
                            .position(x: heroDisplayFrame.midX, y: heroDisplayFrame.midY)
                            .allowsHitTesting(false)
                            .zIndex(2)
                    }
                }
                .onPreferenceChange(ListOutfitFramePreferenceKey.self) { frames in
                    outfitFrames = frames
                    store.listOutfitFrames = frames
                    updateCenteredOutfit(from: frames, viewportFrame: viewportFrame)
                }
            }
            .onAppear {
                prepareEntrance()
            }
            .onChange(of: store.activeTagFilter) { _, _ in
                carouselIndex = 0
            }
            .onChange(of: store.isLoading) { _, isLoading in
                guard !showCarousel else { return }
                if isLoading {
                    resetEntranceState()
                } else {
                    startEntrance(after: AppConfig.loaderFadeDuration + AppConfig.listEntranceDelayAfterLoader)
                }
            }
            .onChange(of: showCarousel) { _, isShowing in
                guard isShowing else { return }
                Task { @MainActor in
                    await syncGridToCarouselSelection(using: reader)
                }
            }
            .onChange(of: carouselIndex) { _, _ in
                guard showCarousel else { return }
                Task { @MainActor in
                    await syncGridToCarouselSelection(using: reader)
                }
            }
            .onDisappear {
                entranceTask?.cancel()
                carouselTransitionTask?.cancel()
            }
        }
    }

    /// Fixed pattern: [1, 3, 2, 2, 1, 3, 3, 2, 1] — looks random but is stable
    private static let placeholderPattern = [1, 3, 2, 2, 1, 3, 3, 2, 1]

    private var outfitsGrid: some View {
        LazyVGrid(columns: columns, spacing: 42) {
            ForEach(Array(displayedOutfits.enumerated()), id: \.element.id) { index, outfit in
                gridItem(outfit: outfit, index: index)
            }
        }
    }

    private func placeholderCard(index: Int) -> some View {
        let imageNumber = Self.placeholderPattern[index % Self.placeholderPattern.count]
        let resourceName = "placeholder-\(imageNumber)"

        return Group {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: "webp"),
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
                    .aspectRatio(FrameConfig.dimensions.width / FrameConfig.dimensions.height, contentMode: .fit)
            }
        }
        .opacity(0.03)
        .blurFadeReveal(active: contentVisible, delay: revealDelay(for: index))
    }

    private func gridItem(outfit: Outfit, index: Int) -> some View {
        OutfitCardView(
            outfit: outfit,
            eagerLoad: index < initialVisibleCount,
            playEntranceSequence: playsInitialSequence && index < initialVisibleCount,
            entranceSequenceActive: contentVisible,
            entranceSequenceDelay: revealDelay(for: index),
            syncFrameIndex: outfitFrameIndices[outfit.id],
            syncImage: outfitFrameImages[outfit.id],
            onTap: { frameIndex, image in
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                presentCarousel(for: outfit, at: index, frameIndex: frameIndex, image: image)
            },
            onHorizontalDragChange: { isDragging in
                isScrubbing = isDragging
                if isDragging {
                    dragHintVisible = false
                }
            },
            onFrameChange: { _ in
                // Intentionally not tracking frame index during rotation —
                // doing so triggers a grid re-render per frame across all
                // visible cards, causing jitter when many outfits are visible.
                // The carousel receives the correct frame via onTap.
            }
        )
        .blurFadeReveal(active: contentVisible, delay: revealDelay(for: index))
        .headerProximityFade(headerBottom: 68, fadeZone: 80)
        .gridTransitionReveal(
            phase: store.viewTransitionPhase,
            isList: store.currentView == .list,
            staggerIndex: index
        )
        .id(outfit.id)
        .opacity(
            (heroTransition?.outfit.id == outfit.id && revealGridOutfitIdDuringHero != outfit.id)
                || store.heroAnchorOutfitId == outfit.id
                ? 0.001
                : 1
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ListOutfitFramePreferenceKey.self,
                    value: [outfit.id: proxy.frame(in: .global)]
                )
            }
        }
    }

    private var emptyStatePrompt: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.currentView = .upload
        } label: {
            HStack(spacing: 6) {
                AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.textPrimary)
                Text("CREATE YOUR FIRST OUTFIT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
            }
            .frame(height: 48)
            .padding(.horizontal, 28)
            .appCapsule(shadowRadius: 8, shadowY: 4)
        }
        .buttonStyle(.plain)
    }

    private var dragHint: some View {
        Text("DRAG TO ROTATE")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
            .opacity(dragHintVisible && !showCarousel ? 1 : 0)
            .frame(maxWidth: .infinity)
    }

    private func prepareEntrance() {
        if store.isLoading {
            resetEntranceState()
        } else {
            startEntrance()
        }
    }

    private func resetEntranceState() {
        entranceTask?.cancel()
        contentVisible = false
        playsInitialSequence = false
        dragHintVisible = true
        showCarousel = false
        carouselBackdropVisible = false
        carouselChromeVisible = false
        isScrubbing = false
        heroTransition = nil
        heroOpacity = 1
        showCurrentCarouselLiveSlide = false
        showCarouselEntryOverlay = false
        revealGridOutfitIdDuringHero = nil
        carouselEntryFrame = nil
        carouselEntryImage = nil
        activeCarouselFrameIndex = 0
        activeCarouselDisplayedFrame = nil
        heroFrame = .zero
        carouselTargetFrame = .null
        store.selectedOutfitId = nil
    }

    private func startEntrance(after delay: Double = 0) {
        entranceTask?.cancel()
        resetEntranceState()
        playsInitialSequence = !store.hasPlayedInitialListEntrance

        entranceTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            contentVisible = true
            if playsInitialSequence {
                store.hasPlayedInitialListEntrance = true
            }
        }
    }

    private func revealDelay(for index: Int) -> Double {
        Double(min(index, initialVisibleCount - 1)) * 0.05
    }

    private func presentCarousel(for outfit: Outfit, at index: Int, frameIndex: Int, image: UIImage?) {
        carouselTransitionTask?.cancel()
        let entryFrameIndex = frameIndex
        carouselTransitionTask = Task { @MainActor in
            let entryImage: UIImage?
            if let image {
                entryImage = image
            } else {
                entryImage = await FrameLoader.shared.frame(for: outfit, index: entryFrameIndex)
            }
            guard !Task.isCancelled else { return }

            carouselIndex = index
            store.selectedOutfitId = outfit.id
            activeCarouselFrameIndex = entryFrameIndex
            activeCarouselDisplayedFrame = nil
            heroOpacity = 1
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            revealGridOutfitIdDuringHero = nil
            outfitFrameIndices[outfit.id] = entryFrameIndex
            if let entryImage {
                outfitFrameImages[outfit.id] = entryImage
            }
            carouselEntryFrame = CarouselEntryFrame(outfitId: outfit.id, frameIndex: entryFrameIndex)
            carouselEntryImage = entryImage
            carouselChromeVisible = false
            carouselTargetFrame = .null

            guard let sourceFrame = outfitFrames[outfit.id] else {
                showCarousel = true
                heroTransition = nil
                showCurrentCarouselLiveSlide = true
                withAnimation(.easeInOut(duration: carouselBackdropFadeInDuration)) {
                    carouselBackdropVisible = true
                }
                _ = await waitForCarouselDisplayedFrame(entryFrameIndex, outfitId: outfit.id)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: carouselChromeFadeInDuration)) {
                    carouselChromeVisible = true
                }
                return
            }

            heroTransition = HeroTransition(outfit: outfit, frameIndex: entryFrameIndex, image: entryImage)
            heroFrame = sourceFrame
            showCarousel = true
            withAnimation(.easeInOut(duration: carouselBackdropFadeInDuration)) {
                carouselBackdropVisible = true
            }

            let targetFrame = await waitForCarouselTargetFrame(fallback: sourceFrame)
            guard !Task.isCancelled else { return }

            withAnimation(.timingCurve(0.22, 0.84, 0.18, 1, duration: heroTransitionDuration)) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            _ = await waitForCarouselDisplayedFrame(entryFrameIndex, outfitId: outfit.id)
            guard !Task.isCancelled else { return }

            showCurrentCarouselLiveSlide = true
            withAnimation(.easeOut(duration: heroFadeInDuration)) {
                showCarouselEntryOverlay = carouselEntryImage != nil
                heroOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(Int(heroFadeInDuration * 1000)))
            guard !Task.isCancelled else { return }

            heroTransition = nil
            heroOpacity = 1

            withAnimation(.easeInOut(duration: carouselChromeFadeInDuration)) {
                carouselChromeVisible = true
            }
        }
    }

    private func dismissCarousel(using reader: ScrollViewProxy) {
        carouselTransitionTask?.cancel()

        guard
            showCarousel,
            let currentOutfit = displayedOutfits[safe: carouselIndex]
        else {
            showCarousel = false
            heroTransition = nil
            carouselBackdropVisible = false
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            carouselEntryFrame = nil
            carouselEntryImage = nil
            carouselTargetFrame = .null
            activeCarouselFrameIndex = 0
            activeCarouselDisplayedFrame = nil
            store.selectedOutfitId = nil
            return
        }

        let startFrame = carouselTargetFrame.isNull ? heroFrame : carouselTargetFrame
        let exitFrameIndex = activeCarouselDisplayedFrame ?? activeCarouselFrameIndex

        carouselTransitionTask = Task { @MainActor in
            await syncGridToCarouselSelection(using: reader)
            let targetFrame = outfitFrames[currentOutfit.id]
            let exitImage = await FrameLoader.shared.frame(for: currentOutfit, index: exitFrameIndex)
            guard !Task.isCancelled else { return }

            heroOpacity = 1
            revealGridOutfitIdDuringHero = nil
            outfitFrameIndices[currentOutfit.id] = exitFrameIndex
            if let exitImage {
                outfitFrameImages[currentOutfit.id] = exitImage
            }

            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            withAnimation(.easeInOut(duration: carouselChromeFadeOutDuration)) {
                carouselChromeVisible = false
            }
            withAnimation(.easeInOut(duration: carouselBackdropFadeOutDuration)) {
                carouselBackdropVisible = false
            }

            guard let targetFrame else {
                try? await Task.sleep(for: .milliseconds(Int(carouselBackdropFadeOutDuration * 1000)))
                guard !Task.isCancelled else { return }
                showCarousel = false
                heroTransition = nil
                heroOpacity = 1
                revealGridOutfitIdDuringHero = nil
                showCurrentCarouselLiveSlide = false
                showCarouselEntryOverlay = false
                carouselEntryFrame = nil
                carouselEntryImage = nil
                carouselTargetFrame = .null
                activeCarouselFrameIndex = 0
                activeCarouselDisplayedFrame = nil
                carouselBackdropVisible = false
                store.selectedOutfitId = nil
                return
            }

            heroTransition = HeroTransition(outfit: currentOutfit, frameIndex: exitFrameIndex, image: exitImage)
            heroFrame = startFrame

            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(.timingCurve(0.22, 0.84, 0.18, 1, duration: heroTransitionDuration)) {
                heroFrame = targetFrame
            }

            try? await Task.sleep(for: .milliseconds(Int(heroTransitionDuration * 1000)))
            guard !Task.isCancelled else { return }

            showCarousel = false
            revealGridOutfitIdDuringHero = currentOutfit.id

            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: heroFadeOutDuration)) {
                heroOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(Int(heroFadeOutDuration * 1000)))
            guard !Task.isCancelled else { return }

            heroTransition = nil
            heroOpacity = 1
            revealGridOutfitIdDuringHero = nil
            showCurrentCarouselLiveSlide = false
            showCarouselEntryOverlay = false
            carouselEntryFrame = nil
            carouselEntryImage = nil
            carouselTargetFrame = .null
            activeCarouselFrameIndex = 0
            activeCarouselDisplayedFrame = nil
            carouselBackdropVisible = false
            store.selectedOutfitId = nil
        }
    }

    @MainActor
    private func syncGridToCarouselSelection(using reader: ScrollViewProxy) async {
        guard let outfitId = displayedOutfits[safe: carouselIndex]?.id else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            reader.scrollTo(outfitId, anchor: .center)
        }
        await Task.yield()
        await Task.yield()
    }

    @MainActor
    private func waitForCarouselTargetFrame(fallback: CGRect) async -> CGRect {
        for _ in 0 ..< 30 {
            if !carouselTargetFrame.isNull {
                return carouselTargetFrame
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return fallback
    }

    @MainActor
    private func waitForCarouselDisplayedFrame(_ frameIndex: Int, outfitId: String) async -> Bool {
        for _ in 0 ..< 24 {
            if displayedOutfits[safe: carouselIndex]?.id == outfitId,
               activeCarouselDisplayedFrame == frameIndex {
                return true
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }

    private func displayedHeroFrame(in viewportFrame: CGRect) -> CGRect {
        guard heroTransition != nil else { return .null }
        return CGRect(
            x: heroFrame.minX - viewportFrame.minX,
            y: heroFrame.minY - viewportFrame.minY,
            width: heroFrame.width,
            height: heroFrame.height
        )
    }

    private func hideCarouselEntryOverlay() {
        guard showCarouselEntryOverlay else { return }
        withAnimation(.easeOut(duration: heroFadeOutDuration)) {
            showCarouselEntryOverlay = false
        }
    }

    private func deleteCarouselOutfit(_ outfit: Outfit) {
        carouselTransitionTask?.cancel()
        showCarousel = false
        carouselBackdropVisible = false
        carouselChromeVisible = false
        isScrubbing = false
        heroTransition = nil
        heroOpacity = 1
        showCurrentCarouselLiveSlide = false
        showCarouselEntryOverlay = false
        revealGridOutfitIdDuringHero = nil
        carouselEntryFrame = nil
        carouselEntryImage = nil
        heroFrame = .zero
        carouselTargetFrame = .null
        activeCarouselFrameIndex = 0
        activeCarouselDisplayedFrame = nil
        carouselIndex = min(carouselIndex, max(displayedOutfits.count - 2, 0))
        store.selectedOutfitId = nil
        store.deleteOutfit(outfit)
    }

    private func updateCenteredOutfit(from frames: [String: CGRect], viewportFrame: CGRect) {
        guard !frames.isEmpty, !showCarousel, store.currentView == .list else { return }

        let visibleViewport = CGRect(
            x: viewportFrame.minX,
            y: viewportFrame.minY,
            width: viewportFrame.width,
            height: max(0, viewportFrame.height - LayoutMetrics.bottomOverlayInset)
        )
        let viewportCenter = CGPoint(x: visibleViewport.midX, y: visibleViewport.midY)

        let nearestOutfitId = frames
            .filter { $0.value.intersects(visibleViewport) }
            .min { lhs, rhs in
                distanceSquared(from: lhs.value.center, to: viewportCenter)
                    < distanceSquared(from: rhs.value.center, to: viewportCenter)
            }?
            .key

        guard let nearestOutfitId else { return }
        if store.centeredListOutfitId != nearestOutfitId {
            store.centeredListOutfitId = nearestOutfitId
        }
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

}

private struct HeroTransition {
    let outfit: Outfit
    let frameIndex: Int
    let image: UIImage?
}

struct CarouselEntryFrame: Equatable {
    let outfitId: String
    let frameIndex: Int
}

private struct HeroOutfitImageView: View {
    let outfit: Outfit
    let frameIndex: Int
    let initialImage: UIImage?
    @State private var image: UIImage?

    init(outfit: Outfit, frameIndex: Int, initialImage: UIImage?) {
        self.outfit = outfit
        self.frameIndex = frameIndex
        self.initialImage = initialImage

        if let initialImage {
            _image = State(initialValue: initialImage)
        } else {
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: "\(outfit.id)-\(frameIndex)") {
            guard initialImage == nil else { return }
            image = await FrameLoader.shared.frame(for: outfit, index: frameIndex)
        }
    }
}

private struct ListOutfitFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

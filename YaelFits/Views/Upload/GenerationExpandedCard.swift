import SwiftUI
import UIKit

/// Floating card that morphs between pill-shape and card-shape via
/// `.frame + .clipShape + .position`. Inner pill/card content
/// layers crossfade in place; never a shared container that
/// resizes (would cause diagonal drift).
struct GenerationExpandedCard: View {
    let job: PipelineJob
    let phase: GenerationPhase
    let isExpanded: Bool
    /// 0 = bottom-most pill, 1 = above it. Drives the morph's
    /// origin Y so it starts from the specific pill the user tapped.
    let pillIndexFromBottom: Int
    /// True when another chip / stack pill sits behind the card.
    /// When false the chip slot is empty so the card centers in
    /// the viewport instead of hugging the bottom.
    let hasChipBehind: Bool
    let onCancel: () -> Void
    let onSave2D: () -> Void
    let onMake3D: () -> Void
    let onAccept: () -> Void
    let onAcceptAndPublish: () -> Void
    let onRetake: () -> Void
    let onReverseRotation: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var publishToFeed: Bool = false

    /// Remembered chin-content phase. Keeps the chin's buttons
    /// visible during a close animation that overlaps with `phase`
    /// moving off a chin state — without it, the chin's switch
    /// flips to `EmptyView` mid-collapse.
    @State private var lastChinPhase: GenerationPhase?

    private let dragDismissThreshold: CGFloat = 100

    private var chinVisibleHeight: CGFloat {
        // Use the last chin phase so the chin's height stays stable
        // during a close that overlaps with phase changing away.
        let p = phaseHasChin ? phase : (lastChinPhase ?? phase)
        switch p {
        case .readyToReview: return GenerationLayout.chinVisibleReview
        default:             return GenerationLayout.chinVisibleDecision
        }
    }

    private var chinBackingHeight: CGFloat {
        chinVisibleHeight + GenerationLayout.chinOverlap
    }

    /// Gap between the chin's visible bottom and the chip slot.
    /// Matches the chip ↔ tab-bar gap (`LayoutMetrics.xxSmall`) so
    /// chin → chip → tab-bar rhythm is consistent.
    private let chinToChipMargin: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            // Read insets from the key window — `proxy.safeAreaInsets`
            // returns zero here because `.ignoresSafeArea()` below
            // strips them. The key-window value is the real device
            // safe area (e.g. 34pt home indicator, 0 on home-button
            // devices) and is what makes the pill morph target line
            // up with the real chip's actual Y across devices.
            let bottomInset = GenerationLayout.keyWindowBottomSafeInset
            let topInset = GenerationLayout.keyWindowTopSafeInset
            let pill = pillRect(in: proxy.size, bottomInset: bottomInset)
            let card = cardRect(in: proxy.size, topInset: topInset, bottomInset: bottomInset)
            let target = isExpanded ? card : pill

            ZStack {
                // Chin always in the tree (visibility driven by
                // `shouldTrayBeOpen`) so it can't unmount mid-
                // animation when phase moves off a chin state.
                // Width is fixed; the x-scale below tracks the
                // morph as a GPU transform — keeps the blur view
                // from re-sampling its backdrop every frame.
                actionChin
                    .frame(width: card.width, height: chinBackingHeight)
                    .scaleEffect(
                        x: card.width > 0 ? target.width / card.width : 1,
                        y: shouldTrayBeOpen ? 1 : 0,
                        anchor: .top
                    )
                    .opacity(shouldTrayBeOpen ? 1 : 0)
                    .position(
                        x: target.midX,
                        y: target.maxY + (chinVisibleHeight - GenerationLayout.chinOverlap) / 2 + dragOffset
                    )
                    .gesture(dragDismissGesture)

                mainCardLayer(target: target, pill: pill, card: card)
            }
        }
        .ignoresSafeArea()
        .animation(Self.cardInternalMotion, value: phase)
        .onChange(of: phase) { _, newPhase in
            if newPhase == .awaitingDecision || newPhase == .readyToReview {
                lastChinPhase = newPhase
            }
        }
    }

    /// Single motion curve for everything that animates inside
    /// the card. Matches RootView's `cardMorphAnimation` so the
    /// chin's slide-in is on the same beat as the pill ↔ card morph.
    static let cardInternalMotion: Animation = .spring(response: 0.3, dampingFraction: 0.78)

    private var shouldTrayBeOpen: Bool {
        isExpanded && phaseHasChin
    }

    private var phaseHasChin: Bool {
        phase == .awaitingDecision || phase == .readyToReview
    }

    @ViewBuilder
    private func mainCardLayer(target: CGRect, pill: CGRect, card: CGRect) -> some View {
        // Chrome stack matches `GenerationPill` exactly so the
        // card-at-pill-state is visually identical to the real
        // pill (avoids a material shift the moment the morph starts).
        ZStack {
            // Pill content: cheap, always mounted, opacity crossfade.
            pillContentLayer
                .frame(width: pill.width, height: pill.height)
                .opacity(isExpanded ? 0 : 1)

            // Card content: heavy. Conditionally mounted so it
            // unmounts quickly on close (fast 100ms fade) and the
            // chrome morph isn't paying for full-size rendering of
            // heavy content as it shrinks.
            if isExpanded {
                cardContentLayer
                    .frame(width: card.width, height: card.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: target.width, height: target.height)
        .clipShape(RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous))
        .background {
            ZStack {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous))
                RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                    .fill(AppPalette.cardFill)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
        )
        // Shadow after `.clipShape` so it renders around the clipped
        // shape. Modest radius keeps the morph cheap per frame.
        .shadow(
            color: Color.black.opacity(isExpanded ? 0.14 : 0.08),
            radius: isExpanded ? 18 : 10,
            y: isExpanded ? 10 : 5
        )
        .position(x: target.midX, y: target.midY + dragOffset)
        .gesture(dragDismissGesture)
    }

    // MARK: - Morph rectangles

    /// Pill rect at the tapped pill's position. Uses the device's
    /// real bottom safe-area inset so the morph lands correctly on
    /// home-indicator and home-button devices alike.
    private func pillRect(in size: CGSize, bottomInset: CGFloat) -> CGRect {
        let bottomCenterY = size.height
            - GenerationLayout.chipSlotInsetFromBottom(bottomSafeInset: bottomInset)
            + GenerationLayout.pillHeight / 2
        let centerY = bottomCenterY
            - CGFloat(pillIndexFromBottom)
            * (GenerationLayout.pillHeight + GenerationLayout.pillVerticalSpacing)
        return CGRect(
            x: (size.width - GenerationLayout.pillWidth) / 2,
            y: centerY - GenerationLayout.pillHeight / 2,
            width: GenerationLayout.pillWidth,
            height: GenerationLayout.pillHeight
        )
    }

    /// Card rect — mid-screen. For chin phases the (card + chin)
    /// block either pins above the chip slot or centers in the
    /// safe band, depending on whether another chip/pill sits
    /// behind.
    private func cardRect(in size: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
        let cardWidth: CGFloat = min(360, size.width - 32)
        let height: CGFloat = cardHeight(in: size, topInset: topInset, bottomInset: bottomInset)
        let y: CGFloat
        if phaseHasChin {
            let blockHeight = height + chinVisibleHeight
            let mainBottom: CGFloat
            if hasChipBehind {
                let chipSlotTop = size.height - GenerationLayout.chipSlotInsetFromBottom(bottomSafeInset: bottomInset)
                mainBottom = chipSlotTop - chinToChipMargin - chinVisibleHeight
            } else {
                // Center block in the band between status-bar and
                // tab-bar (with margin on each side).
                let tabBarTop = size.height - GenerationLayout.tabBarInsetFromBottom(bottomSafeInset: bottomInset)
                let topSafe = max(topInset, 20)  // floor of 20 for home-button devices
                let bandTop = topSafe + chinToChipMargin
                let bandBottom = tabBarTop - chinToChipMargin
                mainBottom = bandTop
                    + max(0, (bandBottom - bandTop - blockHeight) / 2)
                    + height
            }
            y = mainBottom - height
        } else {
            // No-chin phases (queued, in-progress, done): centered.
            y = (size.height - height) / 2
        }
        return CGRect(
            x: (size.width - cardWidth) / 2,
            y: y,
            width: cardWidth,
            height: height
        )
    }

    /// Per-phase card height, clamped to fit available vertical
    /// space on small devices (iPhone SE / Mini). On a large
    /// device returns the design target; on a constrained device
    /// shrinks the card so the chin + tab bar still fit.
    private func cardHeight(in size: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let target: CGFloat = (phase == .done)
            ? GenerationLayout.doneCardHeight
            : GenerationLayout.cardHeight

        // For chin phases the budget has to leave room for the
        // chin's visible portion + the chip slot below + safe
        // areas above and below.
        let chinBudget = phaseHasChin
            ? chinVisibleHeight + 2 * chinToChipMargin
            : 0
        let topSafe = max(topInset, 20)
        let available = size.height
            - topSafe
            - GenerationLayout.tabBarInsetFromBottom(bottomSafeInset: bottomInset)
            - chinBudget
        let floor = GenerationLayout.doneCardHeight  // never shrink below this
        let cap = max(floor, available)
        return min(target, cap)
    }

    // MARK: - Content layers

    /// Visible at pill-state — same look as the actual pill in
    /// the stack, which is opacity-hidden while this card is up.
    private var pillContentLayer: some View {
        HStack(spacing: 10) {
            thumbnail
            Text(phase.pillText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// `.id(contentGroupId)` + `.transition(.opacity)` gives a
    /// clean crossfade when phase crosses a content-group boundary
    /// (progress / decision / review). Within a group the id is
    /// stable so no transition runs.
    @ViewBuilder
    private var cardContentLayer: some View {
        Group {
            switch phase {
            case .queued, .rendering2D, .rendering3D:
                inProgressContent
            case .awaitingDecision:
                decisionContent
            case .readyToReview:
                reviewContent
            case .done:
                EmptyView()
            }
        }
        .id(contentGroupId)
        .transition(.opacity)
    }

    private var contentGroupId: String {
        switch phase {
        case .queued, .rendering2D, .rendering3D: return "progress"
        case .awaitingDecision:                   return "decision"
        case .readyToReview:                      return "review"
        case .done:                               return "done"
        }
    }

    // MARK: - In-progress content (sparkles + status text)

    private var inProgressContent: some View {
        ZStack {
            GenerationStarField(starSize: 180, interactive: false)
                .allowsHitTesting(false)

            // Title pinned to top, detail centered in the middle, cancel
            // pinned to bottom — three rows so each piece has its own
            // anchor and the paragraph stays at card-center regardless
            // of how long the title wraps.
            VStack(spacing: 0) {
                Text(progressTitle)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(AppPalette.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.top, LayoutMetrics.small)

                Spacer(minLength: 0)

                Text(progressDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 220)

                Spacer(minLength: 0)

                cancelLink
                    .padding(.bottom, LayoutMetrics.small)
            }
        }
        .padding(LayoutMetrics.medium)
    }

    /// Title shown at top of the in-progress card. Distinguishes
    /// `queued` (waiting behind the concurrency cap) from the active
    /// loader stages, and surfaces `job.error` if generation failed
    /// while the card is still in a progress state.
    private var progressTitle: String {
        if job.error != nil { return "SOMETHING WENT WRONG" }
        if phase == .queued { return "IN LINE" }
        switch job.loaderStage {
        case .removingBackground:     return "REMOVING BACKGROUND"
        case .creatingInteractiveFit: return "CREATING YOUR INTERACTIVE FIT"
        case .compressing:            return "COMPRESSING"
        }
    }

    /// Friendly detail under the title.
    private var progressDetail: String {
        if let err = job.error { return err }
        if phase == .queued {
            return "Another fit's ahead of you.\nHang tight — you're up next."
        }
        switch job.loaderStage {
        case .removingBackground:
            return "Cutting you out like the main character you are."
        case .creatingInteractiveFit:
            return "Good things take a few minutes. You can close the app — we'll ping you when it's ready."
        case .compressing:
            return "Almost there.\nSqueezing your fit into its final form."
        }
    }

    // MARK: - Decision content (Save 2D / Make 3D)

    /// Title + preview only — action buttons live in the chin below.
    private var decisionContent: some View {
        VStack(spacing: LayoutMetrics.small) {
            Spacer(minLength: 0)
            if let err = job.error {
                // Out-of-credits (and any other 3D failure that routes
                // back to the fork) surfaces here so the user knows
                // *why* they're back at the Save 2D / Generate 3D pick.
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            } else {
                Text("Pick how to save this fit")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            cutoutPreviewCard(height: 320)
            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.small)
    }

    // MARK: - Review content (Accept / Publish / Regenerate)

    /// Title + preview only — action buttons live in the chin below.
    private var reviewContent: some View {
        VStack(spacing: LayoutMetrics.small) {
            Spacer(minLength: 0)
            Text("Your interactive fit is ready")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(AppPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            reviewPreviewCard(height: 320)
            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.small)
    }

    /// Single chin surface that opens out from under the main
    /// card. Buttons are flat rows (no per-row chrome) so the
    /// chin reads as one card, not a stack of mini-cards.
    @ViewBuilder
    private var actionChin: some View {
        // Use `lastChinPhase` so the chin's buttons stay valid
        // during a close that overlaps with phase moving off a
        // chin state — otherwise the switch falls through to
        // `EmptyView` mid-collapse.
        let activeChinPhase: GenerationPhase = phaseHasChin ? phase : (lastChinPhase ?? phase)
        VStack(spacing: LayoutMetrics.xxSmall) {
            switch activeChinPhase {
            case .awaitingDecision:
                primaryButton(label: "Generate 3D", action: onMake3D)
                secondaryButton(label: "Save as 2D", action: onSave2D)
                cancelLink
            case .readyToReview:
                publishToggleRow
                primaryButton(
                    label: publishToFeed ? "Accept & Publish" : "Accept",
                    action: { publishToFeed ? onAcceptAndPublish() : onAccept() }
                )
                secondaryButton(label: "Regenerate", action: onRetake)
                cancelLink
            default:
                EmptyView()
            }
        }
        // Top padding clears the hidden overlap area plus a buffer
        // so the first row sits below the main card's bottom edge.
        .padding(.top, GenerationLayout.chinOverlap + LayoutMetrics.small)
        .padding(.horizontal, LayoutMetrics.medium)
        .padding(.bottom, LayoutMetrics.xSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // Glassy backdrop — matches the card chrome above so
            // the chin reads as the same material extended below.
            ZStack {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous))
                RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                    .fill(AppPalette.cardFill)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 5)
    }

    // MARK: - Reusable bits

    @ViewBuilder
    private var thumbnail: some View {
        CachedJobThumbnail(sourceImage: job.sourceImage, size: 28)
            .clipShape(Circle())
    }

    /// Cutout preview — just the image, no card-inside-a-card.
    /// The main card's chrome is the only surface; the image
    /// floats on it.
    @ViewBuilder
    private func cutoutPreviewCard(height: CGFloat) -> some View {
        Group {
            if let cutoutData = job.cutoutImage, let image = UIImage(data: cutoutData) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    @ViewBuilder
    private func reviewPreviewCard(height: CGFloat) -> some View {
        let isRotatable = (job.stagedOutfit?.frameCount ?? 0) > 1
        ZStack(alignment: .bottomTrailing) {
            if let stagedOutfit = job.stagedOutfit {
                RotatableOutfitImage(
                    outfit: stagedOutfit,
                    height: height,
                    draggable: isRotatable,
                    eagerLoad: true,
                    preloadFullSequenceOnAppear: true
                )
            }

            // Show the reverse-rotation control whenever the user
            // is in the review phase — even if the fake/staged
            // outfit only has 1 frame. The button is the user's
            // promise that 3D came out of a 3D pipeline; hiding it
            // when frameCount is 1 (the fake) makes it look like
            // the review surface is missing a control. Real
            // outfits have frameCount > 1 and the button is fully
            // functional.
            Button {
                onReverseRotation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text(job.isRotationReversed ? "Use Original" : "Reverse")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .appCapsule(shadowRadius: 8, shadowY: 4)
            }
            .buttonStyle(SolidPressButtonStyle())
            .padding(.horizontal, LayoutMetrics.small)
            .padding(.bottom, LayoutMetrics.small)
            .disabled(!isRotatable)
        }
        .frame(height: height)
    }

    /// Primary action — the app's signature glass capsule with the
    /// same look as `AuthView`'s submit button (semibold mono +
    /// tracking, shadowed). Sits at the top of the chin's button
    /// stack as the encouraged action.
    private func primaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        } label: {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .appCapsule(shadowRadius: 8, shadowY: 4)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Secondary action — same glass capsule shape, but lighter
    /// text weight + no shadow so it visually yields to the
    /// primary. Same chrome family as the primary so the chin
    /// reads as a coherent group rather than two unrelated buttons.
    private func secondaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        } label: {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// "Publish to Feed" toggle — custom flat switch (not the
    /// SwiftUI `Toggle` which picks up iOS's glassy/3D material
    /// look). Same dimensions as the system switch, but a plain
    /// solid capsule track + a white circle thumb — no sheen, no
    /// inner shadow.
    private var publishToggleRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            publishToFeed.toggle()
        } label: {
            HStack {
                Text("Publish to Feed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.textSecondary)
                Spacer()
                flatToggleSwitch
            }
            .padding(.horizontal, LayoutMetrics.small)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var flatToggleSwitch: some View {
        ZStack(alignment: publishToFeed ? .trailing : .leading) {
            Capsule()
                .fill(publishToFeed ? AppPalette.uploadGlow : Color(white: 0.82))
                .frame(width: 44, height: 26)
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .padding(2)
                .shadow(color: Color.black.opacity(0.15), radius: 1.5, y: 0.5)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: publishToFeed)
    }

    private var cancelLink: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            onCancel()
        } label: {
            Text("Cancel")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppPalette.textFaint)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Drag dismiss

    private var dragDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                dragOffset = max(0, value.translation.height * 0.92)
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.height
                if value.translation.height > dragDismissThreshold || predicted > 240 {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.smooth(duration: 0.3)) {
                        dragOffset = 0
                    }
                    onDismiss()
                } else {
                    withAnimation(.smooth(duration: 0.3)) {
                        dragOffset = 0
                    }
                }
            }
    }

}

import SwiftUI
import UIKit

/// Identifiable wrapper used by every Quick Add entry point to drive
/// `.sheet(item:)`. Replaces the per-site Carousel/Calendar/Publish/Upload
/// source structs that all had identical shape.
struct QuickAddSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Tap → name → generate flow for product thumbnails. We feed the whole outfit
/// to nano-banana along with the user-supplied garment name so the model has
/// full context (length, cut, occlusions) — no segmentation step.
struct AutoDetectProductsView: View {
    let sourceImage: UIImage
    let userId: UUID
    /// Tiny header label above the canvas. Defaults to "ADD PRODUCTS".
    var headerTitle: String = "ADD PRODUCTS"
    /// Hint shown when no slots have been placed yet. Other states
    /// (naming, post-tap) keep their generic copy.
    var emptyStateHint: String = "TAP A GARMENT ON THE OUTFIT"
    /// Label for the dismiss-without-saving action. Defaults to "Cancel" for
    /// user-initiated entry points; the upload pipeline (which auto-presents
    /// the sheet) uses "Skip / Add later" so it's clear this step is optional.
    var cancelLabel: String = "Cancel"
    /// When provided, the top-right action button shows "Skip" until
    /// the user places their first slot, then swaps to the regular
    /// "Save" affordance. Only the post-greenscreen entry point uses
    /// this — other sheets pass nil and the top-right button is
    /// always "Save".
    var onSkip: (() -> Void)? = nil
    /// Optional fallback for users who don't want the AI-tap flow:
    /// renders an "Add manually" pill at the bottom of the screen
    /// that dismisses the sheet and lets the caller present its own
    /// manual product-entry surface. Hidden when nil. Declared
    /// before `onProductSaved` so existing call sites can keep using
    /// trailing-closure syntax for the save callback.
    var onAddManually: (() -> Void)? = nil
    /// Fires once per uploaded product. The corner checkmark on an
    /// accepted card calls this for that single product and removes the
    /// slot; the sheet stays open. The global Save button calls this
    /// for each remaining accepted slot, then dismisses. Parents
    /// should append to their own product list — the sheet does not
    /// dedup.
    var onProductSaved: (Product) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var slots: [GarmentSlot] = []
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var subjectExtents: SubjectExtents?
    /// "Already in your closet?" matches for the slot currently being
    /// named, plus the slot they belong to. Driven by
    /// `WardrobeService.findSimilar` so the user can reuse an existing
    /// item instead of re-logging it — which also skips the FAL
    /// thumbnail generation entirely.
    @State private var suggestions: [ClosetMatch] = []
    @State private var suggestionSlotID: UUID?
    @FocusState private var focusedSlotID: UUID?
    /// Slot most recently tapped or dragged. Rendered above its peers so
    /// partially-covered cards can be brought forward with one tap.
    @State private var foregroundedSlotID: UUID?
    /// In-flight drag deltas keyed by slot id. Committed onto the slot's
    /// own `dragOffset` when the gesture ends.
    @State private var liveDragTranslation: [UUID: CGSize] = [:]

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                customHeader
                hintBar
                canvasArea
            }
            if let onAddManually {
                VStack {
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onAddManually()
                        dismiss()
                    } label: {
                        Text("Add manually")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 48)
                            .background(
                                Capsule(style: .continuous).fill(Color.black)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, LayoutMetrics.medium)
                }
                // Stay pinned at the bottom; it's fine for the keyboard to
                // cover it while naming a slot (a separate flow) rather
                // than have it ride up over the card.
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .alert("Couldn't save", isPresented: errorBinding) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .task {
            // SubjectExtents iterates every pixel, so keep it off the
            // main thread — otherwise the first tap right after the
            // sheet appears can stall waiting for this to finish.
            if subjectExtents == nil {
                let img = sourceImage
                let extents = await Task.detached(priority: .userInitiated) {
                    SubjectExtents.build(from: img)
                }.value
                subjectExtents = extents
            }
        }
        .onDisappear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // Debounced "already in your closet?" lookup, re-run whenever the
        // name of the slot being typed into changes.
        .task(id: activeNamingName) {
            let name = (activeNamingName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else {
                await MainActor.run { suggestions = [] }
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let matches = (try? await WardrobeService.findSimilar(query: name, limit: 6)) ?? []
            if Task.isCancelled { return }
            await MainActor.run {
                suggestionSlotID = focusedSlotID
                suggestions = matches
            }
        }
        .overlay(alignment: .bottom) {
            if !suggestions.isEmpty, activeNamingName != nil {
                suggestionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: suggestions.isEmpty)
    }

    // MARK: - Header

    private var customHeader: some View {
        ZStack {
            Text(headerTitle)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(AppPalette.textFaint)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text(cancelLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.textPrimary)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .appCapsule()
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    if showsSkipAction {
                        onSkip?()
                        dismiss()
                    } else {
                        Task { await saveAccepted() }
                    }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().controlSize(.small).tint(AppPalette.textMuted)
                        } else if showsSkipAction {
                            Text("Skip")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)
                        } else {
                            // Stay visually active even when all products
                            // have been saved individually — tapping it
                            // then just dismisses the sheet, which is
                            // less confusing than a dimmed button.
                            Text("Save")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)
                        }
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .appCapsule()
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, LayoutMetrics.medium)
        .padding(.top, LayoutMetrics.small)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    // MARK: - Hint

    private var hintBar: some View {
        Text(hintText)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(2.2)
            .foregroundStyle(AppPalette.textFaint)
            .multilineTextAlignment(.center)
            .padding(.vertical, LayoutMetrics.small)
            .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    private var hintText: String {
        let hasNamingSlot = slots.contains { if case .naming = $0.state { return true }; return false }
        if hasNamingSlot { return "NAME EACH ITEM, THEN TAP DONE" }
        if slots.isEmpty { return emptyStateHint }
        return "TAP ANOTHER GARMENT, OR SAVE WHEN DONE"
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let imageRect = computeImageRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                // Tap target — sized to the canvas so we can use a single
                // unambiguous coord space ("canvas") for the gesture.
                // We then explicitly translate the tap into image-local
                // coordinates by subtracting `imageRect.origin`. This
                // avoids any ambiguity that `.position` introduces around
                // the gesture's local coord interpretation.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                            .onEnded { value in
                                let localX = value.location.x - imageRect.minX
                                let localY = value.location.y - imageRect.minY
                                let imageLocal = CGPoint(x: localX, y: localY)
                                handleTap(at: imageLocal, imageRect: imageRect)
                            }
                    )

                let positions = computeAllPositions(canvasSize: geo.size, imageRect: imageRect, bottomReserved: suggestionBarReserved)
                ForEach(slots) { slot in
                    SlotWidgetView(
                        slot: slot,
                        focusedID: $focusedSlotID,
                        onNameChange: { updateName(slot.id, $0) },
                        onCommitName: { Task { await commitName(slot.id) } },
                        onAccept: { acceptSlot(slot.id) },
                        onRetry: { Task { await retryGeneration(slot.id) } },
                        onDismiss: { dismissSlot(slot.id) },
                        onSaveAccepted: { Task { await saveOne(slot.id) } }
                    )
                    .position(positions[slot.id] ?? .zero)
                    .offset(
                        x: slot.dragOffset.width + (liveDragTranslation[slot.id]?.width ?? 0),
                        y: slot.dragOffset.height + (liveDragTranslation[slot.id]?.height ?? 0)
                    )
                    .zIndex(slot.id == foregroundedSlotID ? 1 : 0)
                    .onTapGesture { foregroundedSlotID = slot.id }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                liveDragTranslation[slot.id] = value.translation
                                if foregroundedSlotID != slot.id {
                                    foregroundedSlotID = slot.id
                                }
                            }
                            .onEnded { value in
                                if let i = slots.firstIndex(where: { $0.id == slot.id }) {
                                    slots[i].dragOffset.width += value.translation.width
                                    slots[i].dragOffset.height += value.translation.height
                                }
                                liveDragTranslation[slot.id] = nil
                            }
                    )
                    .transition(
                        .scale(scale: 0.92).combined(with: .opacity)
                    )
                    .animation(.smooth(duration: 0.25), value: slot.state.id)
                }
            }
            // Keyboard show/dismiss changes geo.size, which recomputes
            // imageRect — animate the figure (and slot positions) so it
            // doesn't hard-cut when the user taps Done or X and the
            // keyboard goes away.
            .animation(.smooth(duration: 0.25), value: imageRect)
            // Slide cards up/down when the suggestion bar appears/clears so
            // a low card lifts clear of it rather than being covered.
            .animation(.smooth(duration: 0.22), value: suggestionBarReserved)
            .coordinateSpace(name: "canvas")
        }
    }

    private var hasAcceptedSlot: Bool {
        slots.contains { if case .accepted = $0.state { return true }; return false }
    }

    /// True iff the top-right button should currently be a "Skip" action
    /// (post-greenscreen sheet, before any garment is tapped). Once the
    /// user starts placing slots, the button reverts to the standard
    /// Save affordance.
    private var showsSkipAction: Bool {
        onSkip != nil && slots.isEmpty
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    // MARK: - Geometry

    /// Shrinks the rendered figure relative to the canvas so floating slot
    /// cards have whitespace to sit in instead of overlapping the subject.
    private static let imageScale: CGFloat = 0.85

    private func computeImageRect(in canvasSize: CGSize) -> CGRect {
        let aspect = sourceImage.size.width / max(sourceImage.size.height, 1)
        let maxWidth = canvasSize.width * Self.imageScale
        let maxHeight = (canvasSize.height - LayoutMetrics.small) * Self.imageScale
        var w = maxWidth
        var h = w / max(aspect, 0.001)
        if h > maxHeight {
            h = maxHeight
            w = h * aspect
        }
        let originX = (canvasSize.width - w) / 2
        let originY = (canvasSize.height - h) / 2
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    /// Compute every slot's position in a single pass so we can keep cards
    /// from overlapping each other on the same side. Each slot gets pushed
    /// down past any earlier card it would collide with.
    private func computeAllPositions(canvasSize: CGSize, imageRect: CGRect, bottomReserved: CGFloat = 0) -> [UUID: CGPoint] {
        let widgetHalf = SlotWidgetView.widgetOuterWidth / 2
        // Edge inset has to clear the 40pt corner button overhang from the
        // top-right of each card (offset 8, -8), or the X gets clipped.
        let edgeInset: CGFloat = 32
        let interCardSpacing: CGFloat = 10

        var positions: [UUID: CGPoint] = [:]
        var leftOccupied: [(top: CGFloat, bottom: CGFloat)] = []
        var rightOccupied: [(top: CGFloat, bottom: CGFloat)] = []

        for slot in slots {
            let yRatio = slot.tapPoint.y / max(sourceImage.size.height, 1)
            let preferredY = imageRect.minY + yRatio * imageRect.height
            let halfHeight = SlotWidgetView.estimatedHeight(for: slot.state) / 2

            let onRight = preferredSide(for: slot)
            let centerX = onRight
                ? canvasSize.width - widgetHalf - edgeInset
                : widgetHalf + edgeInset

            // Resolve Y so we don't overlap any earlier card on the same side.
            let topPad = halfHeight + 4
            let bottomPad = canvasSize.height - halfHeight - 8 - bottomReserved
            var y = max(topPad, min(preferredY, bottomPad))

            // Push down past any colliding occupied range, repeating until
            // there's no overlap or we hit the bottom.
            for _ in 0..<slots.count {
                let occupied = onRight ? rightOccupied : leftOccupied
                let myTop = y - halfHeight
                let myBottom = y + halfHeight
                let collision = occupied.first { other in
                    myTop < other.bottom + interCardSpacing
                        && myBottom > other.top - interCardSpacing
                }
                guard let hit = collision else { break }
                y = hit.bottom + interCardSpacing + halfHeight
                if y > bottomPad {
                    y = bottomPad
                    break
                }
            }

            let range = (top: y - halfHeight, bottom: y + halfHeight)
            if onRight { rightOccupied.append(range) } else { leftOccupied.append(range) }
            positions[slot.id] = CGPoint(x: centerX, y: y)
        }
        return positions
    }

    private func preferredSide(for slot: GarmentSlot) -> Bool {
        guard let extents = subjectExtents else {
            return slot.tapPoint.x < sourceImage.size.width / 2
        }
        let yPixel = Int(slot.tapPoint.y.rounded())
        let row = extents.extents(atRow: yPixel)
        if row.right < 0 {
            return slot.tapPoint.x < sourceImage.size.width / 2
        }
        let leftEmpty = row.left
        let rightEmpty = (extents.imageWidth - 1) - row.right
        return rightEmpty >= leftEmpty
    }

    // MARK: - Tap handling

    private func handleTap(at location: CGPoint, imageRect: CGRect) {
        // If a slot is currently being named, a tap on the background just
        // dismisses the keyboard + "already in your closet?" bar (back to
        // the plain tagging UI) instead of starting a new tag.
        if focusedSlotID != nil {
            focusedSlotID = nil
            suggestions = []
            return
        }

        let xRatio = location.x / imageRect.width
        let yRatio = location.y / imageRect.height
        guard (0...1).contains(xRatio), (0...1).contains(yRatio) else { return }
        let pixelPoint = CGPoint(
            x: xRatio * sourceImage.size.width,
            y: yRatio * sourceImage.size.height
        )

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let preview = cropPreview(around: pixelPoint, from: sourceImage)
        let slot = GarmentSlot(
            id: UUID(),
            tapPoint: pixelPoint,
            previewCrop: preview,
            placeholderHint: placeholderHint(forTapY: pixelPoint.y),
            state: .naming,
            name: ""
        )
        withAnimation(.easeOut(duration: 0.18)) {
            slots.append(slot)
        }
        focusedSlotID = slot.id
        // Newest slot wins z-order over any previously foregrounded card.
        foregroundedSlotID = slot.id
    }

    /// Pick an example placeholder based on which third of the subject's
    /// bbox the tap landed in: upper body (tops), lower body (bottoms), or
    /// feet (shoes). Falls back to a lower-body example if we don't have a
    /// subject bbox yet (mask still building).
    private func placeholderHint(forTapY tapY: CGFloat) -> String {
        guard let extents = subjectExtents,
              extents.subjectMaxY > extents.subjectMinY else {
            return PlaceholderExamples.lower.randomElement() ?? "e.g. Black Jeans"
        }
        let bboxHeight = CGFloat(extents.subjectMaxY - extents.subjectMinY + 1)
        let relativeY = (tapY - CGFloat(extents.subjectMinY)) / bboxHeight

        if relativeY < 0.45 {
            return PlaceholderExamples.upper.randomElement() ?? "e.g. Black Tee"
        } else if relativeY < 0.78 {
            return PlaceholderExamples.lower.randomElement() ?? "e.g. Blue Jeans"
        } else {
            return PlaceholderExamples.feet.randomElement() ?? "e.g. Black Loafers"
        }
    }

    /// Crops a square region of `image` centered on the user's tap.
    /// Fast path: the desired crop rect fits inside the source image,
    /// so a single `cgImage.cropping(to:)` call returns the result —
    /// no full-bitmap render needed, which keeps the tap-to-thumbnail
    /// latency in the single-digit-millisecond range.
    /// Edge-case path (tap near the figure's border): crop just the
    /// visible portion and composite it into a square canvas at the
    /// right offset so the tap pixel still lands dead center.
    private func cropPreview(around point: CGPoint, from image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let cgW = CGFloat(cg.width)
        let cgH = CGFloat(cg.height)
        let cropSize = min(cgW, cgH) * 0.5
        let halfCrop = cropSize / 2

        let scale = image.scale
        let px = point.x * scale
        let py = point.y * scale

        let desiredRect = CGRect(
            x: px - halfCrop,
            y: py - halfCrop,
            width: cropSize,
            height: cropSize
        )
        let imageBounds = CGRect(x: 0, y: 0, width: cgW, height: cgH)

        // Fast path — crop fully inside the source image.
        if imageBounds.contains(desiredRect),
           let croppedCG = cg.cropping(to: desiredRect) {
            return UIImage(cgImage: croppedCG, scale: 1, orientation: .up)
        }

        // Slow path — tap near the image edge, so part of the desired
        // crop falls outside. Crop the visible portion, then place it
        // in a square canvas at the offset that keeps the tap centered.
        let visiblePart = desiredRect.intersection(imageBounds)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: cropSize, height: cropSize),
            format: format
        )
        return renderer.image { _ in
            guard !visiblePart.isEmpty,
                  let visibleCG = cg.cropping(to: visiblePart) else { return }
            let visibleUI = UIImage(cgImage: visibleCG, scale: 1, orientation: .up)
            let drawX = visiblePart.minX - desiredRect.minX
            let drawY = visiblePart.minY - desiredRect.minY
            visibleUI.draw(in: CGRect(
                x: drawX,
                y: drawY,
                width: visiblePart.width,
                height: visiblePart.height
            ))
        }
    }

    // MARK: - Pipeline

    private func updateName(_ slotID: UUID, _ newName: String) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[i].name = newName
    }

    // MARK: - Closet dedup suggestions

    /// Extra bottom space the canvas must keep clear for the "already in
    /// your closet?" suggestion bar (which floats above the keyboard), so
    /// the focused card lifts above it instead of being covered. Zero
    /// when the bar isn't showing. Approximates the bar's rendered height
    /// (label + chip row + padding) plus a small gap.
    private var suggestionBarReserved: CGFloat {
        (!suggestions.isEmpty && activeNamingName != nil) ? 140 : 0
    }

    /// Name of the slot currently being typed into (focused + `.naming`).
    /// Drives the suggestion lookup; `nil` when nothing is being named.
    private var activeNamingName: String? {
        guard let id = focusedSlotID,
              let slot = slots.first(where: { $0.id == id }),
              case .naming = slot.state else { return nil }
        return slot.name
    }

    /// Reuse an existing closet item for a slot instead of generating a
    /// fresh thumbnail: fire `onProductSaved` with a `Product` that
    /// points at the existing library row (carrying its `productId` so
    /// the tag links to it), then drop the slot. No FAL call.
    /// Reuse an existing closet item for a slot. Rather than silently
    /// dropping the slot, it drives the *same* card states as a normal
    /// tag (name fills in → brief `.generating` → `.accepted` showing
    /// the product thumbnail) so it visually reads as "added", then
    /// saves and removes the slot. No FAL call — the thumbnail is the
    /// existing item's image.
    private func reuseExistingItem(_ item: ClosetMatch, for slotID: UUID) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        focusedSlotID = nil
        suggestions = []
        withAnimation(.smooth(duration: 0.22)) {
            slots[i].name = item.displayName
            slots[i].state = .generating
        }
        Task {
            let raw = await loadImage(item.resolvedImageURL)
            // Trim the transparent margins so the garment fills the card
            // box consistently — otherwise each PNG's random padding made
            // the reused item look huge or tiny in the "added" card.
            let trimmed = await Task.detached(priority: .userInitiated) {
                raw?.trimmingTransparentMargins()
            }.value
            await MainActor.run {
                if let trimmed, let j = slots.firstIndex(where: { $0.id == slotID }) {
                    withAnimation(.smooth(duration: 0.25)) {
                        slots[j].state = .accepted(trimmed)
                    }
                }
            }
            // Let the "added" card linger a beat so the swap is felt, then
            // commit + remove with the standard removal animation.
            try? await Task.sleep(nanoseconds: trimmed == nil ? 0 : 650_000_000)
            await MainActor.run { finalizeReuse(item: item, slotID: slotID) }
        }
    }

    private func finalizeReuse(item: ClosetMatch, slotID: UUID) {
        onProductSaved(Product(
            name: item.name,
            price: item.price,
            image: item.imageURL,
            shopLink: item.sourceURL,
            productId: item.productId,
            tags: nil
        ))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.18)) {
            slots.removeAll { $0.id == slotID }
        }
    }

    private func loadImage(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private var suggestionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALREADY IN YOUR CLOSET?")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(AppPalette.textFaint)
                .padding(.horizontal, LayoutMetrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(suggestions) { item in
                        Button {
                            if let sid = suggestionSlotID {
                                reuseExistingItem(item, for: sid)
                            }
                        } label: {
                            suggestionChip(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                // Vertical room so the chip shadows aren't clipped by the
                // horizontal ScrollView's bounds.
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(AppPalette.groupedBackground)
            .shadow(color: Color.black.opacity(0.10), radius: 16, y: -5)
        )
    }

    /// A big product thumbnail + semibold label on a thin-material
    /// capsule. `scaledToFit` so the product is never cropped, and no
    /// circle behind it — the product image itself is the focus.
    private func suggestionChip(_ item: ClosetMatch) -> some View {
        HStack(spacing: 6) {
            suggestionThumbnail(item)
            Text(item.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
        .background {
            ZStack {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Capsule(style: .continuous))
                Capsule(style: .continuous).fill(AppPalette.cardFill)
            }
        }
        .overlay(Capsule(style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
    }

    private func suggestionThumbnail(_ item: ClosetMatch) -> some View {
        // Trims the product PNG's transparent margins so the garment
        // fills the frame; fixed size so the pill never resizes on load.
        TrimmedProductThumbnail(url: item.resolvedImageURL, size: 46)
    }

    private func commitName(_ slotID: UUID) async {
        await MainActor.run {
            guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
            guard case .naming = slots[i].state else { return }
            let trimmed = slots[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            slots[i].name = trimmed
            slots[i].state = .generating
            focusedSlotID = nil
        }
        await runGeneration(for: slotID)
    }

    private func runGeneration(for slotID: UUID) async {
        guard let snapshot = await MainActor.run(body: { slots.first(where: { $0.id == slotID }) }) else { return }
        do {
            let thumbnail = try await FalProductThumbnailService.shared.generateThumbnail(
                fromOutfit: sourceImage,
                label: snapshot.name,
                onUpdate: { _ in }
            )
            await MainActor.run {
                guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
                slots[i].state = .readyForReview(thumbnail)
            }
        } catch {
            await MainActor.run {
                guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
                slots[i].state = .failed(error.localizedDescription)
            }
        }
    }

    private func retryGeneration(_ slotID: UUID) async {
        await MainActor.run {
            guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
            switch slots[i].state {
            case .readyForReview, .accepted, .failed:
                slots[i].state = .generating
            default:
                return
            }
        }
        await runGeneration(for: slotID)
    }

    private func acceptSlot(_ slotID: UUID) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        guard case let .readyForReview(thumb) = slots[i].state else { return }
        slots[i].state = .accepted(thumb)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func dismissSlot(_ slotID: UUID) {
        // Clear focus FIRST so the keyboard dismissal starts at the same
        // moment the slot fades out. Otherwise SwiftUI removes the
        // focused TextField first, then clears focus, and the figure
        // scale-up arrives a beat later than the slot disappearance.
        if focusedSlotID == slotID {
            focusedSlotID = nil
        }
        withAnimation(.easeOut(duration: 0.12)) {
            slots.removeAll { $0.id == slotID }
        }
    }

    // MARK: - Save

    /// Uploads the thumbnail for a single accepted slot, reports it to
    /// the parent, and removes the slot from the canvas. Sheet stays
    /// up. Wired to each card's corner checkmark.
    private func saveOne(_ slotID: UUID) async {
        guard let snapshot = await MainActor.run(body: { slots.first(where: { $0.id == slotID }) }) else { return }
        guard case let .accepted(thumb) = snapshot.state else { return }
        do {
            let url = try await ProductThumbnailUploadService.upload(thumb, userId: userId)
            let product = Product(
                name: snapshot.name,
                price: nil,
                image: url,
                shopLink: nil,
                productId: nil,
                tags: nil
            )
            await MainActor.run {
                onProductSaved(product)
                withAnimation(.easeOut(duration: 0.12)) {
                    slots.removeAll { $0.id == slotID }
                }
            }
        } catch {
            await MainActor.run { saveError = error.localizedDescription }
        }
    }

    /// Uploads every still-accepted slot in turn (firing onProductSaved
    /// for each) and dismisses the sheet. Wired to the global Save
    /// button.
    private func saveAccepted() async {
        await MainActor.run { isSaving = true }
        defer { Task { @MainActor in isSaving = false } }

        let acceptedIDs = await MainActor.run {
            slots.compactMap { slot -> UUID? in
                if case .accepted = slot.state { return slot.id }
                return nil
            }
        }

        for slotID in acceptedIDs {
            guard let snapshot = await MainActor.run(body: { slots.first(where: { $0.id == slotID }) }) else { continue }
            guard case let .accepted(thumb) = snapshot.state else { continue }
            do {
                let url = try await ProductThumbnailUploadService.upload(thumb, userId: userId)
                let product = Product(
                    name: snapshot.name,
                    price: nil,
                    image: url,
                    shopLink: nil,
                    productId: nil,
                    tags: nil
                )
                await MainActor.run { onProductSaved(product) }
            } catch {
                await MainActor.run { saveError = error.localizedDescription }
                return
            }
        }
        await MainActor.run { dismiss() }
    }
}

// MARK: - Quick Add cover-frame loader

extension AutoDetectProductsView {
    /// Fetches frame 0 of the outfit's CDN-hosted rotation and decodes it
    /// into a UIImage. Used by every Quick Add entry point that operates on
    /// an existing outfit (carousel, calendar edit, publish sheet). The
    /// upload pipeline bypasses this and feeds its in-memory cutout
    /// directly. Returns nil on any fetch/decode failure so callers can
    /// surface their own error UI.
    static func loadCoverFrame(for outfit: Outfit) async -> UIImage? {
        guard let baseURL = outfit.resolvedRemoteBaseURL else { return nil }
        let frameURL = outfit.frameURL(index: 0, baseURL: baseURL)
        do {
            let (data, _) = try await URLSession.shared.data(from: frameURL)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Subject extents

/// Per-row left/right edges of the opaque subject in the source image. Used
/// to place each floating widget in the empty space at its tap's Y level
/// rather than at a fixed canvas edge.
private struct SubjectExtents {
    let imageWidth: Int
    let imageHeight: Int
    /// Top-most opaque row of the subject (in image pixel coords). Used by the
    /// placeholder-hint heuristic to figure out which third of the body the
    /// user tapped on.
    let subjectMinY: Int
    /// Bottom-most opaque row of the subject.
    let subjectMaxY: Int
    private let leftEdges: [Int]   // leftmost opaque X per row, or imageWidth if empty
    private let rightEdges: [Int]  // rightmost opaque X per row, or -1 if empty

    func extents(atRow y: Int) -> (left: Int, right: Int) {
        guard imageHeight > 0 else { return (imageWidth, -1) }
        let cy = max(0, min(imageHeight - 1, y))
        return (leftEdges[cy], rightEdges[cy])
    }

    static func build(from image: UIImage) -> SubjectExtents? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var leftEdges = [Int](repeating: w, count: h)
        var rightEdges = [Int](repeating: -1, count: h)
        var minY = h
        var maxY = -1
        for y in 0..<h {
            let rowOffset = y * w * 4
            var rowLeft = w
            var rowRight = -1
            for x in 0..<w {
                let alpha = pixels[rowOffset + x * 4 + 3]
                if alpha > 40 {
                    if x < rowLeft { rowLeft = x }
                    if x > rowRight { rowRight = x }
                }
            }
            leftEdges[y] = rowLeft
            rightEdges[y] = rowRight
            if rowRight >= 0 {
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return SubjectExtents(
            imageWidth: w,
            imageHeight: h,
            subjectMinY: minY < h ? minY : 0,
            subjectMaxY: maxY >= 0 ? maxY : h - 1,
            leftEdges: leftEdges,
            rightEdges: rightEdges
        )
    }
}

// MARK: - Slot model

private struct GarmentSlot: Identifiable {
    let id: UUID
    let tapPoint: CGPoint
    let previewCrop: UIImage
    /// Position-derived placeholder shown in the name field before the user
    /// types anything (e.g. "e.g. Black Jeans" for a tap on the lower body).
    let placeholderHint: String
    var state: SlotState
    var name: String
    /// Manual translation applied on top of auto-placement after the user
    /// drags the card. Auto-placement keeps using `tapPoint` so other
    /// cards arrange against the original target, not the dragged-away
    /// position.
    var dragOffset: CGSize = .zero
}

/// Position-based placeholder examples for the name field — picked from the
/// vertical zone of the tap relative to the subject's bbox.
private enum PlaceholderExamples {
    static let upper = [
        "e.g. Black Tee",
        "e.g. Wool Sweater",
        "e.g. Denim Jacket",
        "e.g. Cropped Top",
        "e.g. Linen Shirt",
        "e.g. Leather Blazer",
    ]
    static let lower = [
        "e.g. Blue Jeans",
        "e.g. Mini Skirt",
        "e.g. Cargo Pants",
        "e.g. Wool Trousers",
        "e.g. Pleated Skirt",
        "e.g. Wide-leg Jeans",
    ]
    static let feet = [
        "e.g. Black Loafers",
        "e.g. White Sneakers",
        "e.g. Knee Boots",
        "e.g. Ballet Flats",
        "e.g. Chunky Boots",
    ]
}

private enum SlotState {
    case naming
    case generating
    case readyForReview(UIImage)
    case accepted(UIImage)
    case failed(String)

    var id: Int {
        switch self {
        case .naming: return 0
        case .generating: return 1
        case .readyForReview: return 2
        case .accepted: return 3
        case .failed: return 4
        }
    }
}

// MARK: - Slot widget

private struct SlotWidgetView: View {
    let slot: GarmentSlot
    @FocusState.Binding var focusedID: UUID?
    var onNameChange: (String) -> Void
    var onCommitName: () -> Void
    var onAccept: () -> Void
    var onRetry: () -> Void
    var onDismiss: () -> Void
    /// Tapped when the corner checkmark on an already-accepted slot is
    /// pressed — commits the save flow rather than removing the slot.
    var onSaveAccepted: () -> Void

    private static let thumbSize: CGFloat = 132
    private static let cornerRadius: CGFloat = 18
    /// Width of the inner content (without the card's horizontal padding).
    static let widgetWidth: CGFloat = 156
    /// Width of the outer card including its horizontal padding. Used by the
    /// parent for screen-edge layout math.
    static let widgetOuterWidth: CGFloat = 188

    static func estimatedHeight(for state: SlotState) -> CGFloat {
        switch state {
        case .naming: return 248
        case .generating: return 200
        case .accepted: return 192
        case .readyForReview: return 220
        case .failed: return 216
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            thumbnailArea
            footerArea
        }
        .frame(width: Self.widgetWidth)
        .padding(.top, 16)
        .padding([.bottom, .horizontal], 16)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        .overlay(alignment: .topTrailing) {
            cornerButton
                .offset(x: 10, y: -10)
        }
        .animation(.smooth(duration: 0.25), value: slot.state.id)
    }

    private var isAccepted: Bool {
        if case .accepted = slot.state { return true }
        return false
    }

    private var cornerButton: some View {
        Button(action: { isAccepted ? onSaveAccepted() : onDismiss() }) {
            ZStack {
                if isAccepted {
                    Circle().fill(AppPalette.uploadGlow)
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .shadow(color: AppPalette.uploadGlow.opacity(0.32), radius: 10, y: 4)
                        .shadow(color: AppPalette.cardShadow, radius: 8, y: 4)
                } else {
                    Color.clear.appCircle()
                }
                Image(systemName: isAccepted ? "checkmark" : "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isAccepted ? .white : AppPalette.iconPrimary)
                    .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isAccepted)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var thumbnailArea: some View {
        ZStack {
            // Click-crop background. Stays mounted across all states so
            // it crossfades into the AI thumbnail rather than hard-cutting
            // to it. Opacity drops once the AI thumb takes over.
            cropImageWithBackground
                .opacity(showsClickCrop ? 1 : 0)

            // Generating veil — sits over the click crop while the
            // model produces the thumbnail.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .opacity(isGenerating ? 1 : 0)
            if isGenerating {
                ProgressView()
                    .tint(AppPalette.textMuted)
                    .transition(.opacity)
            }

            // AI thumbnail (review/accepted). Mounted via `if let` so we
            // only carry the UIImage when needed; .transition gives it a
            // soft fade in/out as the state flips.
            if let aiThumb = aiThumbnail {
                Image(uiImage: aiThumb)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            }

            if isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
    }

    private var showsClickCrop: Bool {
        switch slot.state {
        case .naming, .generating: return true
        default: return false
        }
    }

    private var isGenerating: Bool {
        if case .generating = slot.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = slot.state { return true }
        return false
    }

    private var aiThumbnail: UIImage? {
        switch slot.state {
        case .readyForReview(let img), .accepted(let img): return img
        default: return nil
        }
    }

    private var cropImageWithBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.55))
            Image(uiImage: slot.previewCrop)
                .resizable()
                .scaledToFill()
                .frame(width: Self.thumbSize, height: Self.thumbSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private var footerArea: some View {
        switch slot.state {
        case .naming:
            VStack(spacing: 10) {
                TextField(
                    "",
                    text: Binding(
                        get: { slot.name },
                        set: { onNameChange($0) }
                    ),
                    prompt: Text(slot.placeholderHint)
                        .foregroundStyle(AppPalette.textFaint)
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.textStrong)
                .textInputAutocapitalization(.words)
                .focused($focusedID, equals: slot.id)
                .submitLabel(.done)
                .onSubmit { onCommitName() }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.textFaint.opacity(0.3), lineWidth: 0.75))

                let isEmpty = slot.name.trimmingCharacters(in: .whitespaces).isEmpty
                Button(action: onCommitName) {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isEmpty ? AppPalette.textFaint : AppPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .appCapsule()
                        // AI-action accent (matches Quick Add halo).
                        .shadow(
                            color: isEmpty ? .clear : AppPalette.aiAccent.opacity(0.22),
                            radius: 10, y: 0
                        )
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .animation(.easeInOut(duration: 0.18), value: isEmpty)
            }
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(AppPalette.textMuted)
                Text("Generating…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .frame(height: 44)
        case .readyForReview:
            HStack(spacing: 10) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppPalette.iconPrimary)
                        .frame(width: 44, height: 44)
                        .appCircle()
                }
                .buttonStyle(.plain)

                Button(action: onAccept) {
                    ZStack {
                        Circle()
                            .fill(AppPalette.uploadGlow)
                            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                            .shadow(color: AppPalette.uploadGlow.opacity(0.32), radius: 10, y: 4)
                            .shadow(color: AppPalette.cardShadow, radius: 8, y: 4)
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .accepted:
            Text(slot.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        case .failed:
            Button(action: onRetry) {
                Text("Try again")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .appCapsule()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Trimmed product thumbnail

/// Loads a product image and trims its transparent margins so the
/// garment fills the frame — product thumbnails are flat-lays with
/// baked-in transparent padding that otherwise makes them look small
/// and float in their box. The frame is fixed, so the pill doesn't
/// resize when the image lands; the trim runs off the main thread.
private struct TrimmedProductThumbnail: View {
    let url: URL?
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // Small inset so the alpha-trimmed garment doesn't
                    // sit edge-to-edge — gives the pill breathing room.
                    .padding(5)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = UIImage(data: data) else { return }
        let trimmed = await Task.detached(priority: .userInitiated) {
            raw.trimmingTransparentMargins()
        }.value
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.15)) { image = trimmed }
        }
    }
}

private extension UIImage {
    /// Crop away the near-transparent border so the opaque content
    /// fills the image. Returns self if it has no croppable margin.
    func trimmingTransparentMargins(alphaThreshold: UInt8 = 8) -> UIImage {
        guard let cg = cgImage else { return self }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return self }
        let bpp = 4
        let bpr = w * bpp
        var data = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w where data[row + x * bpp + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return self }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: rect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

import SwiftUI
import UIKit

/// Tap → name → generate flow for product thumbnails. We feed the whole outfit
/// to nano-banana along with the user-supplied garment name so the model has
/// full context (length, cut, occlusions) — no segmentation step.
struct AutoDetectProductsView: View {
    let sourceImage: UIImage
    let userId: UUID
    var existingProducts: [Product] = []
    /// Label for the dismiss-without-saving action. Defaults to "Cancel" for
    /// user-initiated entry points; the upload pipeline (which auto-presents
    /// the sheet) uses "Skip / Add later" so it's clear this step is optional.
    var cancelLabel: String = "Cancel"
    var onDone: ([Product]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var slots: [GarmentSlot] = []
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var subjectExtents: SubjectExtents?
    @FocusState private var focusedSlotID: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.groupedBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    hintBar
                    canvasArea
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar { toolbarContent }
            .alert("Couldn't save", isPresented: errorBinding) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .task {
                if subjectExtents == nil {
                    subjectExtents = SubjectExtents.build(from: sourceImage)
                }
            }
            .onDisappear {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    // MARK: - Hint

    private var hintBar: some View {
        Text(hintText)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(AppPalette.textFaint)
            .multilineTextAlignment(.center)
            .padding(.vertical, LayoutMetrics.xSmall)
            .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    private var hintText: String {
        let hasNamingSlot = slots.contains { if case .naming = $0.state { return true }; return false }
        if hasNamingSlot { return "NAME EACH ITEM, THEN TAP DONE" }
        if slots.isEmpty { return "TAP A GARMENT ON THE OUTFIT" }
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

                Color.clear
                    .frame(width: imageRect.width, height: imageRect.height)
                    .contentShape(Rectangle())
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { value in
                            handleTap(at: value.location, imageRect: imageRect)
                        }
                    )

                let positions = computeAllPositions(canvasSize: geo.size, imageRect: imageRect)
                ForEach(slots) { slot in
                    SlotWidgetView(
                        slot: slot,
                        focusedID: $focusedSlotID,
                        onNameChange: { updateName(slot.id, $0) },
                        onCommitName: { Task { await commitName(slot.id) } },
                        onAccept: { acceptSlot(slot.id) },
                        onRetry: { Task { await retryGeneration(slot.id) } },
                        onDismiss: { dismissSlot(slot.id) }
                    )
                    .position(positions[slot.id] ?? .zero)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: slot.state.id)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(cancelLabel) {
                onDone(existingProducts)
                dismiss()
            }
            .foregroundStyle(AppPalette.textMuted)
        }
        ToolbarItem(placement: .principal) {
            Text("ADD PRODUCTS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await saveAccepted() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save").fontWeight(.semibold).foregroundStyle(AppPalette.textStrong)
                }
            }
            .disabled(!hasAcceptedSlot || isSaving)
        }
    }

    private var hasAcceptedSlot: Bool {
        slots.contains { if case .accepted = $0.state { return true }; return false }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    // MARK: - Geometry

    private func computeImageRect(in canvasSize: CGSize) -> CGRect {
        let aspect = sourceImage.size.width / max(sourceImage.size.height, 1)
        let maxWidth = canvasSize.width
        let maxHeight = canvasSize.height - LayoutMetrics.small
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
    private func computeAllPositions(canvasSize: CGSize, imageRect: CGRect) -> [UUID: CGPoint] {
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
            let bottomPad = canvasSize.height - halfHeight - 8
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
        slots.append(slot)
        focusedSlotID = slot.id
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

    private func cropPreview(around point: CGPoint, from image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let cgW = CGFloat(cg.width)
        let cgH = CGFloat(cg.height)
        let cropSize: CGFloat = min(cgW, cgH) * 0.35
        let halfSize = cropSize / 2
        let originX = max(0, min(point.x - halfSize, cgW - cropSize))
        let originY = max(0, min(point.y - halfSize, cgH - cropSize))
        let rect = CGRect(x: originX, y: originY, width: cropSize, height: cropSize)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Pipeline

    private func updateName(_ slotID: UUID, _ newName: String) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[i].name = newName
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
        slots.removeAll { $0.id == slotID }
    }

    // MARK: - Save

    private func saveAccepted() async {
        await MainActor.run { isSaving = true }
        defer { Task { @MainActor in isSaving = false } }

        var newProducts: [Product] = []
        for slot in slots {
            guard case let .accepted(thumb) = slot.state else { continue }
            do {
                let url = try await ProductThumbnailUploadService.upload(thumb, userId: userId)
                newProducts.append(Product(
                    name: slot.name,
                    price: nil,
                    image: url,
                    shopLink: nil,
                    productId: nil,
                    tags: nil
                ))
            } catch {
                await MainActor.run { saveError = error.localizedDescription }
                return
            }
        }
        await MainActor.run {
            onDone(existingProducts + newProducts)
            dismiss()
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

    private static let thumbSize: CGFloat = 100
    private static let cornerRadius: CGFloat = 16
    /// Width of the inner content (without the card's horizontal padding).
    static let widgetWidth: CGFloat = 128
    /// Width of the outer card including its horizontal padding. Used by the
    /// parent for screen-edge layout math.
    static let widgetOuterWidth: CGFloat = 152

    static func estimatedHeight(for state: SlotState) -> CGFloat {
        switch state {
        case .naming: return 188
        case .generating, .accepted: return 144
        case .readyForReview, .failed: return 168
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            thumbnailArea
            footerArea
        }
        .frame(width: Self.widgetWidth)
        .padding(.top, 14)
        .padding([.bottom, .horizontal], 12)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        .overlay(alignment: .topTrailing) {
            // Anchored to the outer card corner and sticks out slightly so it
            // reads as a control for the whole card, not the inner thumbnail.
            cornerButton
                .offset(x: 8, y: -8)
        }
    }

    private var isAccepted: Bool {
        if case .accepted = slot.state { return true }
        return false
    }

    private var cornerButton: some View {
        Button(action: onDismiss) {
            Image(systemName: isAccepted ? "checkmark" : "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isAccepted ? .white : AppPalette.iconPrimary)
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(isAccepted ? AppPalette.uploadGlow : Color.white)
                }
                .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                .shadow(color: AppPalette.cardShadow, radius: 12, y: 6)
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isAccepted)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.55))

            switch slot.state {
            case .naming:
                Image(uiImage: slot.previewCrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            case .generating:
                Image(uiImage: slot.previewCrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                Color.white.opacity(0.55)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                ProgressView().tint(AppPalette.textMuted)
            case .readyForReview(let thumb), .accepted(let thumb):
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var footerArea: some View {
        switch slot.state {
        case .naming:
            VStack(spacing: 8) {
                TextField(
                    "",
                    text: Binding(
                        get: { slot.name },
                        set: { onNameChange($0) }
                    ),
                    prompt: Text(slot.placeholderHint)
                        .foregroundStyle(AppPalette.textMuted)
                )
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textStrong)
                .textInputAutocapitalization(.words)
                .focused($focusedID, equals: slot.id)
                .submitLabel(.done)
                .onSubmit { onCommitName() }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AppPalette.textFaint.opacity(0.4), lineWidth: 0.75)
                )

                Button(action: onCommitName) {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(slot.name.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? AppPalette.textFaint.opacity(0.5)
                                      : AppPalette.textStrong)
                        )
                        .foregroundStyle(slot.name.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? AppPalette.textPrimary
                                         : .white)
                }
                .buttonStyle(.plain)
                .disabled(slot.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .generating:
            Text("Generating…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppPalette.textPrimary)
        case .readyForReview:
            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white))
                        .foregroundStyle(AppPalette.textPrimary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(AppPalette.textFaint.opacity(0.45), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 11).fill(AppPalette.textStrong))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        case .accepted:
            Text(slot.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
        case .failed:
            Button(action: onRetry) {
                Text("Try again")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    .foregroundStyle(AppPalette.textPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppPalette.textFaint.opacity(0.4), lineWidth: 0.75)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

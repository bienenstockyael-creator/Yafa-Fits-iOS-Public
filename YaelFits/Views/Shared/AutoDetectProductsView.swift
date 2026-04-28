import SwiftUI
import UIKit

/// Tap-to-segment flow for auto-generating product thumbnails from a
/// background-removed outfit selfie.
///
/// User taps a garment → SAM2 crops it → user types a label → nano-banana
/// produces a flat-lay thumbnail → user accepts. Repeat for each garment.
/// On done, accepted products are returned to the caller.
struct AutoDetectProductsView: View {
    let sourceImage: UIImage
    let userId: UUID
    var existingProducts: [Product] = []
    var onDone: ([Product]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detected: [Product] = []
    @State private var pending: PendingSegment?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.groupedBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    instructionsBar
                    tappableImage
                    detectedList
                }
            }
            .navigationTitle("Add products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onDone(existingProducts)
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.textMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone(existingProducts + detected)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(detected.isEmpty)
                }
            }
            .sheet(item: $pending) { p in
                LabelAndGenerateSheet(pending: p, userId: userId) { product in
                    if let product { detected.append(product) }
                    pending = nil
                }
            }
            .alert("Couldn't add product", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .onAppear {
            detected = []
        }
    }

    private var instructionsBar: some View {
        Text("Tap each garment to add it as a product")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LayoutMetrics.xSmall)
            .background(AppPalette.cardFill)
    }

    private var tappableImage: some View {
        GeometryReader { geo in
            let displaySize = aspectFit(image: sourceImage.size, in: geo.size)
            let imageOrigin = CGPoint(
                x: (geo.size.width - displaySize.width) / 2,
                y: (geo.size.height - displaySize.height) / 2
            )

            Image(uiImage: sourceImage)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    let location = value.location
                    let inside = CGRect(origin: imageOrigin, size: displaySize).contains(location)
                    guard inside else { return }
                    let xRatio = (location.x - imageOrigin.x) / displaySize.width
                    let yRatio = (location.y - imageOrigin.y) / displaySize.height
                    let pixelX = xRatio * sourceImage.size.width
                    let pixelY = yRatio * sourceImage.size.height
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await beginSegment(at: CGPoint(x: pixelX, y: pixelY)) }
                })
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var detectedList: some View {
        if !detected.isEmpty {
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LayoutMetrics.xSmall) {
                        ForEach(detected) { p in
                            VStack(spacing: 4) {
                                AsyncImage(url: URL(string: p.image)) { phase in
                                    if case .success(let img) = phase { img.resizable().scaledToFit() }
                                    else { Color(white: 0.95) }
                                }
                                .frame(width: 60, height: 60)
                                .background(Color(white: 0.96))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(p.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppPalette.textSecondary)
                                    .lineLimit(1)
                                    .frame(width: 60)
                            }
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.vertical, LayoutMetrics.xSmall)
                }
                .background(AppPalette.cardFill)
            }
        }
    }

    // MARK: - Segmentation

    private func beginSegment(at point: CGPoint) async {
        let segment = PendingSegment(point: point, sourceImage: sourceImage, croppedGarment: nil)
        pending = segment
    }

    private func aspectFit(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

private struct PendingSegment: Identifiable {
    let id = UUID()
    let point: CGPoint
    let sourceImage: UIImage
    var croppedGarment: UIImage?
}

// MARK: - Label & generate sheet

private struct LabelAndGenerateSheet: View {
    let pending: PendingSegment
    let userId: UUID
    var onFinish: (Product?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .segmenting
    @State private var croppedGarment: UIImage?
    @State private var generatedThumbnail: UIImage?
    @State private var label: String = ""
    @State private var statusDetail: String = "Outlining the garment…"

    enum Phase { case segmenting, labeling, generating, reviewing, uploading, error }

    var body: some View {
        VStack(spacing: LayoutMetrics.medium) {
            previewArea
            content
            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.screenPadding)
        .background(AppPalette.groupedBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .task { await runSegmentation() }
    }

    private var previewArea: some View {
        HStack(spacing: LayoutMetrics.small) {
            previewBox(image: croppedGarment, label: "Detected")
            Image(systemName: "arrow.right")
                .foregroundStyle(AppPalette.textFaint)
            previewBox(image: generatedThumbnail, label: "Thumbnail")
        }
    }

    private func previewBox(image: UIImage?, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.96))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                } else {
                    ProgressView().tint(AppPalette.textFaint)
                }
            }
            .frame(width: 110, height: 140)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textFaint)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .segmenting, .generating, .uploading:
            VStack(spacing: 8) {
                ProgressView()
                Text(statusDetail).font(.system(size: 12)).foregroundStyle(AppPalette.textMuted)
            }
        case .labeling:
            VStack(spacing: LayoutMetrics.small) {
                TextField("Name this item (e.g. Striped Sweater)", text: $label)
                    .textInputAutocapitalization(.words)
                    .padding()
                    .background(AppPalette.cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    Task { await runGeneration() }
                } label: {
                    Text("Generate thumbnail").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.textStrong)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { onFinish(nil); dismiss() }
                    .foregroundStyle(AppPalette.textMuted)
            }
        case .reviewing:
            VStack(spacing: LayoutMetrics.small) {
                Button {
                    Task { await accept() }
                } label: {
                    Text("Add to outfit").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.textStrong)

                Button("Try again") { Task { await runGeneration() } }
                Button("Cancel") { onFinish(nil); dismiss() }
                    .foregroundStyle(AppPalette.textMuted)
            }
        case .error:
            VStack(spacing: LayoutMetrics.small) {
                Text(statusDetail).font(.system(size: 13)).foregroundStyle(AppPalette.textPrimary).multilineTextAlignment(.center)
                Button("Close") { onFinish(nil); dismiss() }
            }
        }
    }

    // MARK: - Async ops

    private func runSegmentation() async {
        do {
            let cropped = try await FalSegmentationService.shared.segmentGarment(
                in: pending.sourceImage,
                at: pending.point,
                onUpdate: { progress in
                    await MainActor.run { statusDetail = progress.detail }
                }
            )
            await MainActor.run {
                self.croppedGarment = cropped
                self.phase = .labeling
            }
        } catch {
            await MainActor.run {
                self.statusDetail = error.localizedDescription
                self.phase = .error
            }
        }
    }

    private func runGeneration() async {
        guard let garment = croppedGarment else { return }
        await MainActor.run {
            phase = .generating
            generatedThumbnail = nil
            statusDetail = "Generating thumbnail…"
        }
        do {
            let thumb = try await FalProductThumbnailService.shared.generateThumbnail(
                from: garment,
                label: label,
                onUpdate: { progress in
                    await MainActor.run { statusDetail = progress.detail }
                }
            )
            await MainActor.run {
                self.generatedThumbnail = thumb
                self.phase = .reviewing
            }
        } catch {
            await MainActor.run {
                self.statusDetail = error.localizedDescription
                self.phase = .error
            }
        }
    }

    private func accept() async {
        guard let thumb = generatedThumbnail else { return }
        await MainActor.run {
            phase = .uploading
            statusDetail = "Saving thumbnail…"
        }
        do {
            let imageURL = try await ProductThumbnailUploadService.upload(thumb, userId: userId)
            let product = Product(
                name: label.trimmingCharacters(in: .whitespaces),
                price: nil,
                image: imageURL,
                shopLink: nil,
                productId: nil,
                tags: nil
            )
            await MainActor.run {
                onFinish(product)
                dismiss()
            }
        } catch {
            await MainActor.run {
                statusDetail = error.localizedDescription
                phase = .error
            }
        }
    }
}

import SwiftUI
import UIKit

/// Tap-to-segment flow for auto-generating product thumbnails from a
/// background-removed outfit selfie.
///
/// Flow per garment:
///   1. Tap a garment on the image
///   2. SAM2 runs; the detected region is highlighted on the image
///   3. User can re-tap to re-segment, or hit Continue
///   4. Label modal asks for the garment name
///   5. nano-banana generates a flat-lay thumbnail using the label
///   6. User accepts the thumbnail; it's uploaded and added to detected
///   7. Repeat for each garment, then Done returns all to the caller.
struct AutoDetectProductsView: View {
    let sourceImage: UIImage
    let userId: UUID
    var existingProducts: [Product] = []
    var onDone: ([Product]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detected: [Product] = []
    @State private var phase: Phase = .idle
    @State private var statusDetail: String = ""
    @State private var promptingForLabel = false
    @State private var pendingLabel: String = ""

    enum Phase {
        case idle
        case segmenting
        case previewingMask(FalSegmentationResult)
        case generating(FalSegmentationResult)
        case reviewingThumbnail(FalSegmentationResult, UIImage, String)
        case error
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.groupedBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    instructionsBar
                    tappableImage
                    bottomBar
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
            .sheet(isPresented: $promptingForLabel) { labelSheet }
        }
    }

    // MARK: - Top instructions

    private var instructionsBar: some View {
        Text(currentInstruction)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppPalette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LayoutMetrics.xSmall)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .background(AppPalette.cardFill)
    }

    private var currentInstruction: String {
        switch phase {
        case .idle: return "Tap a garment to detect it"
        case .segmenting: return statusDetail.isEmpty ? "Detecting…" : statusDetail
        case .previewingMask: return "Looks right? Continue or tap again to re-detect"
        case .generating: return statusDetail.isEmpty ? "Generating thumbnail…" : statusDetail
        case .reviewingThumbnail: return "Looks right? Add it or try again"
        case .error: return statusDetail
        }
    }

    // MARK: - Tappable image with overlay

    private var tappableImage: some View {
        GeometryReader { geo in
            let displaySize = aspectFit(image: sourceImage.size, in: geo.size)
            let imageOrigin = CGPoint(
                x: (geo.size.width - displaySize.width) / 2,
                y: (geo.size.height - displaySize.height) / 2
            )

            ZStack {
                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Highlight overlay aligned to the displayed image
                if case let .previewingMask(result) = phase {
                    Image(uiImage: result.highlightOverlay)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if case let .generating(result) = phase {
                    Image(uiImage: result.highlightOverlay)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                        .opacity(0.5)
                }

                if case .segmenting = phase {
                    busyOverlay
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let location = value.location
                    let inside = CGRect(origin: imageOrigin, size: displaySize).contains(location)
                    guard inside else { return }
                    guard isTapAccepted else { return }
                    let xRatio = (location.x - imageOrigin.x) / displaySize.width
                    let yRatio = (location.y - imageOrigin.y) / displaySize.height
                    let pixelX = xRatio * sourceImage.size.width
                    let pixelY = yRatio * sourceImage.size.height
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await runSegmentation(at: CGPoint(x: pixelX, y: pixelY)) }
                }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var isTapAccepted: Bool {
        switch phase {
        case .idle, .previewingMask, .error: return true
        default: return false
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(statusDetail).font(.system(size: 12)).foregroundStyle(.white)
            }
            .padding(LayoutMetrics.medium)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch phase {
        case .previewingMask:
            HStack(spacing: LayoutMetrics.small) {
                Button("Try another tap") { phase = .idle }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.textMuted)
                Button {
                    pendingLabel = ""
                    promptingForLabel = true
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.textStrong)
            }
            .padding(LayoutMetrics.medium)
            .background(AppPalette.cardFill)

        case let .reviewingThumbnail(_, thumbnail, label):
            VStack(spacing: LayoutMetrics.xSmall) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .background(Color(white: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(label).font(.system(size: 11)).foregroundStyle(AppPalette.textMuted)
                HStack(spacing: LayoutMetrics.small) {
                    Button("Try again") { phase = .idle }
                        .buttonStyle(.bordered)
                        .tint(AppPalette.textMuted)
                    Button {
                        Task { await acceptCurrentThumbnail() }
                    } label: {
                        Text("Add to outfit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.textStrong)
                }
            }
            .padding(LayoutMetrics.medium)
            .background(AppPalette.cardFill)

        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusDetail.isEmpty ? "Generating thumbnail…" : statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .padding(LayoutMetrics.medium)
            .background(AppPalette.cardFill)

        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(statusDetail).font(.system(size: 12)).foregroundStyle(AppPalette.textPrimary)
                Spacer()
                Button("Reset") { phase = .idle }
            }
            .padding(LayoutMetrics.medium)
            .background(AppPalette.cardFill)

        default:
            EmptyView()
        }
    }

    // MARK: - Detected products strip

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

    // MARK: - Label sheet

    private var labelSheet: some View {
        VStack(spacing: LayoutMetrics.medium) {
            Text("Name this item")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
            TextField("e.g. Striped Sweater", text: $pendingLabel)
                .textInputAutocapitalization(.words)
                .padding()
                .background(AppPalette.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Button {
                let label = pendingLabel.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, case let .previewingMask(result) = phase else { return }
                promptingForLabel = false
                Task { await runGeneration(result: result, label: label) }
            } label: {
                Text("Generate thumbnail").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.textStrong)
            .disabled(pendingLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") {
                promptingForLabel = false
            }
            .foregroundStyle(AppPalette.textMuted)
            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.screenPadding)
        .presentationDetents([.height(280)])
    }

    // MARK: - Async ops

    private func runSegmentation(at point: CGPoint) async {
        await MainActor.run {
            statusDetail = "SAM2 is locating the garment."
            phase = .segmenting
        }
        do {
            let result = try await FalSegmentationService.shared.segmentGarment(
                in: sourceImage,
                at: point,
                onUpdate: { p in await MainActor.run { statusDetail = p.detail } }
            )
            await MainActor.run {
                phase = .previewingMask(result)
                statusDetail = ""
            }
        } catch {
            await MainActor.run {
                statusDetail = error.localizedDescription
                phase = .error
            }
        }
    }

    private func runGeneration(result: FalSegmentationResult, label: String) async {
        await MainActor.run {
            statusDetail = "nano-banana is generating."
            phase = .generating(result)
        }
        do {
            let thumbnail = try await FalProductThumbnailService.shared.generateThumbnail(
                from: result.croppedGarment,
                label: label,
                onUpdate: { p in await MainActor.run { statusDetail = p.detail } }
            )
            await MainActor.run {
                phase = .reviewingThumbnail(result, thumbnail, label)
                statusDetail = ""
            }
        } catch {
            await MainActor.run {
                statusDetail = error.localizedDescription
                phase = .error
            }
        }
    }

    private func acceptCurrentThumbnail() async {
        guard case let .reviewingThumbnail(_, thumbnail, label) = phase else { return }
        await MainActor.run {
            statusDetail = "Saving thumbnail…"
            phase = .generating(.init(croppedGarment: thumbnail, highlightOverlay: thumbnail))
        }
        do {
            let imageURL = try await ProductThumbnailUploadService.upload(thumbnail, userId: userId)
            let product = Product(
                name: label,
                price: nil,
                image: imageURL,
                shopLink: nil,
                productId: nil,
                tags: nil
            )
            await MainActor.run {
                detected.append(product)
                phase = .idle
                statusDetail = ""
            }
        } catch {
            await MainActor.run {
                statusDetail = error.localizedDescription
                phase = .error
            }
        }
    }

    // MARK: - Helpers

    private func aspectFit(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

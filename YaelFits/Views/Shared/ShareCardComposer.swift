import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

// MARK: - Template definition

private let cardGray = Color(white: 0.918) // matches Mono PNG background exactly
private let cardBlue = Color(red: 24/255, green: 3/255, blue: 254/255) // #1803FE

enum ShareCardTemplate: Int, CaseIterable, Identifiable, Hashable {
    // Dynamic code templates
    case monoLive     = 5
    case electricLive = 6
    case ootdLive     = 7
    // Two-layer PNG templates
    case layered1 = 2
    case layered2 = 3
    case layered3 = 4

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .monoLive:     return "Mono"
        case .electricLive: return "Electric"
        case .ootdLive:     return "OOTD"
        case .layered1:     return "OOTD Classic"
        case .layered2:     return "Fits"
        case .layered3:     return "Stats"
        }
    }

    /// Dynamic code-based templates — render date layers in SwiftUI.
    var isDynamic: Bool {
        self == .monoLive || self == .electricLive || self == .ootdLive
    }

    /// Whether this dynamic template uses a back PNG instead of a solid color.
    var usesBackPNG: Bool { false }

    /// Background fill for dynamic templates.
    var dynamicBackground: Color { cardGray }

    /// Back PNG — fills the card behind the outfit for PNG templates.
    var backImageName: String {
        switch self {
        case .ootdLive:  return "card-layered1-back"
        case .layered1:  return "card-layered1-back"
        case .layered2:  return "card-layered2-back"
        case .layered3:  return "card-layered3-back"
        default:         return "card-mono"
        }
    }

    /// Front PNG — rendered on top of the outfit. nil for dynamic/single-layer.
    var frontImageName: String? {
        switch self {
        case .layered1: return "card-layered1-front"
        case .layered2: return "card-layered2-front"
        case .layered3: return "card-layered3-front"
        default:        return nil
        }
    }

    var frontLayerIsFrosted: Bool { self == .layered2 }
}

// MARK: - Frosted shape view
// Uses CALayer.mask on a UIVisualEffectView subclass so the mask is applied
// in layoutSubviews — at that point the view has its real bounds, not .zero.

private final class FrostedMaskUIView: UIVisualEffectView {
    var maskImage: UIImage? { didSet { applyMask() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyMask()
    }

    private func applyMask() {
        guard let img = maskImage, !bounds.isEmpty else { return }
        let ml = (layer.mask as? CALayer) ?? CALayer()
        ml.frame = bounds
        ml.contents = img.cgImage
        ml.contentsGravity = .resizeAspectFill
        layer.mask = ml
    }
}

private struct FrostedShapeView: UIViewRepresentable {
    let maskImage: UIImage

    func makeUIView(context: Context) -> FrostedMaskUIView {
        let v = FrostedMaskUIView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
        v.maskImage = maskImage
        return v
    }

    func updateUIView(_ uiView: FrostedMaskUIView, context: Context) {
        uiView.maskImage = maskImage
    }
}

// MARK: - Composer view

struct ShareCardComposer: View {
    let outfit: Outfit
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplate: ShareCardTemplate = .monoLive
    @State private var motionManager = CMMotionManager()
    @State private var gyroPitch: Double = 0
    @State private var gyroRoll: Double = 0
    @State private var gyroFrameIndex: Int = 0
    @State private var gyroImage: UIImage?
    @State private var isDraggingOutfit = false
    @State private var gyroSuspended = false
    @State private var gyroResumeTask: Task<Void, Never>?
    @State private var gyroRollOffset: Double = 0
    @State private var gyroBaseFrame: Int = 0
    @State private var isExportingVideo = false
    @State private var exportError: String?
    private let storyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var cardVisible = false
    @State private var templateSlideEdge: Edge = .trailing

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 28)

                Spacer(minLength: 16)

                cardArea
                    .frame(height: 520)
                    .padding(.vertical, -20)
                    .offset(y: cardVisible ? 0 : 72)
                    .opacity(cardVisible ? 1 : 0)
                    .scaleEffect(cardVisible ? 1 : 0.88)
                    .rotation3DEffect(
                        .degrees(cardVisible ? 0 : 18),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.4
                    )

                templatePicker
                    .padding(.top, 18)
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardVisible ? 0 : 20)

                Spacer(minLength: 16)

                shareActions
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardVisible ? 0 : 16)
            }
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            storyHaptic.prepare()
            startGyroscope()
            withAnimation(
                .spring(response: 0.58, dampingFraction: 0.70)
                .delay(0.06)
            ) {
                cardVisible = true
            }
        }
        .onDisappear { stopGyroscope() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("CHOOSE YOUR SHAREABLE CARD")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    // MARK: - Card area

    private var cardArea: some View {
        ZStack {
            // Back layer — PNG or dynamic code background.
            // For dynamic templates the number is overlaid ON the Color so
            // the Color (not the text) determines the card size.
            Group {
                if selectedTemplate == .ootdLive {
                    ZStack {
                        Color.white
                        LinearGradient(
                            colors: [Color(red: 0.737, green: 0.737, blue: 0.737), .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .opacity(0.4)
                    }
                    .overlay(ootdBackLayer)
                } else if selectedTemplate.isDynamic {
                    selectedTemplate.dynamicBackground
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            // Renders text to a tight ink-bounds image, then centers
                            // that image — visually perfect for any combination of digits.
                            Canvas { context, size in
                                let isElec = selectedTemplate == .electricLive
                                let fontName = isElec ? "PlayfairDisplay-Italic" : "Inter28pt-SemiBold"
                                let fontSize: CGFloat = isElec ? 457.2 : 304
                                let kern: CGFloat   = isElec ? -50.3 : -21.3
                                let color = UIColor(dynamicColor)

                                if let img = textToImage(
                                    outfitDayNumber,
                                    fontName: fontName, fontSize: fontSize,
                                    kern: kern, color: color
                                ) {
                                    let rect = CGRect(
                                        x: size.width  / 2 - img.size.width  / 2,
                                        y: size.height / 2 - img.size.height / 2,
                                        width:  img.size.width,
                                        height: img.size.height
                                    )
                                    context.draw(Image(uiImage: img), in: rect)
                                }
                            }
                        )
                } else if let uiImage = UIImage(named: selectedTemplate.backImageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.92)
                }
            }
            .id("back-\(selectedTemplate.id)")
            .transition(.asymmetric(
                insertion: .move(edge: templateSlideEdge),
                removal: .move(edge: templateSlideEdge == .trailing ? .leading : .trailing)
            ))
            .allowsHitTesting(false)

            // Outfit stays fixed
            outfitLayer
                .allowsHitTesting(true)

            // Dynamic date front layer
            if selectedTemplate.isDynamic && selectedTemplate != .ootdLive {
                dynamicDateFrontLayer
            }
            if selectedTemplate == .ootdLive {
                ootdDynamicFrontLayer
                    .id("date-front-\(selectedTemplate.id)")
                    .transition(.asymmetric(
                        insertion: .move(edge: templateSlideEdge),
                        removal: .move(edge: templateSlideEdge == .trailing ? .leading : .trailing)
                    ))
                    .allowsHitTesting(false)
            }

            // PNG front layers
            Group {
                if selectedTemplate.frontLayerIsFrosted,
                   let frontName = selectedTemplate.frontImageName,
                   let maskImage = solidAlphaMask(for: frontName) {
                    FrostedShapeView(maskImage: maskImage)
                }
                if let frontName = selectedTemplate.frontImageName,
                   let uiImage = UIImage(named: frontName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .id("front-\(selectedTemplate.id)")
            .transition(.asymmetric(
                insertion: .move(edge: templateSlideEdge),
                removal: .move(edge: templateSlideEdge == .trailing ? .leading : .trailing)
            ))
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 10)
        .shadow(color: Color.black.opacity(0.06), radius: 48, y: 22)
        .rotation3DEffect(
            .degrees(gyroPitch * 8),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.4
        )
        .rotation3DEffect(
            .degrees(gyroRoll * 8),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.4
        )
    }

    // MARK: - Text-to-image (ink-bounds centering)

    /// Renders `string` into a UIImage cropped to its exact ink bounds (visible pixels only).
    /// Centering this image = visually perfect centering regardless of digit widths.
    private func textToImage(
        _ string: String,
        fontName: String, fontSize: CGFloat,
        kern: CGFloat, color: UIColor
    ) -> UIImage? {
        guard let ctFont = CTFontCreateWithName(fontName as CFString, fontSize, nil) as CTFont? else {
            return nil
        }
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
            kCTKernAttributeName as NSAttributedString.Key: kern as NSNumber
        ]
        let attrStr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        // Measure actual glyph ink bounds (not typographic bounds)
        // nil context = CoreText uses default metrics, gives correct ink bounds
        var glyphBounds = CTLineGetImageBounds(line, nil)

        guard glyphBounds.width > 0, glyphBounds.height > 0 else { return nil }

        let pad: CGFloat = 4
        let imgW = ceil(glyphBounds.width  + pad * 2)
        let imgH = ceil(glyphBounds.height + pad * 2)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH))
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            // CoreText draws with Y-up; flip to UIKit's Y-down coordinate space
            cgCtx.translateBy(x: 0, y: imgH)
            cgCtx.scaleBy(x: 1, y: -1)
            // Offset so glyph origin maps to our padding
            cgCtx.translateBy(x: pad - glyphBounds.origin.x,
                               y: pad - glyphBounds.origin.y)
            CTLineDraw(line, cgCtx)
            cgCtx.restoreGState()
        }
    }

    // MARK: - Dynamic date layers (monoLive / electricLive)

    private var dynamicColor: Color {
        selectedTemplate == .electricLive ? cardBlue : .black
    }

    private var outfitDayNumber: String {
        outfit.parsedDate?.formatted(.dateTime.day(.twoDigits)) ?? "--"
    }
    private var outfitMonthName: String {
        outfit.parsedDate?.formatted(.dateTime.month(.wide)) ?? "Unknown"
    }
    private var outfitWeekday: String {
        outfit.parsedDate?.formatted(.dateTime.weekday(.wide)) ?? "—"
    }


    private var dynamicDateFrontLayer: some View {
        // Use GeometryReader for precise positioning matching the reference design:
        // Month center at ~5% from top, weekday center at ~5% from bottom
        GeometryReader { geo in
            // Electric ✦: Inter Medium Italic 21pt, -0.865 tracking, 5% from edges
            // Mono ✦:     Inter Medium Italic 52.151pt, -1.565 tracking, 8% from edges
            //             (larger font needs more clearance from edge)
            let isElectric = selectedTemplate == .electricLive
            let fontSize: CGFloat = isElectric ? 21 : 36
            let tracking: CGFloat = isElectric ? -0.865 : -1.565
            let yPct: CGFloat = isElectric ? 0.05 : 0.08
            let font = Font.custom("Inter28pt-MediumItalic", size: fontSize)

            // .position() centers the text's own bounding box at the given point
            Text(outfitMonthName)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(dynamicColor)
                .position(x: geo.size.width / 2, y: geo.size.height * yPct)

            Text(outfitWeekday)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(dynamicColor)
                .position(x: geo.size.width / 2, y: geo.size.height * (1 - yPct))
        }
    }

    // MARK: - OOTD dynamic front layer

    private var outfitDayOrdinal: String {
        guard let date = outfit.parsedDate else { return "--" }
        let day = Calendar.current.component(.day, from: date)
        let suffix: String
        switch day {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    private let ootdInset: CGFloat = 24

    // Behind outfit: OOTD + YAFA FITS
    private var ootdBackLayer: some View {
        GeometryReader { geo in
            let textWidth = geo.size.width - ootdInset * 2

            VStack(alignment: .leading, spacing: 0) {
                Text("OOTD")
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 0.42))
                    .foregroundStyle(cardBlue)
                    .frame(width: textWidth, alignment: .center)

                Text("YAFA FITS")
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 0.033))
                    .tracking(0.8)
                    .foregroundStyle(cardBlue)
                    .padding(.top, 2)

                Spacer()
            }
            .padding(.horizontal, ootdInset)
            .padding(.top, geo.size.height * 0.04)
        }
    }

    // Above outfit: DAY + MONTH
    private var ootdDynamicFrontLayer: some View {
        GeometryReader { geo in
            let textWidth = geo.size.width - ootdInset * 2

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text(outfitDayOrdinal)
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 0.14))
                    .foregroundStyle(cardBlue)
                    .padding(.bottom, 2)

                Text(outfitMonthName.uppercased())
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 0.42))
                    .foregroundStyle(cardBlue)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .frame(width: textWidth, alignment: .center)
            }
            .padding(.horizontal, ootdInset)
            .padding(.bottom, geo.size.height * 0.04)
        }
    }

    // MARK: - Outfit layer

    private var outfitLayer: some View {
        RotatableOutfitImage(
            outfit: outfit,
            height: 384,
            draggable: true,
            eagerLoad: true,
            preloadFullSequenceOnAppear: true,
            initialFrameIndex: 0,
            syncFrameIndex: gyroSuspended ? nil : gyroFrameIndex,
            syncImage: gyroSuspended ? nil : gyroImage,
            onHorizontalDragChange: { dragging in
                isDraggingOutfit = dragging
                if dragging {
                    gyroResumeTask?.cancel()
                    gyroSuspended = true
                } else {
                    scheduleGyroResume()
                }
            },
            onFrameChange: { frame in
                if isDraggingOutfit || gyroSuspended {
                    gyroBaseFrame = frame
                }
            }
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Template picker

    private var templatePicker: some View {
        HStack(spacing: 6) {
            ForEach(ShareCardTemplate.allCases) { template in
                let isSelected = selectedTemplate == template
                Button {
                    guard template != selectedTemplate else { return }
                    templateSlideEdge = template.rawValue > selectedTemplate.rawValue ? .trailing : .leading
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        selectedTemplate = template
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(template.name.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(isSelected ? AppPalette.textSecondary : AppPalette.textFaint)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .appCapsule(shadowRadius: 0, shadowY: 0)
                        .opacity(isSelected ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: selectedTemplate)
            }
        }
    }

    // MARK: - Share actions

    private var shareActions: some View {
        HStack(spacing: 10) {
            Button {
                // Set loading state synchronously so UI updates before the task starts
                isExportingVideo = true
                storyHaptic.impactOccurred()
                exportAndShareVideo()
            } label: {
                HStack(spacing: 6) {
                    if isExportingVideo {
                        ProgressView()
                            .tint(AppPalette.textMuted)
                            .scaleEffect(0.7)
                    } else {
                        AppIcon(glyph: .video, size: 12, color: AppPalette.iconPrimary)
                    }
                    Text("STORY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(AppPalette.textMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
            .disabled(isExportingVideo)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                shareAsLink()
            } label: {
                HStack(spacing: 6) {
                    AppIcon(glyph: .globe, size: 12, color: AppPalette.iconPrimary)
                    Text("LINK")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(AppPalette.textMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .appCapsule(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Frosted glass mask

    // Processes a PNG so every non-transparent pixel becomes fully opaque white.
    // This lets us use a low-opacity PNG as a crisp full-strength mask.
    private static var maskCache: [String: UIImage] = [:]

    private func solidAlphaMask(for imageName: String) -> UIImage? {
        if let cached = Self.maskCache[imageName] { return cached }
        guard let source = UIImage(named: imageName) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: source.size)
        let mask = renderer.image { _ in
            // Draw 10 times so even low-opacity shapes (e.g. 30%) accumulate
            // to near-full opacity (1 - 0.7^10 ≈ 97%) while fully transparent
            // pixels stay at 0%. This binarises the alpha without pixel manipulation.
            for _ in 0..<10 {
                source.draw(at: .zero)
            }
        }
        Self.maskCache[imageName] = mask
        return mask
    }

    // MARK: - Gyroscope

    private func scheduleGyroResume() {
        gyroResumeTask?.cancel()
        gyroResumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, !isDraggingOutfit else { return }
            if let motion = motionManager.deviceMotion {
                gyroRollOffset = motion.attitude.roll
            }
            gyroFrameIndex = gyroBaseFrame
            gyroImage = await FrameLoader.shared.frame(for: outfit, index: gyroBaseFrame)
            gyroSuspended = false
        }
    }

    private func startGyroscope() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        gyroRollOffset = 0
        gyroBaseFrame = 0

        motionManager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }

            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                gyroPitch = motion.attitude.pitch
                gyroRoll = motion.attitude.roll
            }

            guard !gyroSuspended else { return }

            let roll = motion.attitude.roll
            let deltaRoll = roll - gyroRollOffset
            let frameCount = max(1, outfit.frameCount)
            let frameOffset = Int(deltaRoll / (2 * .pi) * Double(frameCount))
            var newIndex = (gyroBaseFrame + frameOffset) % frameCount
            if newIndex < 0 { newIndex += frameCount }

            if newIndex != gyroFrameIndex {
                Task { @MainActor in
                    let image = await FrameLoader.shared.frame(for: outfit, index: newIndex)
                    guard !gyroSuspended else { return }
                    gyroImage = image
                    gyroFrameIndex = newIndex
                }
            }
        }
    }

    private func stopGyroscope() {
        motionManager.stopDeviceMotionUpdates()
        gyroResumeTask?.cancel()
    }

    // MARK: - Export

    // 9:16 at half resolution — high enough quality, low enough memory
    private let storyCanvas = CGSize(width: 540, height: 960)

    private func exportAndShareVideo() {
        Task {
            let canvas = storyCanvas
            let backImage = UIImage(named: selectedTemplate.backImageName)
            let frontImage = selectedTemplate.frontImageName.flatMap { UIImage(named: $0) }

            // One full forward rotation — seamless loop since frame 0 ≈ frame N (360° orbit)
            let totalFrames = outfit.frameCount
            let allIndices = Array(Swift.stride(from: 0, to: totalFrames, by: 2))

            guard !allIndices.isEmpty else {
                await MainActor.run { isExportingVideo = false; exportError = "No frames to export." }
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yafa-story-\(outfit.id).mp4")
            try? FileManager.default.removeItem(at: url)

            // Set up writer before loading any frames
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
                await MainActor.run { isExportingVideo = false; exportError = "Couldn't create video." }
                return
            }

            let fps = 30
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(canvas.width),
                AVVideoHeightKey: Int(canvas.height),
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(canvas.width),
                    kCVPixelBufferHeightKey as String: Int(canvas.height),
                ]
            )

            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            // Stream: composite one frame at a time and write immediately.
            // Never hold more than 1 frame in memory.
            var writtenCount = 0
            for outfitIndex in allIndices {
                guard let outfitFrame = await FrameLoader.shared.frame(for: outfit, index: outfitIndex) else {
                    continue
                }

                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(5))
                }

                let composed = compositeFrame(outfitFrame: outfitFrame,
                                              backImage: backImage,
                                              frontImage: frontImage,
                                              canvas: canvas)
                if let composed, let buffer = pixelBuffer(from: composed, size: canvas) {
                    let time = CMTime(value: CMTimeValue(writtenCount), timescale: CMTimeScale(fps))
                    adaptor.append(buffer, withPresentationTime: time)
                    writtenCount += 1
                }
            }

            input.markAsFinished()
            await writer.finishWriting()

            let success = writer.status == .completed && writtenCount > 0
            await MainActor.run {
                isExportingVideo = false
                if success {
                    shareToInstagramStories(videoURL: url)
                } else {
                    exportError = "Couldn't export the video. Please try again."
                }
            }
        }
    }

    private func compositeFrame(
        outfitFrame: UIImage,
        backImage: UIImage?,
        frontImage: UIImage?,
        canvas: CGSize
    ) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(canvas, true, 1)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // 1. Story background — app's grouped background colour
        ctx.setFillColor(UIColor(red: 236/255, green: 240/255, blue: 246/255, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))

        // 2. Card rect — floating, centred, with generous margins
        // Card aspect matches the in-app card: ~342 × 480 pt
        let cardW = canvas.width * 0.82
        let cardH = cardW * (480.0 / 342.0)
        let cardX = (canvas.width - cardW) / 2
        let cardY = (canvas.height - cardH) / 2
        let cardRect = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)
        let cornerRadius = cardW * (24.0 / 342.0) // proportional to LayoutMetrics.cardCornerRadius

        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cornerRadius)

        // Shadow + transparency layer: shadow is applied to the composited card as a whole
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 14),
            blur: 40,
            color: UIColor.black.withAlphaComponent(0.30).cgColor
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Clip everything inside the card shape
        cardPath.addClip()

        // 3. Back PNG (or fallback)
        if let back = backImage {
            back.draw(in: aspectFillRect(imageSize: back.size, canvasSize: cardRect.size)
                .offsetBy(dx: cardX, dy: cardY))
        } else {
            ctx.setFillColor(UIColor(white: 0.91, alpha: 1).cgColor)
            ctx.fill(cardRect)
        }

        // 4. Outfit — fit inside card while strictly preserving aspect ratio
        let hPad = cardW * (40.0 / 342.0)
        let maxW = cardW - hPad * 2
        let maxH = cardH * 0.88
        let frameAspect = outfitFrame.size.height / max(outfitFrame.size.width, 1)

        // Scale to fit: width-constrained first, then height-constrain if needed
        var outfitW = maxW
        var outfitH = outfitW * frameAspect
        if outfitH > maxH {
            outfitH = maxH
            outfitW = outfitH / frameAspect
        }

        outfitFrame.draw(in: CGRect(
            x: cardX + (cardW - outfitW) / 2,
            y: cardY + (cardH - outfitH) / 2,
            width: outfitW,
            height: outfitH
        ))

        // 5. Front PNG overlay
        if let front = frontImage {
            front.draw(in: aspectFillRect(imageSize: front.size, canvasSize: cardRect.size)
                .offsetBy(dx: cardX, dy: cardY))
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 6. Card border on top (drawn outside the clipped state)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        cardPath.stroke()

        return UIGraphicsGetImageFromCurrentImageContext()
    }

    private func aspectFillRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        let scale = max(canvasSize.width / max(imageSize.width, 1),
                        canvasSize.height / max(imageSize.height, 1))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h)
    }

    private func shareToInstagramStories(videoURL: URL) {
        let instagramURL = URL(string: "instagram-stories://share?source_application=\(Bundle.main.bundleIdentifier ?? "")")!
        if UIApplication.shared.canOpenURL(instagramURL),
           let videoData = try? Data(contentsOf: videoURL) {
            UIPasteboard.general.setData(videoData,
                                         forPasteboardType: "com.instagram.sharedSticker.backgroundVideo")
            UIApplication.shared.open(instagramURL)
        } else {
            let activityVC = UIActivityViewController(activityItems: [videoURL], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(activityVC, animated: true)
            }
        }
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                            &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        if let cgImage = image.cgImage {
            context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func shareAsLink() {
        let urlString = "\(AppConfig.siteBaseURL)/card/\(outfit.id)"
        let activityVC = UIActivityViewController(
            activityItems: [urlString],
            applicationActivities: nil
        )
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
}

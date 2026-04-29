import AVFoundation
import CoreImage
import CoreMotion
import Photos
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
    case colorama     = 8
    // Two-layer PNG templates
    case layered2 = 3
    case layered3 = 4

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .monoLive:     return "Mono"
        case .electricLive: return "Electric"
        case .ootdLive:     return "OOTD"
        case .colorama:     return "Colorama"
        case .layered2:     return "Fits"
        case .layered3:     return "Stats"
        }
    }

    /// Dynamic code-based templates — render date layers in SwiftUI.
    var isDynamic: Bool {
        self == .monoLive || self == .electricLive
            || self == .ootdLive || self == .colorama
    }

    /// Whether this dynamic template uses a back PNG instead of a solid color.
    var usesBackPNG: Bool { false }

    /// Background fill for dynamic templates.
    var dynamicBackground: Color {
        // Cool light-grey/blue backdrop for colorama; everything else
        // uses the standard cardGray.
        self == .colorama
            ? Color(red: 0.86, green: 0.89, blue: 0.95)
            : cardGray
    }

    /// Back PNG — fills the card behind the outfit for PNG templates.
    var backImageName: String {
        switch self {
        case .layered2:  return "card-layered2-back"
        case .layered3:  return "card-layered3-back"
        default:         return "card-mono"
        }
    }

    /// Front PNG — rendered on top of the outfit. nil for dynamic/single-layer.
    var frontImageName: String? {
        switch self {
        case .layered2: return "card-layered2-front"
        case .layered3: return "card-layered3-front"
        default:        return nil
        }
    }

    var frontLayerIsFrosted: Bool { self == .layered2 }

    /// Color variants offered for this template. The first entry is the
    /// template's default look (matches the existing in-app appearance);
    /// subsequent entries are alternative tints. Templates without
    /// variants return an empty array.
    var colorVariants: [TemplateColorVariant] {
        switch self {
        case .monoLive:
            // BG / text pairs supplied by Yael. Tint = background (the
            // dot in the picker shows the bg colour); textColor is the
            // date-number colour drawn on top.
            return [
                TemplateColorVariant(id: 0, tint: cardGray, textColor: .black),
                TemplateColorVariant(
                    id: 1,
                    tint: Color(red: 0x18 / 255.0, green: 0x03 / 255.0, blue: 0xFE / 255.0),
                    textColor: Color(red: 0xD1 / 255.0, green: 0xCD / 255.0, blue: 0xFF / 255.0)
                ),
                TemplateColorVariant(
                    id: 2,
                    tint: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0),
                    textColor: Color(red: 0xD6 / 255.0, green: 0xC2 / 255.0, blue: 0xC1 / 255.0)
                ),
                TemplateColorVariant(
                    id: 3,
                    tint: Color(red: 0xD6 / 255.0, green: 0xC2 / 255.0, blue: 0xC1 / 255.0),
                    textColor: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0)
                ),
                TemplateColorVariant(
                    id: 4,
                    tint: Color(red: 0xFE / 255.0, green: 0x2C / 255.0, blue: 0x09 / 255.0),
                    textColor: Color(red: 0x33 / 255.0, green: 0x09 / 255.0, blue: 0x02 / 255.0)
                ),
                TemplateColorVariant(
                    id: 5,
                    tint: Color(red: 0xFB / 255.0, green: 0xE5 / 255.0, blue: 0x4D / 255.0),
                    textColor: Color(red: 0x32 / 255.0, green: 0x2E / 255.0, blue: 0x0F / 255.0)
                ),
            ]
        case .electricLive:
            // BG / text pairs supplied by Yael. The picker dot uses
            // whichever of bg/text is more saturated so each variant
            // is visually distinct.
            return [
                TemplateColorVariant(id: 0, tint: cardBlue), // unchanged default
                TemplateColorVariant(
                    id: 1,
                    tint: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0),
                    textColor: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0),
                    backgroundColor: Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0)
                ),
                TemplateColorVariant(
                    id: 2,
                    tint: Color(red: 0x99 / 255.0, green: 0x8B / 255.0, blue: 0x8A / 255.0),
                    textColor: Color(red: 0x99 / 255.0, green: 0x8B / 255.0, blue: 0x8A / 255.0),
                    backgroundColor: Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0)
                ),
                TemplateColorVariant(
                    id: 3,
                    tint: Color(red: 0x18 / 255.0, green: 0x03 / 255.0, blue: 0xFE / 255.0),
                    textColor: Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0),
                    backgroundColor: Color(red: 0x18 / 255.0, green: 0x03 / 255.0, blue: 0xFE / 255.0)
                ),
                TemplateColorVariant(
                    id: 4,
                    tint: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0),
                    textColor: Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0),
                    backgroundColor: Color(red: 0xE6 / 255.0, green: 0x3E / 255.0, blue: 0x33 / 255.0)
                ),
                TemplateColorVariant(
                    id: 5,
                    tint: Color(red: 0xB3 / 255.0, green: 0xA9 / 255.0, blue: 0xA9 / 255.0),
                    textColor: Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0),
                    backgroundColor: Color(red: 0xB3 / 255.0, green: 0xA9 / 255.0, blue: 0xA9 / 255.0)
                ),
            ]
        case .ootdLive:
            // BG / text triplets supplied by Yael. Each non-default
            // variant replaces OOTD's white→black 40% gradient with a
            // full-opacity two-stop gradient and recolours the OOTD /
            // YAFA FITS / DAY+MONTH text.
            return [
                TemplateColorVariant(id: 0, tint: cardBlue), // unchanged default
                TemplateColorVariant(
                    id: 1,
                    tint: Color(red: 0xA2 / 255.0, green: 0xFF / 255.0, blue: 0xBA / 255.0),
                    textColor: Color(red: 0xA2 / 255.0, green: 0xFF / 255.0, blue: 0xBA / 255.0),
                    backgroundColor: Color(red: 0x0A / 255.0, green: 0x13 / 255.0, blue: 0x10 / 255.0),
                    gradientTop: Color(red: 0x17 / 255.0, green: 0x3C / 255.0, blue: 0x37 / 255.0)
                ),
                TemplateColorVariant(
                    id: 2,
                    tint: Color(red: 0x13 / 255.0, green: 0x00 / 255.0, blue: 0x4B / 255.0),
                    textColor: .white,
                    backgroundColor: .black,
                    gradientTop: Color(red: 0x13 / 255.0, green: 0x00 / 255.0, blue: 0x4B / 255.0)
                ),
                TemplateColorVariant(
                    id: 3,
                    tint: Color(red: 0xFE / 255.0, green: 0x03 / 255.0, blue: 0x78 / 255.0),
                    textColor: Color(red: 0xFE / 255.0, green: 0x03 / 255.0, blue: 0x78 / 255.0),
                    backgroundColor: Color(red: 0x54 / 255.0, green: 0x13 / 255.0, blue: 0x31 / 255.0),
                    gradientTop: Color(red: 0xFF / 255.0, green: 0xDC / 255.0, blue: 0xEC / 255.0)
                ),
            ]
        case .colorama:
            // The actual letter-palette colours live in `Colorama.metal`
            // (one stitchable shader function per variant). The fields
            // here just describe the bg gradient + the picker dot tint.
            return [
                TemplateColorVariant(
                    id: 0,
                    tint: Color(red: 0.74, green: 0.83, blue: 0.96)
                ),
                TemplateColorVariant(
                    id: 1, // pink
                    tint: Color(red: 0xE8 / 255.0, green: 0x3E / 255.0, blue: 0x7C / 255.0),
                    backgroundColor: Color(red: 0xF2 / 255.0, green: 0xA8 / 255.0, blue: 0xC7 / 255.0),
                    gradientTop: Color(red: 0xF5 / 255.0, green: 0xE8 / 255.0, blue: 0xD8 / 255.0)
                ),
                TemplateColorVariant(
                    id: 2, // sage
                    tint: Color(red: 0x82 / 255.0, green: 0xC6 / 255.0, blue: 0x6E / 255.0),
                    backgroundColor: Color(red: 0x6B / 255.0, green: 0x8E / 255.0, blue: 0x5C / 255.0),
                    gradientTop: Color(red: 0xEA / 255.0, green: 0xF5 / 255.0, blue: 0xFC / 255.0)
                ),
                TemplateColorVariant(
                    id: 3, // sunset
                    tint: Color(red: 0xF5 / 255.0, green: 0xBC / 255.0, blue: 0x73 / 255.0),
                    backgroundColor: Color(red: 0x2D / 255.0, green: 0x5B / 255.0, blue: 0xA3 / 255.0),
                    gradientTop: Color(red: 0xF5 / 255.0, green: 0xE5 / 255.0, blue: 0xD0 / 255.0)
                ),
            ]
        case .layered2, .layered3:
            return []
        }
    }
}

/// One selectable colour variant for a template. `tint` is shown in the
/// picker dot AND drives the relevant accent in the card rendering
/// (background fill for mono / colorama, accent text for electric /
/// OOTD). `textColor` is an optional secondary used by templates that
/// recolour their text alongside the background (mono).
struct TemplateColorVariant: Identifiable, Hashable {
    let id: Int
    let tint: Color
    let textColor: Color?
    let backgroundColor: Color?
    /// Top stop of a vertical gradient bg (used by OOTD + colorama
    /// variants). `backgroundColor` is the bottom stop.
    let gradientTop: Color?

    init(
        id: Int,
        tint: Color,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        gradientTop: Color? = nil
    ) {
        self.id = id
        self.tint = tint
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.gradientTop = gradientTop
    }
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
    /// Which export is in progress (so we can show the spinner on the
    /// correct button). nil = no export running.
    @State private var activeExport: ExportDestination?
    @State private var exportError: String?
    private let storyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var cardVisible = false
    @State private var templateSlideEdge: Edge = .trailing
    @State private var carouselDragOffset: CGFloat = 0
    // Continuous fractional template index while the user is scrubbing
    // the dot picker. nil at rest — the dots then track `selectedTemplate`
    // (and any in-progress carousel drag).
    @State private var dotScrubPosition: CGFloat? = nil

    // Per-template selected colour variant. Persists per template, so
    // switching back to a previously-customised template restores its
    // colour. Default (missing key) means variant 0.
    @State private var colorVariantIndex: [ShareCardTemplate: Int] = [:]

    // Cached colorama text bitmaps. Rebuilding these on every body
    // pass (gyroPitch ticks 30+×/sec) is what was making the share
    // tab lag. Keyed on the source string so they only re-render
    // when the outfit's date actually changes.
    @State private var coloramaTextImage: UIImage?
    @State private var coloramaTextMonth: String?
    @State private var coloramaDayImage: UIImage?
    @State private var coloramaDayString: String?
    @State private var coloramaWeekdayImage: UIImage?
    @State private var coloramaWeekdayString: String?

    // Stroke-only versions used for the wave-driven edge highlight.
    @State private var coloramaMonthStroke: UIImage?
    @State private var coloramaDayStroke: UIImage?
    @State private var coloramaWeekdayStroke: UIImage?

    // "OOTD" text shown at the top of the colorama card. Constant
    // string so it's rendered once and reused across outfits.
    @State private var coloramaOotdImage: UIImage?
    @State private var coloramaOotdStroke: UIImage?

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 48)

                Spacer(minLength: 16)

                templateTitle
                    .padding(.bottom, 6)
                    .opacity(cardVisible ? 1 : 0)

                cardCarousel
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
                    .padding(.top, 14)
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardVisible ? 0 : 20)

                templateColorPicker
                    .padding(.top, 14)
                    .opacity(cardVisible ? 1 : 0)

                Spacer(minLength: 32)

                shareActions
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, 14)
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
                    .appCircle()
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

    // MARK: - Card carousel

    private var cardCarousel: some View {
        let templates = availableTemplates
        let cardWidth = UIScreen.main.bounds.width - 48
        let gap: CGFloat = 16
        let step = cardWidth + gap

        return GeometryReader { geo in
            let currentIndex = templates.firstIndex(of: selectedTemplate) ?? 0
            let cardHeight = geo.size.height - 40
            let baseOffset = geo.size.width / 2 - cardWidth / 2 - CGFloat(currentIndex) * step

            // Each card's distance from the visible centre, in fractional
            // template-index units. 0 = centre, ±1 = one slot away, etc.
            // Updates continuously while the carousel is being dragged
            // so the rotation interpolates smoothly during the swipe.
            let cardRelativePos: (Int) -> CGFloat = { i in
                CGFloat(i) - CGFloat(currentIndex) + carouselDragOffset / step
            }
            // Max Y-rotation a side card receives. 30° gives a clearly
            // visible 3D tilt without distorting the centre card's look.
            let maxYRotation: Double = 30
            // Templates whose front layer contains a `UIVisualEffectView`
            // (the Fits frosted sticker) can't be 3D-rotated — the blur
            // is dropped by UIKit whenever the view is rendered through
            // a 3D transform. We skip rotation for them.
            let canRotate: (ShareCardTemplate) -> Bool = { t in
                !t.frontLayerIsFrosted
            }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(Array(templates.enumerated()), id: \.element) { i, template in
                            let degrees: Double = canRotate(template)
                                ? -Double(cardRelativePos(i)) * maxYRotation
                                : 0
                            cardBackLayer(for: template)
                                .frame(width: cardWidth, height: cardHeight)
                                .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
                                )
                                .shadow(color: Color.black.opacity(0.10), radius: 18, y: 10)
                                .rotation3DEffect(
                                    .degrees(degrees),
                                    axis: (x: 0, y: 1, z: 0),
                                    anchor: .center,
                                    perspective: 0.5
                                )
                        }
                    }
                    .offset(x: baseOffset + carouselDragOffset)
                }
                .overlay {
                    outfitLayer
                        .frame(width: cardWidth, height: cardHeight)
                }
                .overlay(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(Array(templates.enumerated()), id: \.element) { i, template in
                            let degrees: Double = canRotate(template)
                                ? -Double(cardRelativePos(i)) * maxYRotation
                                : 0
                            cardFrontLayer(for: template)
                                .frame(width: cardWidth, height: cardHeight)
                                .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
                                .rotation3DEffect(
                                    .degrees(degrees),
                                    axis: (x: 0, y: 1, z: 0),
                                    anchor: .center,
                                    perspective: 0.5
                                )
                        }
                    }
                    .offset(x: baseOffset + carouselDragOffset)
                    .allowsHitTesting(false)
                }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        carouselDragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let translation = value.translation.width
                        let velocity = value.predictedEndTranslation.width
                        var newIndex = currentIndex
                        if translation < -50 || velocity < -200 {
                            newIndex = min(currentIndex + 1, templates.count - 1)
                        } else if translation > 50 || velocity > 200 {
                            newIndex = max(currentIndex - 1, 0)
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            selectedTemplate = templates[newIndex]
                            carouselDragOffset = 0
                        }
                    }
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: selectedTemplate)
        }
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

    // MARK: - Card layers

    private func cardBackLayer(
        for template: ShareCardTemplate,
        forcedTime: Double? = nil
    ) -> some View {
        Group {
            if template == .ootdLive {
                // Variants 1+ override the white→black 40% gradient
                // with a full-opacity two-stop gradient. Variant 0
                // (unchanged) keeps the original look.
                let v = colorVariant(for: .ootdLive)
                Group {
                    if let top = v?.gradientTop, let bottom = v?.backgroundColor {
                        LinearGradient(
                            colors: [top, bottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        ZStack {
                            Color.white
                            LinearGradient(
                                colors: [Color(red: 0.737, green: 0.737, blue: 0.737), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .opacity(0.4)
                        }
                    }
                }
                .overlay(ootdBackLayer)
            } else if template == .colorama {
                let v = colorVariant(for: .colorama)
                let bgTop = v?.gradientTop ?? Color(red: 0.88, green: 0.89, blue: 0.91)
                let bgBottom = v?.backgroundColor ?? renderingTint(for: .colorama)
                LinearGradient(
                    colors: [bgTop, bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(coloramaBigNumber(forcedTime: forcedTime))
            } else if template.isDynamic {
                // mono uses the variant tint as the full-card fill; for
                // mono uses tint as bg; electric reads bg + text from
                // the variant explicitly. Variant 1 (default) for
                // electric leaves bg/text nil, which falls back to the
                // legacy cardGray bg and tint as the text colour.
                let backgroundFill: Color = {
                    if template == .monoLive {
                        return renderingTint(for: .monoLive)
                    }
                    if template == .electricLive,
                       let bg = colorVariant(for: .electricLive)?.backgroundColor {
                        return bg
                    }
                    return template.dynamicBackground
                }()
                let textColorSwift: Color = {
                    switch template {
                    case .electricLive:
                        let v = colorVariant(for: .electricLive)
                        return v?.textColor ?? v?.tint ?? cardBlue
                    case .monoLive:
                        return colorVariant(for: .monoLive)?.textColor ?? .black
                    default:
                        return dynamicColor
                    }
                }()
                let dateColor = UIColor(textColorSwift)
                backgroundFill
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        Canvas { context, size in
                            let isElec = template == .electricLive
                            let fontName = isElec ? "PlayfairDisplay-Italic" : "Inter28pt-SemiBold"
                            let fontSize: CGFloat = isElec ? 457.2 : 304
                            let kern: CGFloat   = isElec ? -50.3 : -21.3

                            if let img = textToImage(
                                outfitDayNumber,
                                fontName: fontName, fontSize: fontSize,
                                kern: kern, color: dateColor
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
                    // Brand mark — bottom-right of the card, tinted to
                    // match the variant's text colour (so it adapts
                    // across mono / electric variants). On Electric the
                    // logo is dropped onto the same horizontal axis as
                    // the weekday label (yPct = 0.05).
                    .overlay {
                        GeometryReader { geo in
                            if let logo = Self.coloramaLogo {
                                let logoW = geo.size.width * 0.12
                                let logoY: CGFloat = template == .electricLive
                                    ? geo.size.height * 0.95
                                    : geo.size.height - logoW * 0.30 - 20
                                Image(uiImage: logo)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: logoW)
                                    .colorMultiply(textColorSwift)
                                    .position(
                                        x: geo.size.width - logoW / 2 - 20,
                                        y: logoY
                                    )
                            }
                        }
                    }
            } else if let uiImage = UIImage(named: template.backImageName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.92)
            }
        }
    }

    // MARK: - Colorama big number
    //
    // The animation cycle period (seconds) lives in the Metal shader as
    // `CYCLE_SECONDS`. Keep these in sync if you change one.

    /// Reproduces the AE Colorama tutorial recipe in pure SwiftUI:
    ///
    ///   1. **Coloured gradient layer** — vertical LinearGradient with
    ///      blue→light-blue→white→light-blue→blue stops (the "colorama
    ///      output" applied to a white-top/black-bottom gradient,
    ///      mapped through a blue/grey hue). The white peak's location
    ///      is driven by `phase`, animated by TimelineView. As phase
    ///      cycles 0→1, the white band scrolls top → bottom and loops
    ///      seamlessly (the colour wrap happens off-screen above /
    ///      below the letters because gradient extent ≥ letter extent).
    ///
    ///   2. **Mask by letter shape** — `.mask(textImage)` clips the
    ///      coloured gradient to the day-number outline. Same as the
    ///      AE precompose-then-mask step.
    ///
    ///   3. **White inner glow on letter outlines** — `coloramaTinted-
    ///      Image(.white, blur: 5).blendMode(.plusLighter)` brightens
    ///      the very edges of the strokes additively, giving the
    ///      "white outlines bleeding inward" feel.
    ///
    ///   5. **Outer glow** — two stacked blurred-tinted copies of the
    ///      text image (heavy soft halo + saturated mid halo) provide
    ///      the diffuse blue glow into the black background.
    ///
    /// Step 4 from the AE recipe (turbulent displace + time
    /// displacement using the inner-glow shape as source) is omitted
    /// here — those need a Metal shader because SwiftUI primitives
    /// don't expose noise distortion or temporal sampling. Easy to add
    /// later as a polish layer.
    /// Must match `CYCLE_SECONDS` in `Colorama.metal`.
    private static let coloramaCycleSeconds: Double = 6.0

    private func coloramaBigNumber(forcedTime: Double? = nil) -> some View {
        // Month + day-of-month + weekday, all rendered through a single
        // shared shader pass so they read as cutouts from one continuous
        // animated gradient. Bitmaps are cached in @State and only
        // re-rendered when their source string changes.
        //
        // Layout:
        //   • month: GTF Adieu Black Slanted 320pt, fills card width,
        //     centred vertically.
        //   • day:   same font, half the month's size, sits directly
        //     above the month with its left edge aligned to the month's.
        //   • weekday: Inter italic at the bottom (unchanged).
        let monthAbbrev = outfit.parsedDate?
            .formatted(.dateTime.month(.abbreviated))
            .lowercased() ?? "—"
        let dayString = outfitDayNumber
        let weekdayString = outfitWeekday
        let smallYPct: CGFloat = 0.08
        // Visible ink-to-ink gap between day's bottom and month's top.
        // 0 = day glyph bottom touches month glyph top; negative values
        // overlap the day into the month's ascender space.
        let dayMonthGap: CGFloat = 4
        // Pad inside each text bitmap (from `textToImage`).
        let bitmapInkPad: CGFloat = 4

        return GeometryReader { geo in
            let cardW = geo.size.width
            let cardH = geo.size.height

            // Month occupies the full card width; its displayed height
            // is derived from the bitmap's aspect ratio.
            let monthDispH: CGFloat = {
                guard let s = coloramaTextImage?.size, s.width > 0 else { return 0 }
                return cardW * s.height / s.width
            }()
            let monthCenterX = cardW / 2
            let monthCenterY = cardH / 2
            let monthTopY = monthCenterY - monthDispH / 2

            // Day is sized to a consistent HEIGHT — half the displayed
            // month height. Width follows from the bitmap's aspect ratio
            // so single-digit days ("1") and double-digit days ("28")
            // appear at the same visual scale, just with different
            // widths. Right edge aligned to the card's right edge.
            let dayDispH: CGFloat = monthDispH * 0.5
            let dayBitmapAspect: CGFloat = {
                guard let s = coloramaDayImage?.size, s.height > 0 else { return 0 }
                return s.width / s.height
            }()
            let dayDispW = dayDispH * dayBitmapAspect
            // Bitmap padding scaled into display space, used to place
            // glyph-ink against glyph-ink rather than bitmap-edge
            // against bitmap-edge.
            let monthPadDisplayed: CGFloat = {
                guard let s = coloramaTextImage?.size, s.width > 0 else { return 0 }
                return bitmapInkPad * cardW / s.width
            }()
            let dayPadDisplayed: CGFloat = {
                guard let s = coloramaDayImage?.size, s.height > 0 else { return 0 }
                return bitmapInkPad * dayDispH / s.height
            }()
            let dayCenterX = cardW - dayDispW / 2
            let dayCenterY = monthTopY
                + monthPadDisplayed + dayPadDisplayed
                - dayMonthGap
                - dayDispH / 2

            ZStack {
                // ---- HALOS (static, cached per-text bitmap) ----
                ZStack {
                    if let img = coloramaOotdImage {
                        coloramaHaloStack(
                            img,
                            fitWidth: nil,
                            centerX: cardW / 2, centerY: cardH * smallYPct,
                            blurOuter: 18, blurMid: 9
                        )
                    }
                    if let img = coloramaTextImage {
                        coloramaHaloStack(
                            img,
                            fitWidth: cardW,
                            centerX: monthCenterX, centerY: monthCenterY,
                            blurOuter: 65, blurMid: 32
                        )
                    }
                    if let img = coloramaDayImage {
                        coloramaHaloStack(
                            img,
                            fitWidth: dayDispW,
                            centerX: dayCenterX, centerY: dayCenterY,
                            blurOuter: 22, blurMid: 11
                        )
                    }
                    if let img = coloramaWeekdayImage {
                        coloramaHaloStack(
                            img,
                            fitWidth: nil,
                            centerX: cardW / 2, centerY: cardH * (1 - smallYPct),
                            blurOuter: 18, blurMid: 9
                        )
                    }
                }
                .drawingGroup()

                // ---- ANIMATED SHADER + COMBINED MASK + EDGE STROKES ----
                // In-app: TimelineView drives `t`. Export: caller passes
                // `forcedTime` so each video frame can render its own
                // moment of the cycle.
                Group {
                    if let t = forcedTime {
                        coloramaAnimatedBody(
                            t: t,
                            cardW: cardW, cardH: cardH,
                            dayDispW: dayDispW,
                            dayCenterX: dayCenterX, dayCenterY: dayCenterY,
                            monthCenterX: monthCenterX, monthCenterY: monthCenterY,
                            smallYPct: smallYPct
                        )
                    } else {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                            let t = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 600)
                            coloramaAnimatedBody(
                                t: t,
                                cardW: cardW, cardH: cardH,
                                dayDispW: dayDispW,
                                dayCenterX: dayCenterX, dayCenterY: dayCenterY,
                                monthCenterX: monthCenterX, monthCenterY: monthCenterY,
                                smallYPct: smallYPct
                            )
                        }
                    }
                }

                // ---- INNER GLOWS (static, cached) ----
                ZStack {
                    if let img = coloramaOotdImage {
                        Image(uiImage: img)
                            .colorMultiply(.white)
                            .blur(radius: 1.5)
                            .position(x: cardW / 2, y: cardH * smallYPct)
                    }
                    if let img = coloramaTextImage {
                        coloramaTintedImage(
                            img, geo: geo,
                            color: .white, blur: 5
                        )
                    }
                    if let img = coloramaDayImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: dayDispW)
                            .colorMultiply(.white)
                            .blur(radius: 1.5)
                            .position(x: dayCenterX, y: dayCenterY)
                    }
                    if let img = coloramaWeekdayImage {
                        Image(uiImage: img)
                            .colorMultiply(.white)
                            .blur(radius: 1.5)
                            .position(x: cardW / 2, y: cardH * (1 - smallYPct))
                    }
                }
                .drawingGroup()
                .blendMode(.plusLighter)
                .opacity(0.25)

                // ---- SOLID WHITE LOGO (bottom right, no effects) ----
                // Brand mark — sits on top of everything, doesn't pulse
                // with the gradient. Half the size of the original
                // shader-driven logo at top.
                if let logo = Self.coloramaLogo {
                    let logoW = cardW * 0.12
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoW)
                        .position(
                            x: cardW - logoW / 2 - 20,
                            y: cardH - logoW * 0.30 - 20
                        )
                }
            }
            .compositingGroup()
        }
        .task(id: monthAbbrev) {
            guard coloramaTextMonth != monthAbbrev else { return }
            coloramaTextImage = textToImage(
                monthAbbrev,
                fontName: "GTFAdieuTRIAL-BlackSlanted", fontSize: 320,
                kern: -8.0, color: .white
            )
            coloramaMonthStroke = textToImage(
                monthAbbrev,
                fontName: "GTFAdieuTRIAL-BlackSlanted", fontSize: 320,
                kern: -8.0, color: .white,
                strokeWidthPercent: 0.625
            )
            coloramaTextMonth = monthAbbrev
        }
        .task(id: dayString) {
            guard coloramaDayString != dayString else { return }
            coloramaDayImage = textToImage(
                dayString,
                fontName: "GTFAdieuTRIAL-BlackSlanted", fontSize: 110,
                kern: -2.75, color: .white
            )
            coloramaDayStroke = textToImage(
                dayString,
                fontName: "GTFAdieuTRIAL-BlackSlanted", fontSize: 110,
                kern: -2.75, color: .white,
                strokeWidthPercent: 0.625
            )
            coloramaDayString = dayString
        }
        .task(id: weekdayString) {
            guard coloramaWeekdayString != weekdayString else { return }
            coloramaWeekdayImage = textToImage(
                weekdayString,
                fontName: "Inter28pt-MediumItalic", fontSize: 36,
                kern: -1.565, color: .white
            )
            coloramaWeekdayStroke = textToImage(
                weekdayString,
                fontName: "Inter28pt-MediumItalic", fontSize: 36,
                kern: -1.565, color: .white,
                strokeWidthPercent: 1.5
            )
            coloramaWeekdayString = weekdayString
        }
        // "OOTD" never changes — render once on first appearance.
        .task {
            if coloramaOotdImage == nil {
                coloramaOotdImage = textToImage(
                    "OOTD",
                    fontName: "Inter28pt-MediumItalic", fontSize: 36,
                    kern: -1.565, color: .white
                )
                coloramaOotdStroke = textToImage(
                    "OOTD",
                    fontName: "Inter28pt-MediumItalic", fontSize: 36,
                    kern: -1.565, color: .white,
                    strokeWidthPercent: 1.5
                )
            }
        }
    }

    /// Two-layer outer halo (blue diffuse + brighter mid) for one text
    /// bitmap. Used by `coloramaBigNumber` for each of the three text
    /// elements with proportional blur radii.
    private func coloramaHaloStack(
        _ img: UIImage,
        fitWidth: CGFloat?,
        centerX: CGFloat,
        centerY: CGFloat,
        blurOuter: CGFloat,
        blurMid: CGFloat
    ) -> some View {
        let halo = coloramaHaloColors()
        return ZStack {
            tintedTextLayer(
                img, fitWidth: fitWidth,
                centerX: centerX, centerY: centerY,
                color: halo.outer,
                blur: blurOuter, opacity: 0.40
            )
            tintedTextLayer(
                img, fitWidth: fitWidth,
                centerX: centerX, centerY: centerY,
                color: halo.mid,
                blur: blurMid, opacity: 0.75
            )
            .blendMode(.plusLighter)
        }
    }

    /// One tinted+blurred copy of a text bitmap. `fitWidth` non-nil
    /// scales the image to that width (used by the big month);
    /// `fitWidth` nil renders at the bitmap's natural size (used by
    /// the small day/weekday labels).
    private func tintedTextLayer(
        _ img: UIImage,
        fitWidth: CGFloat?,
        centerX: CGFloat,
        centerY: CGFloat,
        color: Color,
        blur: CGFloat,
        opacity: Double
    ) -> some View {
        Group {
            if let w = fitWidth {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: w)
            } else {
                Image(uiImage: img)
            }
        }
        .colorMultiply(color)
        .blur(radius: blur)
        .opacity(opacity)
        .position(x: centerX, y: centerY)
    }

    /// One tinted+blurred copy of the text image, scaled to fill the
    /// card width and centred in `geo`. Used for the outer halo stack
    /// and the inner-glow layer; all of them scale together so they
    /// stay aligned with the masked gradient body.
    private func coloramaTintedImage(
        _ img: UIImage,
        geo: GeometryProxy,
        color: Color,
        blur: CGFloat,
        opacity: Double = 1.0
    ) -> some View {
        Image(uiImage: img)
            .resizable()
            .scaledToFit()
            .frame(width: geo.size.width)
            .colorMultiply(color)
            .blur(radius: blur)
            .opacity(opacity)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }

    /// Animated portion of the colorama composite — the displaced
    /// gradient body + the wave-driven white edge strokes. Pulled out so
    /// both the live `TimelineView` path and the export per-frame path
    /// can share it.
    @ViewBuilder
    private func coloramaAnimatedBody(
        t: Double,
        cardW: CGFloat, cardH: CGFloat,
        dayDispW: CGFloat,
        dayCenterX: CGFloat, dayCenterY: CGFloat,
        monthCenterX: CGFloat, monthCenterY: CGFloat,
        smallYPct: CGFloat
    ) -> some View {
        ZStack {
            // Gradient body with AE-style displacement.
            coloramaLetterShapes(
                cardW: cardW,
                dayDispW: dayDispW,
                dayCenterX: dayCenterX, dayCenterY: dayCenterY,
                monthCenterX: monthCenterX, monthCenterY: monthCenterY,
                cardH: cardH, smallYPct: smallYPct
            )
            .frame(width: cardW, height: cardH)
            .layerEffect(
                coloramaDisplacedShader(t: t, cardW: cardW, cardH: cardH),
                maxSampleOffset: .zero
            )

            // Edge strokes masked by the displaced gradient luminance.
            ZStack {
                if let img = coloramaOotdStroke {
                    Image(uiImage: img)
                        .position(x: cardW / 2, y: cardH * smallYPct)
                }
                if let img = coloramaMonthStroke {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: cardW)
                        .position(x: monthCenterX, y: monthCenterY)
                }
                if let img = coloramaDayStroke {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: dayDispW)
                        .position(x: dayCenterX, y: dayCenterY)
                }
                if let img = coloramaWeekdayStroke {
                    Image(uiImage: img)
                        .position(x: cardW / 2, y: cardH * (1 - smallYPct))
                }
            }
            .colorMultiply(.white)
            .mask(
                coloramaLetterShapes(
                    cardW: cardW,
                    dayDispW: dayDispW,
                    dayCenterX: dayCenterX, dayCenterY: dayCenterY,
                    monthCenterX: monthCenterX, monthCenterY: monthCenterY,
                    cardH: cardH, smallYPct: smallYPct
                )
                .frame(width: cardW, height: cardH)
                .layerEffect(
                    coloramaDisplacedShader(t: t, cardW: cardW, cardH: cardH),
                    maxSampleOffset: .zero
                )
                .luminanceToAlpha()
            )
            .blendMode(.plusLighter)
        }
    }

    /// Letter shapes laid out at the right positions — used as both the
    /// displacement-map source for the gradient body and as the mask
    /// source for the edge-stroke luminance lookup.
    @ViewBuilder
    private func coloramaLetterShapes(
        cardW: CGFloat,
        dayDispW: CGFloat,
        dayCenterX: CGFloat, dayCenterY: CGFloat,
        monthCenterX: CGFloat, monthCenterY: CGFloat,
        cardH: CGFloat, smallYPct: CGFloat
    ) -> some View {
        let textBlur: CGFloat = 3
        return ZStack {
            // OOTD at top-centre — same Inter italic as the weekday at
            // the bottom, gets the same shader effect as the letters.
            if let img = coloramaOotdImage {
                Image(uiImage: img)
                    .blur(radius: textBlur)
                    .position(x: cardW / 2, y: cardH * smallYPct)
            }
            if let img = coloramaTextImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: cardW)
                    .blur(radius: textBlur)
                    .position(x: monthCenterX, y: monthCenterY)
            }
            if let img = coloramaDayImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: dayDispW)
                    .blur(radius: textBlur)
                    .position(x: dayCenterX, y: dayCenterY)
            }
            if let img = coloramaWeekdayImage {
                Image(uiImage: img)
                    .blur(radius: textBlur)
                    .position(x: cardW / 2, y: cardH * (1 - smallYPct))
            }
        }
    }

    private func cardFrontLayer(for template: ShareCardTemplate) -> some View {
        ZStack {
            if template.isDynamic && template != .ootdLive && template != .colorama {
                // colorama renders day/weekday with the gradient effect
                // in its back layer (coloramaBigNumber), so we skip the
                // plain-text front layer for that template.
                dynamicDateFrontLayer
            }
            if template == .ootdLive {
                ootdDynamicFrontLayer
            }
            if template.frontLayerIsFrosted,
               let frontName = template.frontImageName,
               let maskImage = solidAlphaMask(for: frontName) {
                FrostedShapeView(maskImage: maskImage)
            }
            if let frontName = template.frontImageName,
               let uiImage = UIImage(named: frontName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            }
        }
    }

    // MARK: - Text-to-image (ink-bounds centering)

    /// Renders `string` into a UIImage cropped to its exact ink bounds (visible pixels only).
    /// Centering this image = visually perfect centering regardless of digit widths.
    private func textToImage(
        _ string: String,
        fontName: String, fontSize: CGFloat,
        kern: CGFloat, color: UIColor,
        strokeWidthPercent: CGFloat = 0  // > 0 = stroke-only render
    ) -> UIImage? {
        guard let ctFont = CTFontCreateWithName(fontName as CFString, fontSize, nil) as CTFont? else {
            return nil
        }
        var attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
            kCTKernAttributeName as NSAttributedString.Key: kern as NSNumber
        ]
        if strokeWidthPercent > 0 {
            // Positive value = stroke-only render (no fill).
            attrs[kCTStrokeWidthAttributeName as NSAttributedString.Key] = strokeWidthPercent as NSNumber
            attrs[kCTStrokeColorAttributeName as NSAttributedString.Key] = color.cgColor
        }
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
        switch selectedTemplate {
        case .electricLive:
            let v = colorVariant(for: .electricLive)
            return v?.textColor ?? v?.tint ?? cardBlue
        case .colorama:     return .white  // legible on the black backdrop
        case .monoLive:
            return colorVariant(for: .monoLive)?.textColor ?? .black
        default:            return .black
        }
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
        // Top label center at ~5% from top, weekday center at ~5% from bottom
        GeometryReader { geo in
            // Electric ✦: Inter Medium Italic 21pt, -0.865 tracking, 5% from edges
            // Mono ✦:     Inter Medium Italic 52.151pt, -1.565 tracking, 8% from edges
            //             (larger font needs more clearance from edge)
            let isElectric = selectedTemplate == .electricLive
            let fontSize: CGFloat = isElectric ? 21 : 36
            let tracking: CGFloat = isElectric ? -0.865 : -1.565
            let yPct: CGFloat = isElectric ? 0.05 : 0.08
            let font = Font.custom("Inter28pt-MediumItalic", size: fontSize)
            // Colorama already renders the month huge in the back layer,
            // so we surface the day number at top instead of repeating
            // the month — the three datums (month / day / weekday) all
            // appear once each on the card.
            let topLabel = selectedTemplate == .colorama
                ? outfitDayNumber
                : outfitMonthName

            // .position() centers the text's own bounding box at the given point
            Text(topLabel)
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
        let v = colorVariant(for: .ootdLive)
        let accent = v?.textColor ?? v?.tint ?? cardBlue
        return GeometryReader { geo in
            let textWidth = geo.size.width - ootdInset * 2

            VStack(alignment: .leading, spacing: -24) {
                Text("OOTD")
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 1.1))
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .foregroundStyle(accent)
                    .frame(width: textWidth, alignment: .center)

                Text("YAFA FITS")
                    .font(.custom("PlayfairDisplay-Italic", size: textWidth * 0.033))
                    .tracking(0.8)
                    .foregroundStyle(accent)
                    .padding(.leading, textWidth * 0.73)
            }
            .padding(.horizontal, ootdInset)
            .padding(.top, -15)
        }
    }

    // Above outfit: DAY + MONTH
    private var ootdDynamicFrontLayer: some View {
        let v = colorVariant(for: .ootdLive)
        let accent = UIColor(v?.textColor ?? v?.tint ?? cardBlue)
        return GeometryReader { geo in
            let textWidth = geo.size.width - ootdInset * 2

            // DAY + MONTH in single Canvas for consistent spacing
            Canvas { context, size in
                let monthImg = textToImage(
                    outfitMonthName.uppercased(),
                    fontName: "PlayfairDisplay-Italic",
                    fontSize: size.width * 0.50,
                    kern: 0,
                    color: accent
                )
                let dayImg = textToImage(
                    outfitDayOrdinal,
                    fontName: "PlayfairDisplay-Italic",
                    fontSize: size.width * 0.14,
                    kern: 0,
                    color: accent
                )

                if let monthImg {
                    let scale = min(size.width / monthImg.size.width, 1.0)
                    let mw = monthImg.size.width * scale
                    let mh = monthImg.size.height * scale
                    let mx = (size.width - mw) / 2
                    let my = size.height - mh
                    context.draw(Image(uiImage: monthImg), in: CGRect(x: mx, y: my, width: mw, height: mh))

                    // DAY sits right above month, right-aligned, fixed 4px gap
                    if let dayImg {
                        let dx = size.width - dayImg.size.width
                        let dy = my - dayImg.size.height - 1
                        context.draw(Image(uiImage: dayImg), in: CGRect(x: dx, y: dy, width: dayImg.size.width, height: dayImg.size.height))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, ootdInset)
            .padding(.bottom, 8)
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
            },
            // Pull the scrub area in from the sides so horizontal swipes
            // near the card edges go to the template carousel instead
            // of getting eaten by the outfit drag.
            horizontalDragInset: 56
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Template picker

    private var availableTemplates: [ShareCardTemplate] {
        let productCount = outfit.products?.count ?? 0
        return ShareCardTemplate.allCases.filter { template in
            if template == .layered2 || template == .layered3 {
                return productCount >= 3
            }
            return true
        }
    }

    /// The dots' continuous "active" index — drives the magnification
    /// lens. When the user is scrubbing the dots, that wins; otherwise
    /// it follows `selectedTemplate` plus any in-progress carousel drag,
    /// so the lens slides smoothly while the carousel is being swiped.
    private var pickerActivePosition: CGFloat {
        let templates = availableTemplates
        if let scrub = dotScrubPosition { return scrub }
        let currentIndex = templates.firstIndex(of: selectedTemplate) ?? 0
        let cardWidth = UIScreen.main.bounds.width - 48
        let gap: CGFloat = 16
        let step = cardWidth + gap
        return CGFloat(currentIndex) + (-carouselDragOffset / step)
    }

    /// Currently-selected colour variant for the given template. Falls
    /// back to variant 0 when the template has no variants defined or
    /// when the saved index is out of range.
    private func colorVariant(for template: ShareCardTemplate) -> TemplateColorVariant? {
        let variants = template.colorVariants
        guard !variants.isEmpty else { return nil }
        let idx = min(max(0, colorVariantIndex[template] ?? 0), variants.count - 1)
        return variants[idx]
    }

    /// Tint to use when rendering a given template — variant tint when
    /// available, else the template's natural default colour.
    private func renderingTint(for template: ShareCardTemplate) -> Color {
        if let v = colorVariant(for: template) { return v.tint }
        return template == .electricLive ? cardBlue : cardGray
    }

    /// Outer + mid halo colours for the active colorama variant. The
    /// outer (heavier blur) uses the deepest hue of the palette; the
    /// mid (brighter, tighter) uses the saturated mid stop.
    private func coloramaHaloColors() -> (outer: Color, mid: Color) {
        switch colorVariantIndex[.colorama] ?? 0 {
        case 1: // pink
            return (
                Color(red: 0.700, green: 0.180, blue: 0.380),
                Color(red: 0.910, green: 0.243, blue: 0.486) // #E83E7C
            )
        case 2: // sage
            return (
                Color(red: 0.350, green: 0.580, blue: 0.300),
                Color(red: 0.510, green: 0.776, blue: 0.431)
            )
        case 3: // sunset
            return (
                Color(red: 0.200, green: 0.350, blue: 0.580),
                Color(red: 0.282, green: 0.471, blue: 0.722)
            )
        default: // unchanged default blue
            return (
                Color(red: 0.10, green: 0.20, blue: 0.95),
                Color(red: 0.18, green: 0.30, blue: 1.00)
            )
        }
    }

    /// Silhouette-only version of `Resources/logo.png`. The source PNG
    /// has no alpha channel — dark silhouettes on a solid white BG —
    /// so we invert luminance (dark → bright) and run that through
    /// `CIMaskToAlpha`, which yields a white-on-transparent shape with
    /// alpha derived from the original's silhouettes. Computed once.
    private static let coloramaLogo: UIImage? = {
        guard let original = UIImage(named: "logo"),
              let cgImage = original.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)

        let inverter = CIFilter(name: "CIColorInvert")
        inverter?.setValue(input, forKey: kCIInputImageKey)
        guard let inverted = inverter?.outputImage else { return nil }

        let masker = CIFilter(name: "CIMaskToAlpha")
        masker?.setValue(inverted, forKey: kCIInputImageKey)
        guard let masked = masker?.outputImage else { return nil }

        let context = CIContext()
        guard let cgOutput = context.createCGImage(masked, from: masked.extent) else { return nil }
        return UIImage(
            cgImage: cgOutput,
            scale: original.scale,
            orientation: original.imageOrientation
        )
    }()

    /// Picks the colorama displacement shader for the active variant.
    /// One stitchable function per palette in `Colorama.metal` because
    /// SwiftUI's shader bridge doesn't accept Color/float3/float4 args
    /// — palette has to be hardcoded per shader.
    private func coloramaDisplacedShader(
        t: Double, cardW: CGFloat, cardH: CGFloat
    ) -> Shader {
        let argT: Shader.Argument = .float(Float(t))
        let argW: Shader.Argument = .float(Float(cardW))
        let argH: Shader.Argument = .float(Float(cardH))
        switch colorVariantIndex[.colorama] ?? 0 {
        case 1:  return ShaderLibrary.coloramaDisplacedPink(argT, argW, argH)
        case 2:  return ShaderLibrary.coloramaDisplacedSage(argT, argW, argH)
        case 3:  return ShaderLibrary.coloramaDisplacedSunset(argT, argW, argH)
        default: return ShaderLibrary.coloramaDisplacedDefault(argT, argW, argH)
        }
    }


    /// Row of colour-variant dots shown beneath the carousel for the
    /// currently-selected template. Tap a dot to switch the template's
    /// active variant — no animation, the change is immediate.
    private var templateColorPicker: some View {
        let variants = selectedTemplate.colorVariants
        let activeId = colorVariant(for: selectedTemplate)?.id ?? 0

        return HStack(spacing: 14) {
            ForEach(variants) { variant in
                Button {
                    colorVariantIndex[selectedTemplate] = variant.id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Circle()
                        .fill(variant.tint)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    AppPalette.textSecondary,
                                    lineWidth: variant.id == activeId ? 1.5 : 0
                                )
                                .padding(-3.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 24)
    }

    /// Floating template name above the carousel. Hard-cut on change —
    /// `.transaction` strips any animation that might be inherited from
    /// the surrounding `withAnimation` calls (carousel snap, dot scrub).
    private var templateTitle: some View {
        Text(selectedTemplate.name.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textMuted)
            .frame(height: 22)
            .transaction { $0.animation = nil }
    }

    /// Dot row with macOS-Dock-style magnification. Scrubbable: drag
    /// across the dots and the selection follows your finger with snap
    /// + haptic at each template boundary. The lens also reflects an
    /// in-progress carousel swipe so the two stay in sync.
    private var templatePicker: some View {
        let templates = availableTemplates
        // The picker is small / flat at rest and "wakes up" — bigger
        // dots, wider spacing, magnifying lens on — only while the user
        // is interacting. Interaction = scrubbing the dots OR dragging
        // the carousel, both of which mutate state we already track.
        let isActive = dotScrubPosition != nil || abs(carouselDragOffset) > 0.5
        let dotSize: CGFloat = isActive ? 6 : 4
        let dotSpacing: CGFloat = isActive ? 18 : 11
        let maxScale: CGFloat = isActive ? 2.4 : 1.0
        let spread: CGFloat = 2.0
        let active = pickerActivePosition
        let activeIntClamped = Int(round(
            max(0, min(CGFloat(templates.count - 1), active))
        ))

        return GeometryReader { geo in
            let totalWidth = CGFloat(max(0, templates.count - 1)) * dotSpacing
            let leadingX = (geo.size.width - totalWidth) / 2

            ZStack {
                ForEach(Array(templates.enumerated()), id: \.element) { i, _ in
                    let centerX = leadingX + CGFloat(i) * dotSpacing
                    let d = abs(active - CGFloat(i))
                    let proximity = max(0, 1 - d / spread)
                    let scale = 1 + (maxScale - 1) * proximity * proximity
                    let isSelected = i == activeIntClamped

                    Circle()
                        .fill(isSelected ? AppPalette.textSecondary : AppPalette.textFaint)
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(scale)
                        .position(x: centerX, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard templates.count > 1 else { return }
                        let relativeX = value.location.x - leadingX
                        let frac = relativeX / dotSpacing
                        let clamped = max(0, min(CGFloat(templates.count - 1), frac))
                        dotScrubPosition = clamped

                        let snapped = Int(round(clamped))
                        let newTemplate = templates[snapped]
                        if newTemplate != selectedTemplate {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                templateSlideEdge =
                                    snapped > (templates.firstIndex(of: selectedTemplate) ?? 0)
                                    ? .trailing : .leading
                                selectedTemplate = newTemplate
                            }
                        }
                    }
                    .onEnded { _ in
                        // Release the scrub override and let the lens
                        // settle back onto the selected template. The
                        // animation is what produces the "magnetism"
                        // feel as the magnification snaps into place.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            dotScrubPosition = nil
                        }
                    }
            )
        }
        .frame(height: 36)
        // Spring the size/spacing changes when the picker wakes / sleeps.
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: isActive)
    }

    // MARK: - Share actions

    private var shareActions: some View {
        let exporting = activeExport != nil
        return HStack(spacing: 10) {
            Button {
                activeExport = .instagramStories
                storyHaptic.impactOccurred()
                exportAndShareVideo(destination: .instagramStories)
            } label: {
                HStack(spacing: 6) {
                    if activeExport == .instagramStories {
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
                .appCapsule()
            }
            .buttonStyle(.plain)
            .disabled(exporting)

            Button {
                activeExport = .cameraRoll
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                exportAndShareVideo(destination: .cameraRoll)
            } label: {
                HStack(spacing: 6) {
                    if activeExport == .cameraRoll {
                        ProgressView()
                            .tint(AppPalette.textMuted)
                            .scaleEffect(0.7)
                    } else {
                        AppIcon(glyph: .image, size: 12, color: AppPalette.iconPrimary)
                    }
                    Text("SAVE")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(AppPalette.textMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .appCapsule()
            }
            .buttonStyle(.plain)
            .disabled(exporting)
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
    // Full Instagram Stories resolution. Half-res (540x960) was visibly
    // soft once IG upscaled it to phone width.
    private let storyCanvas = CGSize(width: 1080, height: 1920)

    /// Snapshot the dynamic front-layer view (mono/electric date text,
    /// OOTD's DAY+MONTH) so it's included in the exported video.
    @MainActor
    private func renderDynamicFrontImage(size: CGSize) -> UIImage? {
        let view = cardFrontLayer(for: selectedTemplate)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2
        return renderer.uiImage
    }

    @MainActor
    private func renderDynamicBackImage(
        size: CGSize,
        time: Double? = nil
    ) -> UIImage? {
        // Snapshot the live back-layer view for dynamic templates.
        // Pass `time` to drive a specific frame of the colorama animation
        // — used by the export loop to render each video frame at its
        // own moment of the cycle.
        let view = cardBackLayer(for: selectedTemplate, forcedTime: time)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2
        return renderer.uiImage
    }

    private enum ExportDestination {
        case instagramStories
        case cameraRoll
    }

    private func exportAndShareVideo(destination: ExportDestination = .instagramStories) {
        Task {
            // Sleep ~one frame so the SwiftUI re-render that swaps the
            // icon for the spinner actually paints before we grab the
            // main thread for the first heavy render. `Task.yield()`
            // alone wasn't enough — the task can resume before the
            // pending UI render runs.
            try? await Task.sleep(for: .milliseconds(50))

            let canvas = storyCanvas
            // We render the back/front layers at HALF the canvas
            // dimensions (logical) — the SwiftUI layout (font sizes,
            // text positions, halo blur radii etc.) was tuned for that
            // size. The renderer's scale=2 then gives us underlying
            // pixels that match the full 1080-wide canvas, so the
            // snapshot draws crisp 1:1 at the larger card rect.
            let renderCanvasScale: CGFloat = 0.5
            let cardW = canvas.width * 0.82 * renderCanvasScale
            let cardH = cardW * (480.0 / 342.0)
            let backSize = CGSize(width: cardW, height: cardH)

            // Only colorama animates per-frame (the gradient cycle).
            // Mono / electric / OOTD have STATIC back layers, so we
            // render their back ONCE here instead of per-frame in the
            // loop — this used to do 45 redundant SwiftUI renders per
            // export and was the dominant cost for those templates.
            let isColorama = selectedTemplate == .colorama
            let staticBackImage: UIImage? = await MainActor.run {
                if !selectedTemplate.isDynamic {
                    return UIImage(named: selectedTemplate.backImageName)
                }
                if isColorama { return nil }  // rendered per-frame below
                return renderDynamicBackImage(size: backSize, time: nil)
            }
            // Front layer for dynamic templates contains the date text
            // (mono/electric top + bottom labels, OOTD's DAY+MONTH)
            // and isn't a bundled PNG — snapshot the SwiftUI view ONCE
            // since the text doesn't animate per video frame.
            let frontImage: UIImage? = await MainActor.run {
                if selectedTemplate.isDynamic {
                    return renderDynamicFrontImage(size: backSize)
                }
                return selectedTemplate.frontImageName.flatMap { UIImage(named: $0) }
            }

            // One full forward rotation — seamless loop since frame 0 ≈ frame N (360° orbit)
            let totalFrames = outfit.frameCount
            let allIndices = Array(Swift.stride(from: 0, to: totalFrames, by: 2))

            guard !allIndices.isEmpty else {
                await MainActor.run { activeExport = nil; exportError = "No frames to export." }
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yafa-story-\(outfit.id).mp4")
            try? FileManager.default.removeItem(at: url)

            // Set up writer before loading any frames
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
                await MainActor.run { activeExport = nil; exportError = "Couldn't create video." }
                return
            }

            let fps = 30
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(canvas.width),
                AVVideoHeightKey: Int(canvas.height),
                // 8 Mbps gives crisp 1080×1920 output. The h264 default
                // for this resolution is closer to 2-3 Mbps which IG
                // re-encodes again on upload, compounding artefacts.
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
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

            // Pick a colorama cycle count that fits naturally inside the
            // video duration so the gradient phase wraps cleanly at the
            // loop boundary (other sin/cos terms have minor
            // discontinuities — accepted tradeoff).
            let totalIterations = allIndices.count
            let videoDuration = Double(totalIterations) / Double(fps)
            let coloramaCycles = max(
                1,
                Int(round(videoDuration / Self.coloramaCycleSeconds))
            )
            let totalShaderTime = Double(coloramaCycles) * Self.coloramaCycleSeconds

            // Stream: composite one frame at a time and write immediately.
            var writtenCount = 0
            for (i, outfitIndex) in allIndices.enumerated() {
                guard let outfitFrame = await FrameLoader.shared.frame(for: outfit, index: outfitIndex) else {
                    continue
                }

                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(5))
                }

                // Only colorama needs a fresh back image per frame
                // (the gradient cycles); other templates reuse the
                // single `staticBackImage` rendered up front.
                let frameBackImage: UIImage?
                if isColorama {
                    let frameTime = (Double(i) / Double(totalIterations)) * totalShaderTime
                    frameBackImage = await MainActor.run {
                        renderDynamicBackImage(size: backSize, time: frameTime)
                    }
                } else {
                    frameBackImage = staticBackImage
                }

                let composed = compositeFrame(outfitFrame: outfitFrame,
                                              backImage: frameBackImage,
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
                activeExport = nil
                guard success else {
                    exportError = "Couldn't export the video. Please try again."
                    return
                }
                switch destination {
                case .instagramStories:
                    shareToInstagramStories(videoURL: url)
                case .cameraRoll:
                    saveVideoToCameraRoll(videoURL: url)
                }
            }
        }
    }

    private func saveVideoToCameraRoll(videoURL: URL) {
        // Trigger system permission prompt automatically; if denied,
        // surface a clear error. `addOnly` is sufficient since we're
        // only writing, not reading the user's library.
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if !success {
                            exportError = error?.localizedDescription
                                ?? "Couldn't save to camera roll."
                        } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
            case .denied, .restricted:
                DispatchQueue.main.async {
                    exportError = "Photos access denied. Allow access in Settings to save videos."
                }
            case .notDetermined:
                break // requestAuthorization will resolve to one of the above
            @unknown default:
                break
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

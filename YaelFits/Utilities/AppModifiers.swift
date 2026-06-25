import SwiftUI
import UIKit

struct LightBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeCoordinator() -> Coordinator {
        Coordinator(style: style)
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        // Only re-create the blur effect if the style actually
        // changed. The previous unconditional `uiView.effect =
        // UIBlurEffect(style: style)` re-instantiated the blur on
        // EVERY SwiftUI render — and assigning a new
        // `UIBlurEffect` forces UIKit to tear down and re-sample
        // the entire backdrop. With multiple blur views on screen
        // (pill stack, chin, card) this was the dominant lag
        // source during animations: every frame, every blur view
        // was being rebuilt from scratch.
        guard context.coordinator.lastStyle != style else { return }
        uiView.effect = UIBlurEffect(style: style)
        context.coordinator.lastStyle = style
    }

    final class Coordinator {
        var lastStyle: UIBlurEffect.Style
        init(style: UIBlurEffect.Style) { self.lastStyle = style }
    }
}

/// Drop-in replacement for `.buttonStyle(.plain)` on frosted-glass
/// surfaces. `.plain` still fades the entire label (including its
/// `.background` slot) on press, which exposes the page background
/// through any `LightBlurView` chrome — the pill/picker buttons
/// briefly look transparent on tap. This style keeps the label at
/// full opacity and replaces the dim with a subtle scale-down for
/// tactile feedback. Haptics in the action closures provide the
/// rest of the press signal.
struct SolidPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct GradientBlurView: View {
    var height: CGFloat = 180

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: AppPalette.pageBackground, location: 0),
                .init(color: AppPalette.pageBackground, location: 0.4),
                .init(color: AppPalette.pageBackground.opacity(0.7), location: 0.6),
                .init(color: AppPalette.pageBackground.opacity(0.3), location: 0.8),
                .init(color: AppPalette.pageBackground.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .allowsHitTesting(false)
    }
}

// MARK: - Glassmorphism modifiers

private struct AppCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AppPalette.cardFill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppCapsuleModifier: ViewModifier {
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Capsule())
                    .overlay(Capsule().fill(AppPalette.cardFill))
            }
            .overlay(Capsule().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppCircleModifier: ViewModifier {
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(Circle())
                    .overlay(Circle().fill(AppPalette.cardFill))
            }
            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

private struct AppRoundedRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LightBlurView(style: .systemThinMaterialLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AppPalette.cardFill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: AppPalette.cardShadow, radius: shadowRadius, y: shadowY)
    }
}

extension View {
    func appCard(
        cornerRadius: CGFloat = LayoutMetrics.cardCornerRadius,
        shadowRadius: CGFloat = 18,
        shadowY: CGFloat = 10
    ) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appCapsule(
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppCapsuleModifier(shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appCircle(
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppCircleModifier(shadowRadius: shadowRadius, shadowY: shadowY))
    }

    func appRoundedRect(
        cornerRadius: CGFloat,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(AppRoundedRectModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius, shadowY: shadowY))
    }

    /// Solid, rounded-top sheet background. A plain `.presentationBackground(Color)`
    /// fills the whole presentation rect and renders SQUARE corners; drawing the
    /// rounded shape ourselves guarantees the rounding (the transparent corners
    /// reveal the dimmed content behind, like a normal sheet).
    func roundedSheetBackground(
        _ color: Color = AppPalette.groupedBackground,
        radius: CGFloat = 24
    ) -> some View {
        presentationBackground {
            UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius,
                style: .continuous
            )
            .fill(color)
            .ignoresSafeArea()
        }
    }
}

// MARK: - Trimmed remote product image

/// Loads a remote product image and crops its transparent margins so
/// the garment fills the frame, then renders it `scaledToFit`. Product
/// thumbnails are flat-lays with baked-in transparent padding that
/// otherwise makes them look randomly tiny/huge. The trim runs off the
/// main thread; the caller supplies the frame, so layout is stable.
/// In-memory cache of trimmed product images so re-created views (e.g.
/// when the closet grid swaps identity on a filter change) show instantly
/// instead of reloading/flickering.
enum TrimmedImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

struct TrimmedRemoteImage: View {
    let url: URL?
    /// Inset applied to the trimmed image inside its frame (breathing room).
    var contentPadding: CGFloat = 0

    /// Fired (main actor) whenever a freshly-loaded image is shown — lets the
    /// closet cell time its "polish complete" flourish to the moment the
    /// cut-out actually appears, not when polishing merely flips off.
    var onLoad: (() -> Void)? = nil

    @State private var image: UIImage?

    init(url: URL?, contentPadding: CGFloat = 0, onLoad: (() -> Void)? = nil) {
        self.url = url
        self.contentPadding = contentPadding
        self.onLoad = onLoad
        // Seed synchronously from cache so there's no blank frame.
        if let url, let cached = TrimmedImageCache.shared.object(forKey: url as NSURL) {
            _image = State(initialValue: cached)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(contentPadding)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        // Cache hit (including the URL we're already showing) — adopt it.
        if let cached = TrimmedImageCache.shared.object(forKey: url as NSURL) {
            if image !== cached {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) { image = cached }
                    onLoad?()
                }
            }
            return
        }
        // Cache miss — fetch this URL even when we're already showing a
        // previous one. The thumbnail swaps raw → cut-out in place when the
        // Share-Extension polish finishes and `image_url` changes; the old
        // `guard image == nil` blocked that reload until the view was
        // recreated (closing/reopening the closet).
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = UIImage(data: data) else { return }
        let trimmed = await Task.detached(priority: .userInitiated) {
            raw.trimmingTransparentMargins()
        }.value
        TrimmedImageCache.shared.setObject(trimmed, forKey: url as NSURL)
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.2)) { image = trimmed }
            onLoad?()
        }
    }
}

extension UIImage {
    /// Crop away the near-transparent border so the opaque content fills
    /// the image. Returns self if there's no croppable margin.
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

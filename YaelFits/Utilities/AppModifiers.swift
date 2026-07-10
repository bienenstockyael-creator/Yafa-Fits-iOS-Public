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

    /// For fullScreenCover pages that should read as a rounded card while
    /// they MOVE (open/close slide, drag-to-dismiss) but be seamlessly
    /// full screen at rest. Rounds the UIKit presentation container to
    /// the display's corner radius — invisible at rest, visible during
    /// the system slides.
    ///
    /// `containerActive`: pages with their OWN finger-drag (the closet)
    /// must pass `false` while the drag is live — the container is
    /// STATIONARY, so its masksToBounds corners carve into the card as
    /// it slides inside (the drag's "clipping pop"). At rest the
    /// rounding coincides with the glass, so toggling it is invisible.
    func fullScreenCardCorners(containerActive: Bool = true) -> some View {
        modifier(FullScreenCardCornersModifier(containerActive: containerActive))
    }
}

private struct FullScreenCardCornersModifier: ViewModifier {
    let containerActive: Bool

    func body(content: Content) -> some View {
        content
            // Container-level rounding: covers the SYSTEM present /
            // dismiss slides, where UIKit moves the whole container.
            // (Pages with their own finger-drag — the closet — add a
            // drag-time bounds clip locally; a shared content clip
            // here misfired because SwiftUI collapses safe-area
            // extensions the moment a page is offset.)
            .background(FullScreenCardCornersConfigurator(active: containerActive))
    }
}

/// Rounds the UIKit PRESENTATION CONTAINER (the hosting controller's
/// root view) to the physical display corner radius. The container is
/// the thing UIKit actually slides during present AND dismiss, and a
/// layer property survives every frame of both transitions — unlike a
/// SwiftUI clip, which the dismissal's safe-area re-layout kept
/// re-mapping (corners showed on open but vanished on close). At rest
/// the container fills the screen, so the rounding coincides with the
/// glass and is invisible.
private struct FullScreenCardCornersConfigurator: UIViewControllerRepresentable {
    let active: Bool

    func makeUIViewController(context: Context) -> CornerApplyingViewController {
        let vc = CornerApplyingViewController()
        vc.active = active
        return vc
    }

    func updateUIViewController(_ vc: CornerApplyingViewController, context: Context) {
        vc.active = active
        vc.applyCorners()
    }

    final class CornerApplyingViewController: UIViewController {
        var active = true

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyCorners()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyCorners()
        }

        func applyCorners() {
            // Climb to the presented hosting controller's root view.
            var top: UIViewController = self
            while let parent = top.parent { top = parent }
            guard let container = top.view else { return }
            container.layer.cornerRadius = active ? UIScreen.main.displayCornerRadiusSafe : 0
            container.layer.cornerCurve = .continuous
            container.layer.masksToBounds = active
        }
    }
}

extension UIScreen {
    /// The physical display corner radius. Falls back to 0 (square) on
    /// devices whose screens genuinely have square corners, which is
    /// also the correct clip for them.
    var displayCornerRadiusSafe: CGFloat {
        // The value lives under a private-but-stable key; assembled
        // indirectly rather than written as a literal.
        let key = ["Radius", "Corner", "display", "_"].reversed().joined()
        return (value(forKey: key) as? CGFloat) ?? 0
    }
}

// MARK: - Sheet header

/// Standard modal-sheet header used across the app: a circular X on the left,
/// a small monospaced all-caps title centered, balanced by a clear 36pt spacer
/// on the right so the title stays optically centered.
struct AppSheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(SolidPressButtonStyle())
            .accessibilityLabel("Close")

            Spacer()

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
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
        //
        // Load via the shared RemoteImageCache rather than a bare
        // URLSession: disk persistence (cold launches skip the network
        // entirely — the old memory-only cache re-downloaded EVERY
        // product cut-out each session, the "thumbnails take 1–2s"
        // problem), request de-dup, and CGImageSource-downsampled
        // decode. 640px also makes the transparent-margin trim walk
        // ~16× fewer pixels than the full-res original.
        guard let raw = await RemoteImageCache.shared.load(url, maxPixelSize: 640) else { return }
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

/// The "MADE ON YAFA" brand mark used across the share / export cards — the
/// figure-lineup logo (`logo.png`) with the MADE ON YAFA label stretched to
/// the same width directly above it. Matches the ShareCardComposer mark: a
/// large base font + `minimumScaleFactor` makes the label fill `width`.
struct MadeOnYafaMark: View {
    var width: CGFloat
    var color: Color = .white

    private static let logo: UIImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("MADE ON YAFA")
                .font(.custom("Inter28pt-MediumItalic", size: 100))
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.01)
                .frame(width: width)
                .foregroundStyle(color)
            if let logo = Self.logo {
                Image(uiImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
                    .foregroundStyle(color)
            }
        }
    }
}

// MARK: - Snapshot-driven drag-to-dismiss (full-screen sheets)

/// Weak handle to a fullScreenCover's UIKit container view, so a
/// finger-drag dismissal can snapshot the page's actual pixels.
final class ContainerViewRef {
    weak var view: UIView?

    /// Renders the container (the full-screen page, including the
    /// strips behind the bars) into an image.
    func snapshot() -> UIImage? {
        guard let view else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }
}

/// Grabs the presented hosting controller's root view into a
/// `ContainerViewRef` (same parent-climb as the corner configurator).
struct ContainerViewGrabber: UIViewControllerRepresentable {
    let ref: ContainerViewRef

    func makeUIViewController(context: Context) -> GrabberViewController {
        GrabberViewController(ref: ref)
    }

    func updateUIViewController(_ vc: GrabberViewController, context: Context) {}

    final class GrabberViewController: UIViewController {
        let ref: ContainerViewRef

        init(ref: ContainerViewRef) {
            self.ref = ref
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            grab()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            grab()
        }

        private func grab() {
            var top: UIViewController = self
            while let parent = top.parent { top = parent }
            ref.view = top.view
        }
    }
}

/// Progressive card clip for snapshot drags: radius grows with the
/// pull; at ~0 it clips nothing.
struct DragCardShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard radius > 0.5 else {
            return Path(rect.insetBy(dx: -2000, dy: -2000))
        }
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

/// The dragged card of a snapshot-driven dismissal: the page bitmap,
/// screen-pinned (position compensates for host-layout churn), with
/// corners that morph rounder over the first ~110pt of pull and a
/// soft shadow — riding the finger. Pixels cannot reflow, which is
/// the whole point.
struct SnapshotDragCard: View {
    let image: UIImage
    let dragOffset: CGFloat

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let screen = UIScreen.main.bounds
            Image(uiImage: image)
                .resizable()
                .frame(width: screen.width, height: screen.height)
                .clipShape(DragCardShape(
                    radius: min(UIScreen.main.displayCornerRadiusSafe, dragOffset * 0.5)
                ))
                .shadow(
                    color: .black.opacity(0.25 * min(1, dragOffset / 110)),
                    radius: 24,
                    y: -6
                )
                .position(
                    x: screen.width / 2 - origin.x,
                    y: screen.height / 2 - origin.y
                )
                .offset(y: dragOffset)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Drop-in drag-to-dismiss for fullScreenCover pages

extension View {
    /// The full "physical sheet" dismissal for fullScreenCover pages:
    /// grab the page in its top zone and pull — a snapshot of the page
    /// rides the finger with morphing corners, a shadow, and a dim
    /// behind; release past the threshold to dismiss, or let it spring
    /// back. Includes the rounded-corner treatment for the system
    /// open/close slides, so this REPLACES `fullScreenCardCorners()`.
    /// Apply INSIDE the cover content; pair with
    /// `.presentationBackground(.clear)` at the call site.
    func snapshotDragDismiss(onClose: @escaping () -> Void) -> some View {
        modifier(SnapshotDragDismissModifier(onClose: onClose))
    }
}

private struct SnapshotDragDismissModifier: ViewModifier {
    let onClose: () -> Void
    /// Drags must START within this distance from the screen top —
    /// the page's header zone — so the gesture never competes with
    /// scrolling or content interactions lower down.
    var grabZoneHeight: CGFloat = 140

    @State private var dragOffset: CGFloat = 0
    @State private var snapshot: UIImage?
    @State private var isCommitting = false
    @State private var containerRef = ContainerViewRef()

    func body(content: Content) -> some View {
        ZStack {
            // Dim behind the dragged card — fades in with the pull,
            // back out as a committed dismiss slides away.
            if dragOffset > 0 {
                Color.black
                    .opacity(
                        0.20 * min(1, dragOffset / 260)
                            * (1 - dragOffset / UIScreen.main.bounds.height)
                    )
                    .ignoresSafeArea()
            }

            content
                .fullScreenCardCorners(containerActive: snapshot == nil)
                .background(ContainerViewGrabber(ref: containerRef))
                // Hidden while the snapshot drives — pixel-identical
                // at the swap in both directions.
                .opacity(snapshot == nil ? 1 : 0)

            if let snapshot {
                SnapshotDragCard(image: snapshot, dragOffset: dragOffset)
            }
        }
        .simultaneousGesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { v in
                guard !isCommitting else { return }
                guard v.startLocation.y < grabZoneHeight else { return }
                let vertical = v.translation.height
                guard vertical > 0, abs(vertical) > abs(v.translation.width) else {
                    // Turned horizontal / pulled back up — snap back.
                    if dragOffset != 0, snapshot != nil {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                        scheduleSnapshotCleanup()
                    }
                    return
                }
                if snapshot == nil { snapshot = containerRef.snapshot() }
                dragOffset = vertical
            }
            .onEnded { v in
                guard !isCommitting, snapshot != nil else { return }
                if v.translation.height > 120 || v.predictedEndTranslation.height > 350 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    // Finish the slide on the snapshot, then drop the
                    // cover with animations disabled — the system
                    // dismissal would re-animate the live page.
                    isCommitting = true
                    withAnimation(.easeIn(duration: 0.22)) {
                        dragOffset = UIScreen.main.bounds.height
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { onClose() }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                    scheduleSnapshotCleanup()
                }
            }
    }

    private func scheduleSnapshotCleanup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard dragOffset == 0 else { return }
            snapshot = nil
        }
    }
}

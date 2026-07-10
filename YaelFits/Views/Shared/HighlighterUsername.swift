import SwiftUI
import UIKit

/// Text rendered on a single, unified colored shape that traces
/// per-line widths — the magazine-paste "highlighter blob" look.
/// Used by the `bust` profile header style for the display name.
///
/// Architecture:
///   1. Display name is split into up to two roughly-balanced
///      lines at whitespace boundaries.
///   2. Each line's text width is measured via UIKit's
///      `NSString.size` so the shape lines up exactly with the
///      SwiftUI text rendering.
///   3. A custom `HighlighterBlobShape` draws ONE path that
///      traces the union of the per-line rounded rectangles —
///      with smooth fillets at the concave step-down corners
///      where line 1's narrower width meets line 2's wider
///      width (or vice-versa). The fill ends up as a single
///      colored blob with rounded curves all the way around,
///      visually unified rather than two stacked pills.
///   4. Text sits on top inside a `VStack(spacing: 0)`,
///      width-matched to the shape by sharing the same
///      horizontal padding measurement.
struct HighlighterUsername: View {
    let text: String
    /// Accent color drawn behind the text.
    var color: Color
    /// Font size for the rendered text — BASE size, before
    /// Dynamic Type scaling. The component multiplies this by
    /// the system's body-text scale factor (read via
    /// `@ScaledMetric` below) so a user with Larger Text
    /// enabled in iOS Settings gets a proportionally larger
    /// highlighter without losing the shape's shape-glyph
    /// alignment.
    var fontSize: CGFloat = 20
    /// Horizontal padding inside each line's pill — tight
    /// enough that the blob hugs the glyphs on the sides like
    /// a marker highlight rather than a button.
    var horizontalPadding: CGFloat = 8
    /// Vertical padding inside each line's pill. Combined with
    /// the `lineHeight` formula below, this gives just enough
    /// room above and below the glyphs that descenders aren't
    /// kissed off, while keeping the two lines stacked tight
    /// against each other so the blob reads as one shape.
    var verticalPadding: CGFloat = 1
    /// Tilt applied to the whole blob (deg).
    var rotation: Double = 0
    /// Corner radius applied to outer convex corners AND
    /// concave step-down fillets — rounded everywhere.
    var cornerRadius: CGFloat = 8

    /// Dynamic Type scale factor (relative to `.body`). At the
    /// default content size category this is 1.0; at Larger
    /// Text settings it scales up. Multiplying the base
    /// `fontSize` by this and feeding the result through the
    /// shape's geometry keeps the bg blob hugging the glyphs
    /// at every text size — without this the text would grow
    /// past the shape's bounds at larger settings. Consumers
    /// should clamp `.dynamicTypeSize(...)` at the parent
    /// level to bound the maximum scale.
    @ScaledMetric(relativeTo: .body) private var dynamicScale: CGFloat = 1

    /// Effective font size after Dynamic Type scaling. All
    /// internal measurements + the rendered Text use this.
    private var scaledFontSize: CGFloat { fontSize * dynamicScale }

    var body: some View {
        ZStack {
            HighlighterBlobShape(
                lineWidths: lineWidths,
                lineHeight: lineHeight,
                cornerRadius: cornerRadius
            )
            .fill(color)

            VStack(spacing: 0) {
                ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: scaledFontSize, weight: .bold))
                        .foregroundStyle(AppPalette.textStrong)
                        .frame(height: lineHeight)
                        .padding(.horizontal, horizontalPadding)
                }
            }
        }
        .frame(width: shapeWidth, height: shapeHeight)
        .rotationEffect(.degrees(rotation))
    }

    /// Splits the display name into up to two width-balanced
    /// lines at whitespace boundaries. Picks the split point
    /// that minimizes the wider of the two lines, so names
    /// with uneven word lengths don't lopside the blob.
    ///
    /// Examples:
    ///   "Yael Bienenstock"  -> ["Yael", "Bienenstock"]
    ///   "Mary Jane Smith"   -> ["Mary", "Jane Smith"]   // width-balanced
    ///   "X Bienenstock"     -> ["X", "Bienenstock"]
    ///   "Cher"              -> ["Cher"]
    ///
    /// Naive word-count midpoint was the prior implementation
    /// and produced visibly imbalanced blobs for names where
    /// the words varied much in length.
    private var displayLines: [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [text] }

        let attrs: [NSAttributedString.Key: Any] = [.font: measuringFont]
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: attrs).width
        }

        var bestSplit = 1
        var bestMaxWidth = CGFloat.infinity
        for splitAt in 1..<words.count {
            let first = words[..<splitAt].joined(separator: " ")
            let second = words[splitAt...].joined(separator: " ")
            let wider = max(width(first), width(second))
            if wider < bestMaxWidth {
                bestMaxWidth = wider
                bestSplit = splitAt
            }
        }

        let first = words[..<bestSplit].joined(separator: " ")
        let second = words[bestSplit...].joined(separator: " ")
        return [first, second]
    }

    private var measuringFont: UIFont {
        .systemFont(ofSize: scaledFontSize, weight: .bold)
    }

    /// Per-line pill width = rendered text width + horizontal
    /// padding on both sides. Driven by UIKit measurement so
    /// the shape lines up exactly with SwiftUI's text render.
    private var lineWidths: [CGFloat] {
        let attrs: [NSAttributedString.Key: Any] = [.font: measuringFont]
        return displayLines.map { line in
            let textW = (line as NSString).size(withAttributes: attrs).width
            return textW + 2 * horizontalPadding
        }
    }

    /// Single-line height = font SIZE + vertical padding
    /// (top + bottom). Using `fontSize` instead of the font's
    /// natural `lineHeight` (which includes ascender slack +
    /// internal leading) is what makes the two lines sit
    /// tight against each other — without this, the SF font's
    /// built-in line gap leaves a visible band between
    /// stacked highlighter rows.
    private var lineHeight: CGFloat {
        scaledFontSize + 2 * verticalPadding
    }

    private var shapeWidth: CGFloat { lineWidths.max() ?? 0 }
    private var shapeHeight: CGFloat { lineHeight * CGFloat(displayLines.count) }
}

/// Custom shape that traces the union of N stacked rounded
/// rectangles (one per line) as a single closed Path. At every
/// joint where line widths differ, smooth quadratic-Bezier
/// fillets replace the 90° step-down — both the outer convex
/// corners and the inner concave junctions read as rounded
/// curves.
///
/// All corners use `addQuadCurve` with the control point placed
/// at the CORNER itself. This makes every fillet tangent-continuous
/// with the adjacent straight segments — incoming and outgoing
/// tangents align with the lines they connect, so the curve flows
/// smoothly without cusps. (Placing the control at the bbox's
/// opposite corner produced a discontinuous tangent at the joint,
/// which made the silhouette read as two separate pills instead
/// of one unified blob.)
struct HighlighterBlobShape: Shape {
    /// Pre-measured width of each line's pill (text + padding).
    let lineWidths: [CGFloat]
    /// Pre-measured height of each line (font + padding).
    let lineHeight: CGFloat
    /// Corner / fillet radius.
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard !lineWidths.isEmpty else { return Path() }
        let cx = rect.midX
        let r = cornerRadius
        let n = lineWidths.count

        // Per-line edge accessors. y starts at rect.minY so the
        // shape draws relative to the actual frame origin (not
        // always 0,0 in some layout contexts).
        func leftX(_ i: Int) -> CGFloat { cx - lineWidths[i] / 2 }
        func rightX(_ i: Int) -> CGFloat { cx + lineWidths[i] / 2 }
        func topY(_ i: Int) -> CGFloat { rect.minY + CGFloat(i) * lineHeight }
        func botY(_ i: Int) -> CGFloat { rect.minY + CGFloat(i + 1) * lineHeight }

        if n == 1 {
            return Path(
                roundedRect: CGRect(
                    x: leftX(0),
                    y: topY(0),
                    width: lineWidths[0],
                    height: lineHeight
                ),
                cornerRadius: r
            )
        }

        var p = Path()

        // ── Top-left corner of line 0 + top edge + top-right ──
        p.move(to: CGPoint(x: leftX(0), y: topY(0) + r))
        // Top-left convex (going UP → RIGHT): control at corner
        p.addQuadCurve(
            to: CGPoint(x: leftX(0) + r, y: topY(0)),
            control: CGPoint(x: leftX(0), y: topY(0))
        )
        p.addLine(to: CGPoint(x: rightX(0) - r, y: topY(0)))
        // Top-right convex (going RIGHT → DOWN): control at corner
        p.addQuadCurve(
            to: CGPoint(x: rightX(0), y: topY(0) + r),
            control: CGPoint(x: rightX(0), y: topY(0))
        )

        // ── Walk DOWN the right side, joint by joint ───────
        // Every corner uses `control = the corner point itself`,
        // which keeps the curve TANGENT to both adjacent straight
        // segments. This produces a smooth corner that flows
        // continuously out of the line above into the line below
        // — no cusps, no visible seams at the joints. (Putting
        // the control at the bbox's opposite corner produced a
        // discontinuous tangent and made the joint look like two
        // separate pills.)
        for i in 0..<(n - 1) {
            let curR = rightX(i)
            let nextR = rightX(i + 1)
            let joinY = botY(i)

            if curR < nextR {
                // Step OUT to the right (next wider).
                p.addLine(to: CGPoint(x: curR, y: joinY - r))
                p.addQuadCurve(
                    to: CGPoint(x: curR + r, y: joinY),
                    control: CGPoint(x: curR, y: joinY)
                )
                p.addLine(to: CGPoint(x: nextR - r, y: joinY))
                p.addQuadCurve(
                    to: CGPoint(x: nextR, y: joinY + r),
                    control: CGPoint(x: nextR, y: joinY)
                )
            } else if curR > nextR {
                // Step IN to the left (next narrower).
                p.addLine(to: CGPoint(x: curR, y: joinY - r))
                p.addQuadCurve(
                    to: CGPoint(x: curR - r, y: joinY),
                    control: CGPoint(x: curR, y: joinY)
                )
                p.addLine(to: CGPoint(x: nextR + r, y: joinY))
                p.addQuadCurve(
                    to: CGPoint(x: nextR, y: joinY + r),
                    control: CGPoint(x: nextR, y: joinY)
                )
            } else {
                p.addLine(to: CGPoint(x: curR, y: joinY))
            }
        }

        // ── Bottom-right + bottom edge + bottom-left ───────
        let last = n - 1
        p.addLine(to: CGPoint(x: rightX(last), y: botY(last) - r))
        // Convex bottom-right (going DOWN → LEFT): control at corner
        p.addQuadCurve(
            to: CGPoint(x: rightX(last) - r, y: botY(last)),
            control: CGPoint(x: rightX(last), y: botY(last))
        )
        p.addLine(to: CGPoint(x: leftX(last) + r, y: botY(last)))
        // Convex bottom-left (going LEFT → UP): control at corner
        p.addQuadCurve(
            to: CGPoint(x: leftX(last), y: botY(last) - r),
            control: CGPoint(x: leftX(last), y: botY(last))
        )

        // ── Walk UP the left side, joint by joint ──────────
        // Same tangent-continuous treatment as the right side:
        // control at the corner point for ALL joints.
        for i in stride(from: n - 1, through: 1, by: -1) {
            let curL = leftX(i)
            let prevL = leftX(i - 1)
            let joinY = topY(i)

            if curL < prevL {
                // Lower line (cur) wider than upper (prev) —
                // going UP, step IN to the right.
                p.addLine(to: CGPoint(x: curL, y: joinY + r))
                p.addQuadCurve(
                    to: CGPoint(x: curL + r, y: joinY),
                    control: CGPoint(x: curL, y: joinY)
                )
                p.addLine(to: CGPoint(x: prevL - r, y: joinY))
                p.addQuadCurve(
                    to: CGPoint(x: prevL, y: joinY - r),
                    control: CGPoint(x: prevL, y: joinY)
                )
            } else if curL > prevL {
                // Lower line (cur) narrower than upper (prev) —
                // going UP, step OUT to the left.
                p.addLine(to: CGPoint(x: curL, y: joinY + r))
                p.addQuadCurve(
                    to: CGPoint(x: curL - r, y: joinY),
                    control: CGPoint(x: curL, y: joinY)
                )
                p.addLine(to: CGPoint(x: prevL + r, y: joinY))
                p.addQuadCurve(
                    to: CGPoint(x: prevL, y: joinY - r),
                    control: CGPoint(x: prevL, y: joinY)
                )
            } else {
                p.addLine(to: CGPoint(x: curL, y: joinY))
            }
        }

        // Close back to top-left
        p.addLine(to: CGPoint(x: leftX(0), y: topY(0) + r))
        p.closeSubpath()

        return p
    }
}

// MARK: - Diary note (fit annotation)

/// The minimal set of text styles a user can pick for a diary note on a
/// fit — mirrors the "few tasteful choices" of Instagram story text.
/// Handwritten + typewriter map to iOS system faces (no bundled asset);
/// yafaMono is the app's all-caps monospace label look; clean is the
/// app's standard text font; highlighter reuses the bust marker style.
enum DiaryNoteStyle: String, CaseIterable, Sendable, Identifiable {
    case handwritten
    case typewriter
    case highlighter
    case yafaMono
    case clean

    var id: String { rawValue }

    /// Tolerant decode — unknown/nil rawValue falls back to handwritten.
    static func from(_ raw: String?) -> DiaryNoteStyle {
        guard let raw, let s = DiaryNoteStyle(rawValue: raw) else { return .handwritten }
        return s
    }

    var accessibilityName: String {
        switch self {
        case .handwritten: return "Handwritten"
        case .typewriter:  return "Typewriter"
        case .highlighter: return "Highlighter"
        case .yafaMono:    return "Yafa mono"
        case .clean:       return "Clean"
        }
    }

    /// Uppercase the text (the Yafa caps-mono look).
    var isUppercased: Bool { self == .yafaMono }
    var tracking: CGFloat { self == .yafaMono ? 1.5 : 0 }

    func font(size: CGFloat) -> Font {
        switch self {
        // Bradley Hand — iOS's nicest built-in casual handwriting
        // (Noteworthy read like lined-notebook print).
        case .handwritten: return .custom("BradleyHandITCTT-Bold", size: size)
        case .typewriter:  return .custom("AmericanTypewriter", size: size)
        case .highlighter: return .system(size: size, weight: .semibold)
        case .yafaMono:    return .system(size: size, weight: .bold, design: .monospaced)
        case .clean:       return .system(size: size, weight: .medium)
        }
    }

    /// UIKit twin of `font(size:)` for the editor's UITextView input.
    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .handwritten:
            return UIFont(name: "BradleyHandITCTT-Bold", size: size)
                ?? .systemFont(ofSize: size, weight: .bold)
        case .typewriter:
            return UIFont(name: "AmericanTypewriter", size: size)
                ?? .systemFont(ofSize: size)
        case .highlighter: return .systemFont(ofSize: size, weight: .semibold)
        case .yafaMono:    return .monospacedSystemFont(ofSize: size, weight: .bold)
        case .clean:       return .systemFont(ofSize: size, weight: .medium)
        }
    }
}

/// Palette of light "inks" for a diary note — chosen to read well over
/// an outfit photo (and over the dark editor). For `highlighter` the
/// color is the marker fill (text stays dark).
enum DiaryInk {
    static let palette: [Color] = [
        .white,
        Color(red: 1.0, green: 0.78, blue: 0.85),   // pink
        Color(red: 0.62, green: 0.80, blue: 1.0),   // blue
        Color(red: 1.0, green: 0.86, blue: 0.45),   // yellow
        Color(red: 0.68, green: 0.95, blue: 0.82),  // mint
        // Appended LAST — saved notes store a palette index, so inserting
        // anywhere else would recolor every existing note.
        Color(red: 0.12, green: 0.12, blue: 0.13),  // black
    ]

    /// True for inks too dark to carry dark-on-ink text (the highlighter
    /// pill flips to white text for these).
    static func isDark(_ color: Color) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.45
    }
}

/// Renders a diary note in its chosen style. Used on the fit in the
/// carousel (owner + shared viewers) and, later, on the share card.
struct DiaryNoteView: View {
    let text: String
    let style: DiaryNoteStyle
    /// Ink color (text color; marker fill for highlighter).
    var color: Color = .white
    var size: CGFloat = 20
    /// Drop the legibility shadow (used in the editor, where re-rendering the
    /// shadow every gesture frame caused a shimmer).
    var showShadow: Bool = true

    var body: some View {
        let display = style.isUppercased ? text.uppercased() : text
        Text(display)
            .font(style.font(size: size))
            .tracking(style.tracking)
            .foregroundStyle(
                style == .highlighter
                    ? (DiaryInk.isDark(color) ? .white : Color(red: 0.11, green: 0.12, blue: 0.15))
                    : color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, style == .highlighter ? 7 : 0)
            .padding(.vertical, style == .highlighter ? 3 : 0)
            .background {
                if style == .highlighter {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                }
            }
            // Soft shadow keeps light ink legible over a busy photo.
            .shadow(color: (showShadow && style != .highlighter) ? .black.opacity(0.22) : .clear, radius: 2.5, y: 1)
    }
}

/// Modal editor for a fit's diary note. WYSIWYG on a dark canvas (like
/// IG story text): type, pick one of the tasteful styles + an ink color.
/// Empty text on save = delete the note.
/// Reports the diary note's rendered (unscaled) size so the editor can
/// keep its bounding box inside the safe zone as you drag/pinch.
private struct DiaryNoteSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

/// In-place note editor — NOT a sheet. Renders as a full-screen layer
/// that DIMS the carousel behind it (the fit stays visible, dimmed) and
/// floats the editing chrome on top, like Instagram story text: type in
/// the middle, pick a style at the bottom, Cancel/Done at the top. Tap
/// the dimmed area to commit.
/// UIKit-backed note input. Exists because SwiftUI's TextField resigns the
/// keyboard whenever its text attributes change (font/color chip taps) — a
/// UITextView updated in place NEVER does. Sized externally (it sits in the
/// overlay of an invisible mirror Text), so no intrinsic-size gymnastics.
private struct NoteInputField: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textAlignment = .center
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocapitalizationType = .sentences
        tv.keyboardAppearance = .dark
        tv.delegate = context.coordinator
        tv.text = text
        // Kick focus on the next tick instead of waiting for an updateUIView
        // pass — the window attaches a beat after make.
        DispatchQueue.main.async { [weak tv] in
            guard let tv else { return }
            context.coordinator.focusWhenReady(tv)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        // ONLY write when changed — unconditionally re-setting font/text on
        // every SwiftUI update pass invalidates UITextView's text layout,
        // which re-triggers layout, which re-runs updateUIView… a spin that
        // froze the UI on the first keystroke.
        if tv.text != text { tv.text = text }
        if tv.font != font { tv.font = font }
        if tv.textColor != textColor { tv.textColor = textColor }
        // First-responder changes are DEFERRED out of this update pass:
        // becoming/resigning first responder mutates SwiftUI-observed focus
        // state, and doing it synchronously inside updateUIView triggers
        // "Modifying state during view update, this will cause undefined
        // behavior" console spam.
        if isFocused {
            if !tv.isFirstResponder {
                let coordinator = context.coordinator
                DispatchQueue.main.async { [weak tv] in
                    guard let tv, coordinator.parent.isFocused else { return }
                    coordinator.focusWhenReady(tv)
                }
            }
        } else if tv.isFirstResponder {
            DispatchQueue.main.async { [weak tv] in
                tv?.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteInputField
        private var focusRetryScheduled = false
        init(_ parent: NoteInputField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        /// UIKit-level keyboard guard: while typing mode is active, ANY
        /// resign (e.g. the long-press entry touch churn — seen as ↓1 right
        /// after open) is reverted on the next runloop tick, so the keyboard
        /// comes back before its dismiss animation is visible.
        func textViewDidEndEditing(_ textView: UITextView) {
            guard parent.isFocused else { return }
            DispatchQueue.main.async { [weak textView] in
                guard let textView, self.parent.isFocused else { return }
                textView.becomeFirstResponder()
            }
        }

        /// becomeFirstResponder only works once the view is in a window —
        /// on mount (incl. mid-long-press entry) that can lag a beat, so
        /// retry on a tight interval instead of silently failing.
        func focusWhenReady(_ tv: UITextView, attempts: Int = 25) {
            guard !tv.isFirstResponder else { return }
            if tv.window != nil, tv.becomeFirstResponder() {
                return
            }
            guard attempts > 0, !focusRetryScheduled else { return }
            focusRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak tv] in
                self.focusRetryScheduled = false
                guard let tv, self.parent.isFocused else { return }
                self.focusWhenReady(tv, attempts: attempts - 1)
            }
        }
    }
}

/// In-place note editor (IG-style). Rendered as an overlay ON the carousel:
/// the chrome fades out, a dim scrim drops over the live carousel, and the
/// note is typed/positioned right where it will live — no sheet, no backdrop
/// swap. One full-screen gesture layer owns all manipulation (see
/// `manipulation(_:allowed:)`), with live clamping so nothing ever snaps.
struct DiaryNoteEditOverlay: View {
    /// Global frame of the fit's slide — the note's normalized coordinate
    /// space (pos 0..1 spans this rect; values outside 0..1 are legal and
    /// mean "around the fit"). Makes editor placement map 1:1 to display.
    let slideFrame: CGRect
    let initialText: String
    let initialStyle: DiaryNoteStyle
    let initialX: Double
    let initialY: Double
    let initialScale: Double
    let initialRotation: Double
    let initialColorIndex: Int
    let onSave: (String, DiaryNoteStyle, Double, Double, Double, Double, Int) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var style: DiaryNoteStyle
    @State private var pos: CGPoint       // normalized 0..1 within the canvas
    @State private var scale: CGFloat
    @State private var rotation: Angle
    @State private var colorIndex: Int
    // Live gesture values — @State (NOT @GestureState) so a re-render mid-drag
    // can't reset them and snap the note back. Folded into pos/scale/rotation
    // in .onEnded. Exact pattern from AutoDetectProductsView's floating tags.
    @State private var liveDrag: CGSize = .zero
    @State private var liveMagnify: CGFloat = 1.0
    @State private var liveRotate: Angle = .zero
    @State private var noteSize: CGSize = .zero
    /// True once the current gesture has meaningfully pinched or rotated —
    /// a near-stationary two-finger pinch must never be mistaken for a tap
    /// (that mistake was flipping the editor into typing mode mid-pinch).
    @State private var gestureDidTransform = false
    // Baseline so the control rows start above the keyboard with no first-show
    // jump; only ever GROWS (never shrinks), so the layout never drifts down.
    // 336 ≈ modern-iPhone keyboard height, so the first-show settle is tiny.
    @State private var keyboardHeight: CGFloat = 336
    /// Two clean modes (IG-style): text mode (keyboard up, editing) vs sticker
    /// mode (a plain Text you drag/pinch/rotate — no field, so it's smooth).
    @State private var editing = true
    // Tap-to-exit is disabled until the editor settles, so the long-press
    // entry's finger-lift can't immediately drop us out of edit mode.
    @State private var scrimArmed = false

    // Boundaries are the UI, not the fit: the note roams the whole screen
    // except the top chrome (Cancel/Done) and the bottom strip where the
    // action row / arrows live once the carousel chrome returns. Tunable.
    private let topReserved: CGFloat = 48       // below the Cancel/Done row
    private let sideInset: CGFloat = 6          // note CENTER stays on-screen
    private let bottomReserved: CGFloat = 64    // above the action-row strip

    init(
        slideFrame: CGRect,
        initialText: String,
        initialStyle: DiaryNoteStyle,
        initialX: Double,
        initialY: Double,
        initialScale: Double,
        initialRotation: Double,
        initialColorIndex: Int,
        onSave: @escaping (String, DiaryNoteStyle, Double, Double, Double, Double, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.slideFrame = slideFrame
        self.initialText = initialText
        self.initialStyle = initialStyle
        self.initialX = initialX
        self.initialY = initialY
        self.initialScale = initialScale
        self.initialRotation = initialRotation
        self.initialColorIndex = initialColorIndex
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        _style = State(initialValue: initialStyle)
        _pos = State(initialValue: CGPoint(x: initialX, y: initialY))
        _scale = State(initialValue: CGFloat(initialScale))
        _rotation = State(initialValue: .radians(initialRotation))
        _colorIndex = State(initialValue: initialColorIndex)
    }

    private var ink: Color {
        DiaryInk.palette.indices.contains(colorIndex) ? DiaryInk.palette[colorIndex] : .white
    }

    /// Whitespace-only counts as empty — a note of spaces shouldn't
    /// reach positioning mode or save as content.
    private var noteTextIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True while any manipulation gesture is live. Used to strip inherited
    /// animations off the note so it tracks the finger instead of easing.
    private var isGesturing: Bool {
        liveDrag != .zero || liveMagnify != 1.0 || liveRotate != .zero
    }

    private func commit() {
        onSave(text, style, Double(pos.x), Double(pos.y), Double(scale), rotation.radians, colorIndex)
    }

    /// Bottom safe-area inset of the key window (home-indicator strip).
    private static var windowSafeBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 34
    }

    /// The note's on-screen scale this frame (committed × live pinch), clamped
    /// live so the fold on release commits the exact displayed value — no snap.
    private var displayScale: CGFloat {
        min(3, max(0.4, scale * liveMagnify))
    }

    /// The note's on-screen center this frame: committed pos + live drag,
    /// clamped to `allowed` CONTINUOUSLY — the note stops at a boundary
    /// under the finger instead of escaping and snapping back on release.
    /// `f` is the slide rect (the normalized coordinate space); `allowed` is
    /// the roaming area (whole screen minus top chrome and bottom UI).
    private func livePlaced(_ f: CGRect, allowed: CGRect) -> CGPoint {
        let raw = CGPoint(x: f.minX + pos.x * f.width + liveDrag.width,
                          y: f.minY + pos.y * f.height + liveDrag.height)
        guard f.width > 0, f.height > 0 else { return raw }
        // Clamp the note's CENTER, not its bounding box — IG-style. The note
        // may hang partly past an edge; clamping the whole box made the
        // roaming area shrink with the note's size, which read as "tight".
        return CGPoint(
            x: min(allowed.maxX, max(allowed.minX, raw.x)),
            y: min(allowed.maxY, max(allowed.minY, raw.y)))
    }

    /// Generous hit test for "did this tap land on the note?" — the note's
    /// scaled bounding box padded out, floored at a 44pt finger target
    /// (IG-style forgiveness; rotation deliberately ignored).
    private func isNearNote(_ p: CGPoint, in f: CGRect, allowed: CGRect) -> Bool {
        let c = livePlaced(f, allowed: allowed)
        let halfW = max((noteSize.width * displayScale) / 2 + 24, 44)
        let halfH = max((noteSize.height * displayScale) / 2 + 24, 44)
        return abs(p.x - c.x) <= halfW && abs(p.y - c.y) <= halfH
    }

    var body: some View {
        GeometryReader { geo in
            // The hosting view BREATHES with the keyboard (an ancestor above
            // OutfitGridView partially avoids it — measured 68pt). Everything
            // here is therefore laid out in SCREEN coordinates inside a
            // fixed screen-sized canvas that is re-pinned to the physical
            // screen every frame via the live global origin — so no ancestor
            // resize can ever move the editor.
            let originG = geo.frame(in: .global).origin
            let screen = UIScreen.main.bounds
            let safeTop = LayoutMetrics.safeTop
            // slideFrame is global — and canvas coords ARE global coords.
            let f = slideFrame
            // Where the note may roam: the WHOLE screen, bounded only by the
            // top chrome and a bottom strip for the action row.
            let allowed = CGRect(
                x: sideInset,
                y: safeTop + topReserved,
                width: screen.width - sideInset * 2,
                height: (screen.height - Self.windowSafeBottom - bottomReserved)
                    - (safeTop + topReserved))
            // While typing, the input sits at the FIT'S CENTER — the same spot
            // an unpositioned sticker lands (pos 0.5/0.5), so leaving typing
            // mode is seamless. Capped to stay clear of the chips + keyboard.
            let typing = CGPoint(
                x: screen.width / 2,
                y: min(f.midY, screen.height - keyboardHeight - 170))

            ZStack {
                // IG-style dim over the LIVE carousel — no sheet, no backdrop
                // swap. Deeper while typing so the text pops; lighter while
                // positioning so the fit reads clearly underneath.
                Color.black.opacity(editing ? 0.55 : 0.35)
                    .allowsHitTesting(false)

                // Typing-mode tap-catcher: tap anywhere outside the field →
                // positioning mode (drop keyboard). Armed after the opening
                // touch lifts so a long-press entry can't kick us out.
                if editing {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard scrimArmed else { return }
                            if noteTextIsEmpty {
                                // Nothing to position — tapping out of an
                                // empty note exits the editor entirely.
                                editing = false
                                DispatchQueue.main.async { commit() }
                            } else {
                                withAnimation(.easeOut(duration: 0.22)) { editing = false }
                            }
                        }
                }

                // The note: text mode = centered field above the keyboard;
                // sticker mode = a passive sticker (hit-testing OFF — the
                // full-screen manipulation layer below owns ALL touches, so
                // grabbing it never depends on landing exactly on the glyphs).
                noteElement(fitFrame: f)
                    .position(editing ? typing : livePlaced(f, allowed: allowed))
                    .allowsHitTesting(editing)
                    // Gesture updates must track the finger 1:1 — strip any
                    // in-flight animation ONLY while a gesture is live, so the
                    // typing↔positioning mode change still glides.
                    .transaction { if isGesturing { $0.animation = nil } }

                // Positioning-mode manipulation surface — IG-style: drag,
                // pinch, and rotate work from ANYWHERE on screen and move the
                // note; taps are discriminated on release (near note → edit,
                // elsewhere → commit & close).
                if !editing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(manipulation(f, allowed: allowed))
                }

                // Chrome — Cancel / Done, a hint, and the color + font rows.
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.7))
                                // Full 44pt finger target — the bare text was
                                // easy to miss, which read as "didn't work".
                                .padding(.vertical, 12)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                        }
                        Spacer()
                        // Done steps OUT one level, not all the way home:
                        // from typing/styling it drops the keyboard into
                        // drag-&-pinch positioning (ending editing first so
                        // a pending autocorrect lands in the text); from
                        // positioning it saves & closes. EXCEPTION: with no
                        // text there's nothing to position — skip that mode
                        // and exit directly (committing the empty text,
                        // which is also how deleting a note's text deletes
                        // the note).
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if editing, !noteTextIsEmpty {
                                editing = false
                            } else if editing {
                                editing = false
                                DispatchQueue.main.async { commit() }
                            } else {
                                commit()
                            }
                        } label: {
                            Text("Done")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                        }
                    }
                    // Own the whole top strip so no underlying layer can
                    // compete for touches anywhere along the row.
                    .contentShape(Rectangle())
                    // Buttons carry their own hit-area padding (10h/12v) —
                    // trimmed here so labels sit at the same screen position.
                    .padding(.horizontal, LayoutMetrics.screenPadding - 10)
                    .padding(.vertical, LayoutMetrics.small - 12)

                    Spacer(minLength: 0)

                    // Font + color rows ONLY in edit mode (keyboard up). In
                    // positioning mode it's just the sticker — nothing else.
                    if editing {
                        // Absorb ALL taps in this block (incl. gaps between chips
                        // and surrounding padding) so a stray tap can't fall
                        // through to the tap-catcher and drop edit mode.
                        VStack(spacing: 0) {
                            colorRow
                                .padding(.bottom, 12)
                            fontChips
                                .padding(.bottom, 14)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { }   // absorb; nothing to re-assert
                    } else if !text.isEmpty {
                        Text("drag · pinch · rotate · tap to edit")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.bottom, 26)
                    }
                }
                .padding(.top, safeTop)
                .padding(.bottom, editing ? keyboardHeight : Self.windowSafeBottom)
                // Glide (don't snap) when the measured keyboard height lands
                // and when the chrome swaps between typing and positioning.
                .animation(.easeOut(duration: 0.22), value: keyboardHeight)
                .animation(.easeOut(duration: 0.22), value: editing)
            }
            // The screen-pinning: a fixed screen-sized canvas whose center is
            // re-anchored to the physical screen center every frame. When the
            // hosting view breathes with the keyboard, originG changes and the
            // .position compensates exactly — the editor never moves.
            .frame(width: screen.width, height: screen.height)
            .position(x: screen.width / 2 - originG.x,
                      y: screen.height / 2 - originG.y)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            // Stand down the app-wide tap-to-dismiss-keyboard recognizer —
            // it fires for chip taps and the entry touch (SwiftUI buttons
            // aren't UIControls, so its exemption misses them) and was THE
            // source of the keyboard bounce across every prior fix attempt.
            GlobalKeyboardDismiss.shared.isSuspended = true
            // Arm the tap-catcher after the opening touch has definitely lifted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scrimArmed = true }
        }
        .onDisappear {
            GlobalKeyboardDismiss.shared.isSuspended = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            if let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = max(keyboardHeight, frame.height)
            }
        }
    }

    @ViewBuilder
    private func noteElement(fitFrame f: CGRect) -> some View {
        Group {
            if editing {
                // Text mode. The input is a UIKit UITextView (NoteInputField):
                // setting .font/.textColor on an EXISTING UITextView never
                // resigns first responder — unlike SwiftUI's TextField, which
                // kept dropping the keyboard on every font/color chip tap no
                // matter which attributes were held constant (proven by the
                // ↓ counter climbing in Yael's recording). Focus is driven by
                // `editing` directly.
                ZStack {
                    if text.isEmpty {
                        // App-standard font on purpose — the placeholder is
                        // UI copy, not note content, so it doesn't follow
                        // the selected note style.
                        Text("Write about this fit…")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .allowsHitTesting(false)
                    }
                    // Invisible sizing mirror: the field is overlaid on a Text
                    // of the SAME string/font, so the input — and the
                    // highlighter pill behind it — hugs the typed content and
                    // resizes with every keystroke.
                    Text(text.isEmpty ? " " : text)
                        .font(style.font(size: 22))
                        .multilineTextAlignment(.center)
                        .opacity(0)
                        .overlay {
                            NoteInputField(
                                text: $text,
                                font: style.uiFont(size: 22),
                                textColor: style == .highlighter
                                    ? (DiaryInk.isDark(ink)
                                        ? .white
                                        : UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
                                    : UIColor(ink),
                                isFocused: editing)
                        }
                        .padding(.horizontal, style == .highlighter ? 10 : 0)
                        .padding(.vertical, style == .highlighter ? 5 : 0)
                        .background {
                            // Highlighter pill only once there's content —
                            // an empty box floating behind the cursor read
                            // as a glitch when previewing font styles.
                            if style == .highlighter, !text.isEmpty {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink)
                            }
                        }
                }
            } else {
                // Sticker mode — a plain rendered Text (no field), so drag /
                // pinch / rotate are perfectly smooth and never flicker.
                // `.drawingGroup()` rasterizes the text (+ any highlighter bg)
                // into ONE Metal texture, so as it's dragged/scaled/rotated the
                // GPU transforms a single flat layer each frame instead of
                // re-compositing the sub-layers — the one lever that can kill a
                // 120Hz-only shimmer a 60Hz screen recording can't show.
                if text.isEmpty {
                    // Placeholder is UI copy — app-standard font, never
                    // the selected note style (and no highlighter pill).
                    Text("Tap to write…")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .drawingGroup()
                } else {
                    DiaryNoteView(text: text,
                                  style: style, color: ink, size: 22, showShadow: false)
                        .drawingGroup()
                }
            }
        }
        .frame(maxWidth: max(120, f.width * 0.88))
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { g in
                Color.clear.preference(key: DiaryNoteSizeKey.self, value: g.size)
            }
        }
        // Only update the measured size when NOT mid-gesture, so a preference
        // change can't trigger a re-render (and flicker) during a drag.
        .onPreferenceChange(DiaryNoteSizeKey.self) { if !isGesturing { noteSize = $0 } }
        .scaleEffect(editing ? 1 : displayScale)
        .rotationEffect(editing ? .zero : rotation + liveRotate)
        // NO gestures here — in positioning mode the note is a passive sticker
        // and the full-screen manipulation layer owns every touch. Attaching
        // gestures to the note itself made the grab target a few dozen points
        // wide (and pinches needed BOTH fingers on it), which is what made
        // manipulation feel like it "only sometimes works".
    }

    /// Unified full-screen manipulation (IG-style). One gesture owns every
    /// touch in positioning mode:
    /// - drag from ANYWHERE moves the note (no aiming at the glyphs)
    /// - pinch/rotate from ANYWHERE scales/spins it (fingers needn't touch it)
    /// - tap is discriminated ON RELEASE: near the note → edit; elsewhere →
    ///   commit & close; never during a pinch
    /// Live values are plain @State written in .onChanged (re-renders can't
    /// reset them) and the DISPLAYED (live-clamped) value is what gets folded
    /// on release — so the note can never snap back when the finger lifts.
    private func manipulation(_ f: CGRect, allowed: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in liveDrag = value.translation }
            .onEnded { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if dist < 10 && !gestureDidTransform {
                    // A tap. Near the note → back to typing; elsewhere → done.
                    liveDrag = .zero
                    if isNearNote(value.location, in: f, allowed: allowed) {
                        withAnimation(.easeOut(duration: 0.22)) { editing = true }
                    } else if scrimArmed {
                        commit()
                    }
                } else {
                    // Fold the exact displayed (live-clamped) center into pos.
                    let end = livePlaced(f, allowed: allowed)
                    if f.width > 0, f.height > 0 {
                        pos = CGPoint(x: (end.x - f.minX) / f.width,
                                      y: (end.y - f.minY) / f.height)
                    }
                    liveDrag = .zero
                }
                gestureDidTransform = false
            }
            .simultaneously(with:
                MagnifyGesture()
                    .onChanged { value in
                        liveMagnify = value.magnification
                        if abs(value.magnification - 1) > 0.04 { gestureDidTransform = true }
                    }
                    .onEnded { _ in
                        // Fold the displayed (clamped) scale, then neutralize
                        // the live factor in the same tick — no visual change.
                        scale = displayScale
                        liveMagnify = 1.0
                    }
            )
            .simultaneously(with:
                RotateGesture()
                    .onChanged { value in
                        liveRotate = value.rotation
                        if abs(value.rotation.degrees) > 2 { gestureDidTransform = true }
                    }
                    .onEnded { value in
                        liveRotate = .zero
                        rotation += value.rotation
                    }
            )
    }

    private var colorRow: some View {
        HStack(spacing: 16) {
            ForEach(Array(DiaryInk.palette.enumerated()), id: \.offset) { i, c in
                Button { colorIndex = i } label: {
                    Circle()
                        .fill(c)
                        .frame(width: 24, height: 24)
                        // White hairline so dark swatches (black ink) stay
                        // visible against the editor's dim scrim.
                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: i == colorIndex ? 2 : 0).padding(-3))
                }
                .accessibilityLabel("Ink color \(i + 1)")
            }
        }
    }

    private var fontChips: some View {
        HStack(spacing: 10) {
            ForEach(DiaryNoteStyle.allCases) { s in
                Button {
                    // No withAnimation — animating the font swap churns the
                    // field's layout mid-focus; the chip highlight updates
                    // instantly and the text simply re-renders in the new face.
                    style = s
                } label: {
                    Text(s == .yafaMono ? "AA" : "Aa")
                        .font(s.font(size: 17))
                        .foregroundStyle(s == style ? .black : .white)
                        .frame(width: 46, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(s == style ? Color.white : Color.white.opacity(0.14))
                        }
                }
                .accessibilityLabel(s.accessibilityName)
                .accessibilityAddTraits(s == style ? .isSelected : [])
            }
        }
    }
}

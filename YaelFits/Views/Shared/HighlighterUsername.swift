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
        case .handwritten: return .custom("Noteworthy-Bold", size: size)
        case .typewriter:  return .custom("AmericanTypewriter", size: size)
        case .highlighter: return .system(size: size, weight: .semibold)
        case .yafaMono:    return .system(size: size, weight: .bold, design: .monospaced)
        case .clean:       return .system(size: size, weight: .medium)
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
    ]
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
            .foregroundStyle(style == .highlighter ? Color(red: 0.11, green: 0.12, blue: 0.15) : color)
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
struct DiaryNoteEditOverlay: View {
    let initialText: String
    let initialStyle: DiaryNoteStyle
    let initialX: Double
    let initialY: Double
    let initialScale: Double
    let initialRotation: Double
    let initialColorIndex: Int
    /// Global frame of the fit the note sits on — makes positioning WYSIWYG.
    let slideFrame: CGRect
    let onSave: (String, DiaryNoteStyle, Double, Double, Double, Double, Int) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var style: DiaryNoteStyle
    @State private var pos: CGPoint       // normalized 0..1 within slideFrame
    @State private var scale: CGFloat
    @State private var rotation: Angle
    @State private var colorIndex: Int
    // Live gesture values (auto-reset when the gesture ends). Committed into
    // pos/scale/rotation in .onEnded — same pattern as AvatarCropView.
    @GestureState private var gestureDrag: CGSize = .zero
    @GestureState private var gestureMagnify: CGFloat = 1.0
    @GestureState private var gestureRotate: Angle = .zero
    @State private var noteSize: CGSize = .zero
    // Baseline so the control rows start above the keyboard with no first-show
    // jump; only ever GROWS (never shrinks), so the layout never drifts down.
    @State private var keyboardHeight: CGFloat = 300
    /// Two clean modes (IG-style): text mode (keyboard up, editing) vs sticker
    /// mode (a plain Text you drag/pinch/rotate — no field, so it's smooth).
    @State private var editing = true
    @FocusState private var fieldFocus: Bool

    // Safe-zone insets (fractions of the fit frame) that keep the note off
    // the carousel UI: side arrows, top chrome, bottom action row. Tune if
    // the note still overlaps a control on-device.
    private let safeSideInset: CGFloat = 0.06
    private let safeTopInset: CGFloat = 0.07
    private let safeBottomInset: CGFloat = 0.06

    init(
        initialText: String,
        initialStyle: DiaryNoteStyle,
        initialX: Double,
        initialY: Double,
        initialScale: Double,
        initialRotation: Double,
        initialColorIndex: Int,
        slideFrame: CGRect,
        onSave: @escaping (String, DiaryNoteStyle, Double, Double, Double, Double, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialText = initialText
        self.initialStyle = initialStyle
        self.initialX = initialX
        self.initialY = initialY
        self.initialScale = initialScale
        self.initialRotation = initialRotation
        self.initialColorIndex = initialColorIndex
        self.slideFrame = slideFrame
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

    /// True while any manipulation gesture is live. Used to strip inherited
    /// animations off the note so it tracks the finger instead of easing.
    private var isGesturing: Bool {
        gestureDrag != .zero || gestureMagnify != 1.0 || gestureRotate != .zero
    }

    private func commit() {
        onSave(text, style, Double(pos.x), Double(pos.y), Double(scale), rotation.radians, colorIndex)
    }

    /// Clamps a normalized position so the note's (scaled) bounding box stays
    /// inside the safe zone — off the side arrows, top chrome, and bottom
    /// buttons. A note bigger than the safe zone snaps to center.
    private func clampedPos(_ raw: CGPoint, in f: CGRect) -> CGPoint {
        guard f.width > 0, f.height > 0 else { return raw }
        let halfWN = ((noteSize.width * scale) / 2) / f.width
        let halfHN = ((noteSize.height * scale) / 2) / f.height
        let minX = halfWN + safeSideInset, maxX = 1 - halfWN - safeSideInset
        let minY = halfHN + safeTopInset, maxY = 1 - halfHN - safeBottomInset
        let x = minX <= maxX ? min(maxX, max(minX, raw.x)) : 0.5
        let y = minY <= maxY ? min(maxY, max(minY, raw.y)) : 0.5
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            // The fit's global frame, expressed in this overlay's local space.
            let originG = geo.frame(in: .global).origin
            let f = CGRect(x: slideFrame.minX - originG.x,
                           y: slideFrame.minY - originG.y,
                           width: slideFrame.width, height: slideFrame.height)
            let placed = CGPoint(x: f.minX + pos.x * f.width,
                                 y: f.minY + pos.y * f.height)
            // Fixed upper-center — does NOT track the keyboard, so the note
            // stays put whether the keyboard is up or down (no drift).
            let typing = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.34)

            ZStack {
                // Dim. Tap while typing → sticker mode (drop keyboard); tap
                // while positioning → commit.
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editing { fieldFocus = false } else { commit() }
                    }

                // The note: text mode = centered field above the keyboard;
                // sticker mode = draggable/pinchable/rotatable Text. (Animation
                // is killed at the call site so it tracks the finger 1:1.)
                noteElement(fitFrame: f)
                    .position(editing ? typing : placed)
                    .offset(editing ? .zero : gestureDrag)

                // Chrome — Cancel / Done, a hint, and the color + font rows.
                VStack(spacing: 0) {
                    HStack {
                        Button("Cancel", action: onCancel)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button("Done") { fieldFocus = false; commit() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.vertical, LayoutMetrics.small)

                    Spacer(minLength: 0)

                    // Font + color rows ONLY in edit mode (keyboard up). In
                    // positioning mode it's just the sticker — nothing else.
                    if editing {
                        colorRow
                            .padding(.bottom, 12)
                        fontChips
                            .padding(.bottom, 14)
                    } else if !text.isEmpty {
                        Text("drag · pinch · rotate · tap to edit")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.bottom, 26)
                    }
                }
                .padding(.bottom, editing ? keyboardHeight : 0)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            if let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                // Grow to the real height, never shrink — the control rows stay
                // at a stable spot whether the keyboard is up or down.
                keyboardHeight = max(keyboardHeight, frame.height)
            }
        }
        .onChange(of: fieldFocus) { _, isFocused in
            // Keyboard dismissed (Done / swipe) → drop to sticker mode.
            if !isFocused { editing = false }
        }
    }

    @ViewBuilder
    private func noteElement(fitFrame f: CGRect) -> some View {
        Group {
            if editing {
                // Text mode — the field mounts HERE and focuses itself on
                // appear (reliable for every entry point, incl. long-press,
                // where the finger may still be down for a moment).
                ZStack {
                    if text.isEmpty {
                        Text("Write about this fit…")
                            .font(style.font(size: 22))
                            .foregroundStyle(.white.opacity(0.35))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .font(style.font(size: 22))
                        .tracking(style.tracking)
                        .foregroundStyle(style == .highlighter ? Color(red: 0.11, green: 0.12, blue: 0.15) : ink)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(style.isUppercased ? .characters : .sentences)
                        .focused($fieldFocus)
                        .padding(.horizontal, style == .highlighter ? 8 : 0)
                        .padding(.vertical, style == .highlighter ? 4 : 0)
                        .background {
                            if style == .highlighter {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ink)
                            }
                        }
                }
                .onAppear {
                    // Retry so a long-press finger has time to lift (iOS drops
                    // becomeFirstResponder while a touch is still down).
                    for d in [0.35, 0.7] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                            if editing && !fieldFocus { fieldFocus = true }
                        }
                    }
                }
            } else {
                // Sticker mode — a plain rendered Text (no field), so drag /
                // pinch / rotate are perfectly smooth and never flicker.
                DiaryNoteView(text: text.isEmpty ? "Tap to write…" : text,
                              style: style, color: ink, size: 22, showShadow: false)
                    .opacity(text.isEmpty ? 0.5 : 1)
            }
        }
        .frame(maxWidth: max(120, f.width * 0.88))
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { g in
                Color.clear.preference(key: DiaryNoteSizeKey.self, value: g.size)
            }
        }
        .onPreferenceChange(DiaryNoteSizeKey.self) { noteSize = $0 }
        .scaleEffect(editing ? 1 : scale * gestureMagnify)
        .rotationEffect(editing ? .zero : rotation + gestureRotate)
        .contentShape(Rectangle())
        .gesture(manipulation(f), including: editing ? .subviews : .all)
    }

    /// Combined drag + pinch + rotate. Uses @GestureState so the note follows
    /// the finger 1:1 with no accumulator jitter; commits (and clamps to the
    /// safe zone) only on release.
    private func manipulation(_ f: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureDrag) { value, state, _ in state = value.translation }
            .onEnded { value in
                // Near-zero movement = a tap → enter text mode (one gesture
                // handles both, so a drag can never accidentally toggle edit).
                if hypot(value.translation.width, value.translation.height) < 6 {
                    editing = true
                    return
                }
                guard f.width > 0 else { return }
                let raw = CGPoint(x: pos.x + value.translation.width / f.width,
                                  y: pos.y + value.translation.height / f.height)
                pos = clampedPos(raw, in: f)
            }
            .simultaneously(with:
                MagnifyGesture()
                    .updating($gestureMagnify) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        scale = min(3, max(0.4, scale * value.magnification))
                        pos = clampedPos(pos, in: f)
                    }
            )
            .simultaneously(with:
                RotateGesture()
                    .updating($gestureRotate) { value, state, _ in state = value.rotation }
                    .onEnded { value in rotation += value.rotation }
            )
    }

    private var colorRow: some View {
        HStack(spacing: 16) {
            ForEach(Array(DiaryInk.palette.enumerated()), id: \.offset) { i, c in
                Button { colorIndex = i } label: {
                    Circle()
                        .fill(c)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
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
                    withAnimation(.easeInOut(duration: 0.15)) { style = s }
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

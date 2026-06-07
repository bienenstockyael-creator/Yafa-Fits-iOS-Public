import SwiftUI
import UIKit

/// Username label that arcs along the bottom edge of a circular
/// avatar. Self-sizes its angular footprint to the text length,
/// with rounded end caps so it reads as a pill rather than a
/// clipped arc. Glyphs are rotated per-character so the text
/// follows the curve.
///
/// Originally lived in `EmptyFollowingHeroView` (used for the
/// "Find your people" avatar bubbles); promoted to a shared
/// component so the profile header's `curved` customization
/// style can reuse the exact same render path.
///
/// Parameters allow customization for the two known use sites:
///   * Empty-feed avatars: small (10pt) text, white pill, subtle
///     `cardBorder` stroke.
///   * Profile header curved style: bigger (14pt) text, accent-
///     color pill, no extra stroke.
///
/// Drawn entirely via a single `Canvas` pass so the render is
/// cached by SwiftUI — important because the empty-feed avatar
/// site applies a per-frame `FloatEffect` GeometryEffect that
/// would otherwise force a redraw on every animation tick.
struct CurvedUsernamePill: View {
    /// Exact text the caller wants curved. The view does NOT
    /// auto-prefix `@` — callers wanting an `@handle` pill
    /// must pass "@\(handle)" explicitly. This keeps the
    /// component reusable for both username and display-name
    /// renderings.
    let text: String
    let avatarRadius: CGFloat
    /// Render size of each glyph. Empty-feed avatars use 10pt;
    /// profile header curved style uses ~14pt.
    var fontSize: CGFloat = 10
    /// Radial thickness of the pill (its "height"). Scales with
    /// font size for readability — caller can override.
    var pillThickness: CGFloat = 22
    /// Pill background color. Defaults to white for the legacy
    /// avatar-bubble use site; the profile header style passes
    /// the user's chosen accent color.
    var fillColor: Color = .white
    /// Stroke color drawn slightly larger than `fillColor`,
    /// creating a thin outline. Set to `.clear` to disable.
    var strokeColor: Color = AppPalette.cardBorder
    /// Color used for the glyphs themselves.
    var textColor: Color = AppPalette.textPrimary
    /// Weight for the rendered glyphs. Defaults to medium; the
    /// accent-styled header pill uses semibold for more visual
    /// pop against the colored background.
    var fontWeight: Font.Weight = .medium

    private static let avatarGap: CGFloat = 4
    private static let endPadding: CGFloat = 6
    /// Negative tracking applied per glyph so the curved text
    /// reads tight rather than airy. Path-text effects in After
    /// Effects etc. typically dial in similar small negative
    /// tracking when the curve radius is small relative to glyph
    /// height.
    private static let perGlyphTighten: CGFloat = 0.85

    private var measuringFont: UIFont {
        let weight: UIFont.Weight
        switch fontWeight {
        case .semibold: weight = .semibold
        case .bold:     weight = .bold
        default:        weight = .medium
        }
        return .systemFont(ofSize: fontSize, weight: weight)
    }

    private let characters: [Character]
    private let displayText: String
    /// Per-glyph advance widths, cached at init so the per-frame
    /// redraw cost stays bounded.
    private let glyphAdvances: [CGFloat]
    private let measuredArcLength: CGFloat

    init(
        text: String,
        avatarRadius: CGFloat,
        fontSize: CGFloat = 10,
        pillThickness: CGFloat = 22,
        fillColor: Color = .white,
        strokeColor: Color = AppPalette.cardBorder,
        textColor: Color = AppPalette.textPrimary,
        fontWeight: Font.Weight = .medium
    ) {
        self.text = text
        self.avatarRadius = avatarRadius
        self.fontSize = fontSize
        self.pillThickness = pillThickness
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.textColor = textColor
        self.fontWeight = fontWeight

        let chars = Array(text)
        self.displayText = text
        self.characters = chars

        let measuringWeight: UIFont.Weight
        switch fontWeight {
        case .semibold: measuringWeight = .semibold
        case .bold:     measuringWeight = .bold
        default:        measuringWeight = .medium
        }
        let measuringFont = UIFont.systemFont(ofSize: fontSize, weight: measuringWeight)
        let attrs: [NSAttributedString.Key: Any] = [.font: measuringFont]
        let advances = chars.map { char -> CGFloat in
            let width = (String(char) as NSString).size(withAttributes: attrs).width
            return width * Self.perGlyphTighten
        }
        self.glyphAdvances = advances
        self.measuredArcLength = advances.reduce(0, +) + Self.endPadding * 2
    }

    private var pillInnerRadius: CGFloat { avatarRadius + Self.avatarGap }
    private var pillOuterRadius: CGFloat { pillInnerRadius + pillThickness }
    private var textRadius: CGFloat { (pillInnerRadius + pillOuterRadius) / 2 }

    private var totalAngle: CGFloat {
        // Clamp so a pathological username doesn't wrap past a
        // half-circle (which would visually collide with the
        // avatar's top).
        min(.pi, measuredArcLength / textRadius)
    }

    /// SwiftUI's Circle path starts at 3 o'clock and proceeds
    /// counterclockwise (math-CCW = screen-CW). 0.25 lands at
    /// 6 o'clock — directly below the avatar centre.
    private var trimAmount: CGFloat { totalAngle / (2 * .pi) }
    private var trimFrom: CGFloat { 0.25 - trimAmount / 2 }
    private var trimTo: CGFloat { 0.25 + trimAmount / 2 }

    // Pad enough room for the drop shadow drawn in
    // `drawPillBackground`. Shadow currently has a 6pt blur
    // radius and 3pt vertical offset, so ~12pt of breathing
    // room past `pillOuterRadius` keeps it from getting clipped
    // at the canvas edge.
    private var canvasSize: CGFloat { (pillOuterRadius + 12) * 2 }

    var body: some View {
        Canvas { context, _ in
            let center = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
            drawPillBackground(context: &context, center: center)
            drawGlyphs(context: &context, center: center)
        }
        .frame(width: canvasSize, height: canvasSize)
    }

    private func drawPillBackground(context: inout GraphicsContext, center: CGPoint) {
        let startAngle = Double(trimFrom) * 2 * .pi
        let endAngle = Double(trimTo) * 2 * .pi

        var path = Path()
        path.addArc(
            center: center,
            radius: textRadius,
            startAngle: .radians(startAngle),
            endAngle: .radians(endAngle),
            clockwise: false
        )

        // Stroke the pill inside a layer that has a soft drop
        // shadow. Drawing through a separate layer means the
        // shadow comes off the OUTLINE of the rendered pill,
        // not the underlying arc path — and it doesn't double
        // up when the stroke + fill are stacked. The glyphs are
        // drawn separately afterward so they stay shadow-free.
        context.drawLayer { layer in
            layer.addFilter(
                .shadow(
                    color: .black.opacity(0.18),
                    radius: 6,
                    x: 0,
                    y: 3
                )
            )
            layer.stroke(
                path,
                with: .color(strokeColor),
                style: StrokeStyle(
                    lineWidth: pillThickness + 1.5,
                    lineCap: .round
                )
            )
            layer.stroke(
                path,
                with: .color(fillColor),
                style: StrokeStyle(
                    lineWidth: pillThickness,
                    lineCap: .round
                )
            )
        }
    }

    private func drawGlyphs(context: inout GraphicsContext, center: CGPoint) {
        let totalAdvance = glyphAdvances.reduce(0, +)
        guard totalAdvance > 0 else { return }
        var runningAdvance: CGFloat = 0
        for (index, char) in characters.enumerated() {
            let advance = glyphAdvances[index]
            let centerAdvance = runningAdvance + advance / 2
            runningAdvance += advance

            let progress = centerAdvance / totalAdvance
            let t = trimTo - progress * (trimTo - trimFrom)
            let angle = Double(t) * 2 * .pi
            let rotation = angle - .pi / 2

            let position = CGPoint(
                x: center.x + textRadius * CGFloat(cos(angle)),
                y: center.y + textRadius * CGFloat(sin(angle))
            )

            let resolved = context.resolve(
                Text(String(char))
                    .font(.system(size: fontSize, weight: fontWeight))
                    .foregroundStyle(textColor)
            )

            context.drawLayer { layer in
                layer.translateBy(x: position.x, y: position.y)
                layer.rotate(by: .radians(rotation))
                layer.draw(resolved, at: .zero, anchor: .center)
            }
        }
    }
}

import SwiftUI

/// The three header layouts a user can pick to style their
/// profile page. Mirrors the `header_style` enum on
/// `profiles` (see `20260606100000_profile_header_style.sql`).
///
/// The string values are the canonical names used on the
/// server. The enum exists so call sites can switch
/// exhaustively without comparing raw strings.
enum ProfileHeaderStyle: String, Codable, CaseIterable, Sendable {
    case minimal
    case curved
    case bust

    /// Rendered name used in the customize-sheet carousel.
    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .curved:  return "Curved"
        case .bust:    return "Bust"
        }
    }

    /// Initializer that defaults to `.minimal` for unknown /
    /// legacy values, so a future server-side enum addition
    /// doesn't crash older clients.
    static func parse(_ raw: String?) -> ProfileHeaderStyle {
        guard let raw, let style = ProfileHeaderStyle(rawValue: raw) else {
            return .minimal
        }
        return style
    }
}

/// Predefined palette for the `curved` and `bust` accent colors.
/// Sampled directly from the Y2K magazine paste-up reference
/// (IMG_3728): bubblegum pink, highlighter chartreuse, cobalt
/// blue + a complementary coral. Stored on the profile as a
/// 6-digit hex string ("#RRGGBB"); the picker UI presents them
/// as colored dots beneath the carousel.
///
/// Keeping the palette small (4 colors) means every chosen
/// color reads as a deliberate brand-aligned choice rather than
/// a random hue from a wheel.
enum ProfileHeaderAccentColor {
    // Sampled from the magazine reference, then lifted ~15%
    // toward white so black text on top stays readable at
    // small sizes. The original saturated tones (e.g. cobalt
    // #2E8FFA) crushed contrast on the highlighter glyphs.
    static let palette: [String] = [
        "#F68CC1",  // bubblegum pink (lightened)
        "#DEE961",  // highlighter chartreuse (lightened)
        "#73B3FB",  // cobalt blue (lightened — biggest lift, was darkest)
        "#FF9F84",  // coral (lightened)
    ]

    /// Default color picked when a user first switches away from
    /// `minimal` and hasn't explicitly tapped a dot yet.
    static let defaultHex: String = palette[0]

    /// Resolves a stored hex string to a SwiftUI Color. Falls
    /// back to the default if the value is unrecognized — guards
    /// against stale palette entries from older app versions.
    static func color(for hex: String?) -> Color {
        let value = hex ?? defaultHex
        return Color(hex: value) ?? Color(hex: defaultHex) ?? .pink
    }

    /// Human-readable name for a palette hex — surfaced to
    /// VoiceOver as the color picker's per-dot label. Keep the
    /// keys in lockstep with `palette` above.
    static func accessibilityName(for hex: String) -> String {
        switch hex {
        case "#F68CC1": return "Pink"
        case "#DEE961": return "Yellow"
        case "#73B3FB": return "Blue"
        case "#FF9F84": return "Coral"
        default:        return "Custom color"
        }
    }
}

/// Single source of truth for profile-header sizing + visual
/// constants. Both `ProfileHeader` (owner) and `UserProfileSheet`
/// (viewer) render the same header layouts, so the magic numbers
/// live here instead of being copy-pasted into both. Change a
/// value here and both rendering paths stay in lockstep.
///
/// Naming convention: `live*` for the actual profile screen,
/// `preview*` for the customize-sheet carousel cards (which run
/// at a larger scale so each card reads as a hero preview).
enum ProfileHeaderMetrics {
    // MARK: Live header (ProfileHeader + UserProfileSheet)

    /// Unified avatar height for all three styles. Width matches
    /// for minimal + curved (circles); bust uses `liveBustFrameWidth`
    /// so the cutout has horizontal breathing room for hair /
    /// shoulders.
    static let liveAvatarSize: CGFloat = 132
    static let liveBustFrameWidth: CGFloat = 180
    /// Extra vertical room below the bust frame so the offset
    /// highlighter blob has overhang space without clipping.
    static let liveBustExtraHeight: CGFloat = 32
    /// Vertical position of the highlighter blob across the bust,
    /// as a fraction of `liveAvatarSize`. ~0.38 lands across the
    /// chest / torso area to match the Y2K magazine paste-up
    /// reference.
    static let bustHighlighterOffsetRatio: CGFloat = 0.38
    /// Frame padding around the curved-pill ZStack — needs to
    /// accommodate the pill arc that extends past the circle's
    /// bottom + sides.
    static let liveCurvedFramePadding: CGFloat = 90

    // MARK: Shared display constants

    /// Highlighter font size for the live header (preview uses
    /// a larger scale; see `previewHighlighterFontSize`).
    static let liveHighlighterFontSize: CGFloat = 18
    /// Tilt applied to the highlighter blob (degrees). Negative
    /// rotates counter-clockwise — top-right corner sits higher
    /// than the bottom-left for that hand-pasted feel.
    static let highlighterRotation: Double = -7

    /// Curved-pill font size for the live header.
    static let liveCurvedFontSize: CGFloat = 16
    /// Stroke thickness of the curved pill arc — wide enough to
    /// hold the font size above without crowding the glyphs.
    static let liveCurvedPillThickness: CGFloat = 30

    // MARK: Preview (customize-sheet carousel cards)

    /// Avatar diameter inside a preview card — 1.5x the live
    /// header so each card reads as a hero, not a thumbnail.
    static let previewAvatarDiameter: CGFloat = 180
    /// Bust frame width in the preview, scaled to keep the
    /// same width:height ratio (~1.36) used in the live header
    /// so cutouts render with the same horizontal breathing room.
    static let previewBustWidth: CGFloat = 245
    /// Extra vertical room below the bust frame in the preview
    /// card so the highlighter overhang has space + the bio
    /// row below doesn't overlap it.
    static let previewBustExtraHeight: CGFloat = 60

    static let previewHighlighterFontSize: CGFloat = 27
    static let previewCurvedFontSize: CGFloat = 21
    static let previewCurvedPillThickness: CGFloat = 39
    static let previewCurvedFramePadding: CGFloat = 90
}

extension Color {
    /// Convenience parser for our 6-digit hex strings ("#RRGGBB").
    /// Returns nil for unexpected formats so callers can fall back
    /// rather than crashing.
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8)  & 0xFF) / 255.0
        let b = Double(value         & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

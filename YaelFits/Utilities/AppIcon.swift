import SwiftUI

enum AppIconGlyph {
    case grid
    case calendar
    case plusCircle
    case globe
    case heart
    case comment
    case trash
    case bookmark
    case chevronLeft
    case chevronRight
    case xmark
    case camera
    case image
    case video
    case check
    case circleCheck
    case circleAlert
    case sun
    case cloud
    case wind
    case snowflake
    case thermometer
    case person
    case search
    case cart
    case share
    case bell
    case tshirt
    case sparkles
    case stack
}

struct AppIcon: View {
    let glyph: AppIconGlyph
    var size: CGFloat = 24
    var color: Color = AppPalette.iconPrimary
    var filled = false
    var strokeWidth: CGFloat = 2

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let lineWidth = min(rect.width, rect.height) * (strokeWidth / 24)
            let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            if filled, let fillPath = fillPath(in: rect) {
                context.fill(fillPath, with: .color(color))
            }

            for path in strokePaths(in: rect) {
                context.stroke(path, with: .color(color), style: strokeStyle)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Stroke paths

    private func strokePaths(in rect: CGRect) -> [Path] {
        switch glyph {
        case .grid:
            return [
                roundedRectPath(x: 3, y: 3, width: 18, height: 18, radius: 2, in: rect),
                linePath(from: (3, 9), to: (21, 9), in: rect),
                linePath(from: (3, 15), to: (21, 15), in: rect),
                linePath(from: (9, 3), to: (9, 21), in: rect),
                linePath(from: (15, 3), to: (15, 21), in: rect),
            ]
        case .calendar:
            return [
                linePath(from: (8, 2), to: (8, 6), in: rect),
                linePath(from: (16, 2), to: (16, 6), in: rect),
                roundedRectPath(x: 3, y: 4, width: 18, height: 18, radius: 2, in: rect),
                linePath(from: (3, 10), to: (21, 10), in: rect),
            ]
        case .plusCircle:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                linePath(from: (8, 12), to: (16, 12), in: rect),
                linePath(from: (12, 8), to: (12, 16), in: rect),
            ]
        case .globe:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                ellipsePath(x: 8, y: 2, width: 8, height: 20, in: rect),
                linePath(from: (2, 12), to: (22, 12), in: rect),
            ]
        case .heart:
            return [heartPath(in: rect)]
        case .comment:
            return [
                roundedRectPath(x: 4, y: 5, width: 16, height: 12, radius: 4, in: rect),
                polylinePath(points: [(10, 17), (8.5, 20), (13, 17)], in: rect),
            ]
        case .trash:
            return [
                roundedRectPath(x: 7, y: 8, width: 10, height: 12, radius: 2, in: rect),
                linePath(from: (5, 8), to: (19, 8), in: rect),
                linePath(from: (9.5, 5), to: (14.5, 5), in: rect),
                linePath(from: (10.5, 11), to: (10.5, 17), in: rect),
                linePath(from: (13.5, 11), to: (13.5, 17), in: rect),
                linePath(from: (8.5, 5), to: (7, 8), in: rect),
                linePath(from: (15.5, 5), to: (17, 8), in: rect),
            ]
        case .bookmark:
            return [bookmarkPath(in: rect)]
        case .chevronLeft:
            return [polylinePath(points: [(15, 18), (9, 12), (15, 6)], in: rect)]
        case .chevronRight:
            return [polylinePath(points: [(9, 18), (15, 12), (9, 6)], in: rect)]
        case .xmark:
            return [
                linePath(from: (18, 6), to: (6, 18), in: rect),
                linePath(from: (6, 6), to: (18, 18), in: rect),
            ]
        case .camera:
            return [
                roundedRectPath(x: 2, y: 7, width: 20, height: 13, radius: 2, in: rect),
                circlePath(cx: 12, cy: 13, r: 3, in: rect),
                polylinePath(points: [(8, 7), (9.4, 4.9), (14.6, 4.9), (16, 7)], in: rect),
            ]
        case .image:
            return [
                roundedRectPath(x: 3, y: 3, width: 18, height: 18, radius: 2, in: rect),
                circlePath(cx: 9, cy: 9, r: 2, in: rect),
                polylinePath(points: [(21, 15), (17.6, 11.6), (15.2, 14), (6, 21)], in: rect),
            ]
        case .video:
            return [
                roundedRectPath(x: 2, y: 6, width: 14, height: 12, radius: 2, in: rect),
                polygonPath(points: [(16, 10.5), (21.5, 7.5), (21.5, 16.5), (16, 13)], in: rect),
            ]
        case .check:
            return [polylinePath(points: [(20, 6), (9, 17), (4, 12)], in: rect)]
        case .circleCheck:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                polylinePath(points: [(17.5, 9), (10.7, 15.8), (6.5, 11.6)], in: rect),
            ]
        case .circleAlert:
            return [
                circlePath(cx: 12, cy: 12, r: 10, in: rect),
                linePath(from: (12, 8), to: (12, 12), in: rect),
                linePath(from: (12, 16.15), to: (12.01, 16.15), in: rect),
            ]
        case .sun:
            return [
                circlePath(cx: 12, cy: 12, r: 4, in: rect),
                linePath(from: (12, 2), to: (12, 4), in: rect),
                linePath(from: (12, 20), to: (12, 22), in: rect),
                linePath(from: (2, 12), to: (4, 12), in: rect),
                linePath(from: (20, 12), to: (22, 12), in: rect),
                linePath(from: (4.93, 4.93), to: (6.34, 6.34), in: rect),
                linePath(from: (17.66, 17.66), to: (19.07, 19.07), in: rect),
                linePath(from: (4.93, 19.07), to: (6.34, 17.66), in: rect),
                linePath(from: (17.66, 6.34), to: (19.07, 4.93), in: rect),
            ]
        case .cloud:
            return [cloudPath(in: rect)]
        case .wind:
            return [windTopPath(in: rect), windMiddlePath(in: rect), windBottomPath(in: rect)]
        case .snowflake:
            return [
                linePath(from: (12, 3), to: (12, 21), in: rect),
                linePath(from: (4.2, 7.2), to: (19.8, 16.8), in: rect),
                linePath(from: (19.8, 7.2), to: (4.2, 16.8), in: rect),
            ]
        case .thermometer:
            return [thermometerPath(in: rect)]
        case .person:
            return [
                circlePath(cx: 12, cy: 8, r: 4, in: rect),
                personBodyPath(in: rect),
            ]
        case .search:
            return [
                circlePath(cx: 11, cy: 11, r: 7, in: rect),
                linePath(from: (16, 16), to: (21, 21), in: rect),
            ]
        case .cart:
            return [
                circlePath(cx: 10, cy: 20.5, r: 1.2, in: rect),
                circlePath(cx: 18, cy: 20.5, r: 1.2, in: rect),
                polylinePath(points: [(2, 3), (5, 3), (7.5, 15), (19, 15)], in: rect),
                polylinePath(points: [(5.8, 6.5), (20, 6.5), (19, 12), (7, 12)], in: rect),
            ]
        case .share:
            return [
                polylinePath(points: [(8, 8), (12, 4), (16, 8)], in: rect),
                linePath(from: (12, 4), to: (12, 16), in: rect),
                polylinePath(points: [(5, 12), (5, 20), (19, 20), (19, 12)], in: rect),
            ]
        case .bell:
            var body = Path()
            body.addArc(center: point(12, 10, in: rect), radius: rect.width * (6.0 / 24), startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            let left = point(6, 10, in: rect)
            let right = point(18, 10, in: rect)
            let botLeft = point(5, 18, in: rect)
            let botRight = point(19, 18, in: rect)
            body.addLine(to: CGPoint(x: left.x, y: left.y))
            body.addLine(to: botLeft)
            body.move(to: CGPoint(x: right.x, y: right.y))
            body.addLine(to: botRight)
            let bar = linePath(from: (4, 18), to: (20, 18), in: rect)
            let clapper1 = Path(ellipseIn: scaledRect(x: 10, y: 19.5, width: 4, height: 3, in: rect))
            return [body, bar, clapper1]
        case .tshirt:
            return [tshirtPath(in: rect)]
        case .sparkles:
            return [
                sparklePath(cx: 12, cy: 12, size: 7, in: rect),
                sparklePath(cx: 19, cy: 5, size: 2.5, in: rect),
                sparklePath(cx: 5, cy: 18, size: 2, in: rect),
            ]
        case .stack:
            return [
                roundedRectPath(x: 3, y: 15, width: 18, height: 5, radius: 1.5, in: rect),
                roundedRectPath(x: 4.5, y: 9.5, width: 15, height: 5, radius: 1.5, in: rect),
                roundedRectPath(x: 6, y: 4, width: 12, height: 5, radius: 1.5, in: rect),
            ]
        }
    }

    private func fillPath(in rect: CGRect) -> Path? {
        switch glyph {
        case .heart: return heartPath(in: rect)
        case .bookmark: return bookmarkPath(in: rect)
        default: return nil
        }
    }

    // MARK: - Path helpers

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * (x / 24), y: rect.minY + rect.height * (y / 24))
    }

    private func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + rect.width * (x / 24), y: rect.minY + rect.height * (y / 24),
               width: rect.width * (width / 24), height: rect.height * (height / 24))
    }

    private func linePath(from s: (CGFloat, CGFloat), to e: (CGFloat, CGFloat), in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(s.0, s.1, in: r)); p.addLine(to: point(e.0, e.1, in: r)); return p
    }

    private func polylinePath(points: [(CGFloat, CGFloat)], in r: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: point(first.0, first.1, in: r))
        for next in points.dropFirst() { p.addLine(to: point(next.0, next.1, in: r)) }
        return p
    }

    private func polygonPath(points: [(CGFloat, CGFloat)], in r: CGRect) -> Path {
        var p = polylinePath(points: points, in: r); p.closeSubpath(); return p
    }

    private func roundedRectPath(x: CGFloat, y: CGFloat, width w: CGFloat, height h: CGFloat, radius: CGFloat, in r: CGRect) -> Path {
        let s = scaledRect(x: x, y: y, width: w, height: h, in: r)
        let sr = min(s.width, s.height) * (radius / min(w, h))
        return Path(roundedRect: s, cornerSize: CGSize(width: sr, height: sr), style: .continuous)
    }

    private func circlePath(cx: CGFloat, cy: CGFloat, r: CGFloat, in rect: CGRect) -> Path {
        Path(ellipseIn: scaledRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2, in: rect))
    }

    private func ellipsePath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in rect: CGRect) -> Path {
        Path(ellipseIn: scaledRect(x: x, y: y, width: width, height: height, in: rect))
    }

    // MARK: - Complex paths

    private func heartPath(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: point(12, 20.7, in: rect))
        p.addCurve(to: point(2.4, 9.7, in: rect), control1: point(6.4, 17.1, in: rect), control2: point(2.1, 14.3, in: rect))
        p.addCurve(to: point(7.8, 5.2, in: rect), control1: point(2.6, 6.6, in: rect), control2: point(5.4, 4.5, in: rect))
        p.addCurve(to: point(12, 7.2, in: rect), control1: point(9.4, 5.2, in: rect), control2: point(10.8, 6.1, in: rect))
        p.addCurve(to: point(16.2, 5.2, in: rect), control1: point(13.2, 6.1, in: rect), control2: point(14.6, 5.2, in: rect))
        p.addCurve(to: point(21.6, 9.7, in: rect), control1: point(18.6, 4.5, in: rect), control2: point(21.4, 6.6, in: rect))
        p.addCurve(to: point(12, 20.7, in: rect), control1: point(21.9, 14.3, in: rect), control2: point(17.6, 17.1, in: rect))
        p.closeSubpath()
        return p
    }

    private func bookmarkPath(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: point(7, 3, in: rect))
        p.addQuadCurve(to: point(5, 5, in: rect), control: point(5, 3, in: rect))
        p.addLine(to: point(5, 20, in: rect))
        p.addLine(to: point(12, 16.2, in: rect))
        p.addLine(to: point(19, 20, in: rect))
        p.addLine(to: point(19, 5, in: rect))
        p.addQuadCurve(to: point(17, 3, in: rect), control: point(19, 3, in: rect))
        p.closeSubpath()
        return p
    }

    private func cloudPath(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: point(17.5, 19, in: r))
        p.addCurve(to: point(9, 19, in: r), control1: point(14.8, 19, in: r), control2: point(11.8, 19, in: r))
        p.addCurve(to: point(4.4, 14.2, in: r), control1: point(6.2, 19, in: r), control2: point(4.4, 17.2, in: r))
        p.addCurve(to: point(9.2, 9, in: r), control1: point(4.4, 11.4, in: r), control2: point(6.6, 9, in: r))
        p.addCurve(to: point(15.7, 10, in: r), control1: point(11.7, 9, in: r), control2: point(13.9, 8.8, in: r))
        p.addCurve(to: point(17.5, 10, in: r), control1: point(16.3, 10, in: r), control2: point(16.9, 10, in: r))
        p.addCurve(to: point(20.6, 14.5, in: r), control1: point(19.8, 10, in: r), control2: point(20.9, 12, in: r))
        p.addCurve(to: point(17.5, 19, in: r), control1: point(20.6, 17.1, in: r), control2: point(19.4, 19, in: r))
        return p
    }

    private func windTopPath(in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(2, 8, in: r))
        p.addCurve(to: point(17.5, 8, in: r), control1: point(7, 8, in: r), control2: point(14, 8, in: r))
        p.addCurve(to: point(19.5, 10, in: r), control1: point(18.9, 8, in: r), control2: point(20, 8.8, in: r))
        p.addCurve(to: point(17.5, 12, in: r), control1: point(20, 11.2, in: r), control2: point(18.9, 12, in: r))
        return p
    }

    private func windMiddlePath(in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(2, 12, in: r))
        p.addCurve(to: point(20.5, 12, in: r), control1: point(7, 12, in: r), control2: point(16.8, 12, in: r))
        p.addCurve(to: point(22, 13.5, in: r), control1: point(21.3, 12, in: r), control2: point(22, 12.6, in: r))
        p.addCurve(to: point(20.5, 15, in: r), control1: point(22, 14.4, in: r), control2: point(21.3, 15, in: r))
        return p
    }

    private func windBottomPath(in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(2, 16, in: r))
        p.addCurve(to: point(12.8, 16, in: r), control1: point(5.5, 16, in: r), control2: point(10.4, 16, in: r))
        p.addCurve(to: point(14, 17.8, in: r), control1: point(13.6, 16, in: r), control2: point(14.2, 16.8, in: r))
        p.addCurve(to: point(12.8, 19.6, in: r), control1: point(14.2, 18.8, in: r), control2: point(13.6, 19.6, in: r))
        return p
    }

    private func thermometerPath(in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(12, 20, in: r))
        p.addCurve(to: point(8, 16, in: r), control1: point(9.8, 20, in: r), control2: point(8, 18.2, in: r))
        p.addCurve(to: point(10, 12.8, in: r), control1: point(8, 14.7, in: r), control2: point(8.8, 13.7, in: r))
        p.addLine(to: point(10, 4.2, in: r))
        p.addCurve(to: point(12, 2, in: r), control1: point(10, 3, in: r), control2: point(10.9, 2, in: r))
        p.addCurve(to: point(14, 4.2, in: r), control1: point(13.1, 2, in: r), control2: point(14, 3, in: r))
        p.addLine(to: point(14, 12.8, in: r))
        p.addCurve(to: point(16, 16, in: r), control1: point(15.2, 13.7, in: r), control2: point(16, 14.7, in: r))
        p.addCurve(to: point(12, 20, in: r), control1: point(16, 18.2, in: r), control2: point(14.2, 20, in: r))
        return p
    }

    private func personBodyPath(in r: CGRect) -> Path {
        var p = Path(); p.move(to: point(20, 21, in: r))
        p.addCurve(to: point(12, 14, in: r), control1: point(20, 17.1, in: r), control2: point(16.4, 14, in: r))
        p.addCurve(to: point(4, 21, in: r), control1: point(7.6, 14, in: r), control2: point(4, 17.1, in: r))
        return p
    }

    private func tshirtPath(in r: CGRect) -> Path {
        // Single closed outline traced clockwise from the left hem corner.
        // 24x24 viewbox; body is x∈[6,18], hem y=20, sleeves extend to
        // x=3 / x=21, neckline dips from (9,5) curving down to (15,5).
        var p = Path()
        p.move(to: point(6, 20, in: r))                                       // hem left
        p.addLine(to: point(6, 11, in: r))                                    // body left → sleeve junction
        p.addLine(to: point(3, 12, in: r))                                    // left sleeve cuff (outer-bottom)
        p.addLine(to: point(3, 7, in: r))                                     // left sleeve top (outer-top)
        p.addLine(to: point(8, 5, in: r))                                     // shoulder peak (left)
        p.addLine(to: point(9, 5, in: r))                                     // neckline left edge
        p.addQuadCurve(to: point(15, 5, in: r), control: point(12, 8, in: r)) // neckline curve
        p.addLine(to: point(16, 5, in: r))                                    // shoulder peak (right)
        p.addLine(to: point(21, 7, in: r))                                    // right sleeve top
        p.addLine(to: point(21, 12, in: r))                                   // right sleeve cuff
        p.addLine(to: point(18, 11, in: r))                                   // body right ← sleeve junction
        p.addLine(to: point(18, 20, in: r))                                   // body right → hem
        p.closeSubpath()
        return p
    }

    private func sparklePath(cx: CGFloat, cy: CGFloat, size: CGFloat, in r: CGRect) -> Path {
        // 4-point star with concave sides — the inset controls how
        // pinched the waist of each arm is.
        let inset = size * 0.3
        var p = Path()
        p.move(to: point(cx, cy - size, in: r))
        p.addLine(to: point(cx + inset, cy - inset, in: r))
        p.addLine(to: point(cx + size, cy, in: r))
        p.addLine(to: point(cx + inset, cy + inset, in: r))
        p.addLine(to: point(cx, cy + size, in: r))
        p.addLine(to: point(cx - inset, cy + inset, in: r))
        p.addLine(to: point(cx - size, cy, in: r))
        p.addLine(to: point(cx - inset, cy - inset, in: r))
        p.closeSubpath()
        return p
    }
}

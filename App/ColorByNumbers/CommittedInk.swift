import CBNKit
import PencilKit
import UIKit

/// One region's rings as an even-odd CGPath in TEMPLATE space — the
/// building block of `allowedInkMask` below.
private func templateSpaceCGPath(_ region: CBNRegion) -> CGPath {
    let path = CGMutablePath()
    for ring in [region.path] + region.holes where ring.count >= 3 {
        path.move(to: CGPoint(x: ring[0].x, y: ring[0].y))
        for point in ring.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.closeSubpath()
    }
    return path
}

/// EXACT geometry of "where crayon `colorNumber`'s ink may land," in
/// template space: fold the regions in painter's order — union each
/// matching one, subtract each non-matching one. Sequential union/subtract
/// in draw order is precisely visible-area semantics (a later region always
/// occludes an earlier one), with none of the parity pitfalls of a single
/// even-odd path.
func allowedInkMask(template: CBNTemplate, colorNumber: Int) -> CGPath {
    var allowed: CGPath = CGMutablePath()
    for region in template.regions where region.path.count >= 3 {
        let path = templateSpaceCGPath(region)
        allowed = region.colorNumber == colorNumber
            ? allowed.union(path, using: .evenOdd)
            : allowed.subtracting(path, using: .evenOdd)
    }
    return allowed
}

/// Renders an attempt's committed ink, honoring boundary-assist clipping.
///
/// Why a renderer of our own instead of one `PKDrawing.image(...)` call:
/// boundary-assist's promise is pixel-level — ink may not PAINT past the
/// outline — but the stored strokes only guarantee their CENTER line stays
/// inside (StrokeClipper), so half the ink width blooms over the edge when
/// rendered raw. PKStroke.mask looked purpose-built for this and simply
/// does not apply in `PKDrawing.image()` rendering (verified empirically:
/// pixel-identical output with and without masks — see the M3 bloom fix).
/// So the clip happens here, in plain CGContext, where the semantics are
/// certain.
///
/// Which strokes get clipped, and to which crayon's regions? The action
/// log: stroke gestures appear in it in the same order their sub-strokes
/// were appended to the drawing, so walking the log recovers each
/// gesture's stroke slice and its kind (`strokes` = freehand, paint as-is;
/// `clippedStrokes` = boundary, clip paint to the ink color's mask). The
/// ink color maps back to a palette number by nearest-match — palettes are
/// a handful of well-separated colors, so this is unambiguous even after
/// color-space round trips.
@MainActor
enum CommittedInkRenderer {
    /// The attempt's ink over a transparent background, sized
    /// `template.size × scale` points at `screenScale` — nil when there is
    /// nothing to draw. Drawings and masks are all in template space, so
    /// callers only choose an output scale; registration is inherent.
    static func image(
        drawing: PKDrawing,
        actionLog: [CBNAttemptAction],
        template: CBNTemplate,
        scale: CGFloat,
        screenScale: CGFloat = 1
    ) -> UIImage? {
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return nil }

        let templateRect = CGRect(x: 0, y: 0, width: template.size.width, height: template.size.height)
        let size = CGSize(width: templateRect.width * scale, height: templateRect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        format.opaque = false

        var cursor = 0
        var maskCache: [Int: CGPath] = [:]

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for entry in actionLog {
                guard let count = entry.substrokeCount else { continue }
                guard cursor < strokes.count else { break }
                let slice = Array(strokes[cursor ..< min(cursor + count, strokes.count)])
                cursor += count

                let gestureImage = PKDrawing(strokes: slice).image(from: templateRect, scale: scale)

                guard case .clippedStrokes = entry,
                      let number = paletteNumber(closestTo: slice.first?.ink.color, in: template)
                else {
                    gestureImage.draw(in: CGRect(origin: .zero, size: size))
                    continue
                }

                let mask = maskCache[number] ?? {
                    var transform = CGAffineTransform(scaleX: scale, y: scale)
                    let scaled = allowedInkMask(template: template, colorNumber: number)
                        .copy(using: &transform) ?? CGMutablePath()
                    maskCache[number] = scaled
                    return scaled
                }()

                let cg = context.cgContext
                cg.saveGState()
                cg.addPath(mask)
                cg.clip(using: .evenOdd)
                gestureImage.draw(in: CGRect(origin: .zero, size: size))
                cg.restoreGState()
            }
        }
    }

    /// Nearest palette entry to a stroke's ink color, by RGB distance.
    private static func paletteNumber(closestTo color: UIColor?, in template: CBNTemplate) -> Int? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        var best: (number: Int, distance: Double)?
        for entry in template.palette {
            guard let rgb = entry.rgb else { continue }
            let distance = pow(rgb.red - Double(r), 2)
                + pow(rgb.green - Double(g), 2)
                + pow(rgb.blue - Double(b), 2)
            if best == nil || distance < best!.distance {
                best = (entry.number, distance)
            }
        }
        return best?.number
    }
}

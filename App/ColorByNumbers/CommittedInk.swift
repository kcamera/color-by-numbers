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

/// The VISIBLE area of ONE region, in template space: its own path, minus
/// every region painted AFTER it (painter's order = `template.regions`
/// order). Same CGPath boolean technique as `allowedInkMask` just above —
/// sequential subtract in draw order is exact occlusion — but seeded from a
/// single region instead of every same-colored one. What lets
/// `CommittedInkRenderer` repaint a LATE fill (one that happened after a
/// scribble already covered it) without bleeding into a differently-shaped
/// region stacked on top (the M3 crayon-layering fix — see its doc comment
/// on `image(...)`).
private func visibleRegionAreaMask(regionIndex: Int, template: CBNTemplate) -> CGPath {
    let regions = template.regions
    guard regionIndex < regions.count, regions[regionIndex].path.count >= 3 else {
        return CGMutablePath()
    }
    var visible = templateSpaceCGPath(regions[regionIndex])
    for region in regions[(regionIndex + 1)...] where region.path.count >= 3 {
        visible = visible.subtracting(templateSpaceCGPath(region), using: .evenOdd)
    }
    return visible
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
///
/// Fills, not just strokes, sometimes get REPAINTED here too — the M3
/// crayon-layering fix. Real crayons stack by TIME: a region tap-filled
/// after a scribble already crossed it should paint OVER that scribble, not
/// under it (the base fills layer in `CanvasView.draw` is bottom-most,
/// always, so it alone can't show that). The action log has exact
/// chronology, so `image(...)` walks it and repaints any fill that happened
/// after ink already existed, clipped to that region's own visible area so
/// a late fill still can't bleed into a shape stacked on top of it.
@MainActor
enum CommittedInkRenderer {
    /// The warm dark outline gray used everywhere ink needs an edge —
    /// `TemplateRenderer.outlineGray`'s literal value, mirrored here the
    /// same way `CanvasView.draw` mirrors it (that type is `internal` to
    /// CBNKit and not visible from the app target). `srgbRed` explicitly,
    /// not the plain `CGColor(red:green:blue:)` initializer — the latter is
    /// device generic RGB, not sRGB, and renders visibly washed out next to
    /// every other color in this app (all produced via `UIColor`/SwiftUI
    /// `Color`, both sRGB); `TemplateRenderer.swift` in CBNKit already
    /// establishes `srgbRed` as this codebase's convention for raw CGColor.
    private static let outlineColor = CGColor(srgbRed: 0.35, green: 0.33, blue: 0.31, alpha: 1)

    /// The attempt's ink over a transparent background, sized
    /// `template.size × scale` points at `screenScale` — nil when there is
    /// nothing to draw. Drawings and masks are all in template space, so
    /// callers only choose an output scale; registration is inherent.
    /// `filledRegionIDs` is the attempt's ORDERED fill list — its count
    /// always equals the log's `.fill` entry count, in the same order
    /// (invariant documented on `CBNAttempt.effectiveActionLog`) — which is
    /// what lets this walk recover each `.fill` entry's region without
    /// storing anything extra in the log itself.
    static func image(
        drawing: PKDrawing,
        actionLog: [CBNAttemptAction],
        filledRegionIDs: [String],
        template: CBNTemplate,
        scale: CGFloat,
        screenScale: CGFloat = 1
    ) -> UIImage? {
        let strokes = drawing.strokes
        // No strokes means no ink ever existed to be painted under, so no
        // fill in the log could possibly need a chronological repaint — the
        // base fills layer alone is already correct, same early-out as
        // before this fix.
        guard !strokes.isEmpty else { return nil }

        let templateRect = CGRect(x: 0, y: 0, width: template.size.width, height: template.size.height)
        let size = CGSize(width: templateRect.width * scale, height: templateRect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        format.opaque = false

        let regionIndexByID = Dictionary(
            uniqueKeysWithValues: template.regions.enumerated().map { ($1.id, $0) }
        )

        var cursor = 0
        var fillIndex = 0
        // How many stroke gestures have been walked so far — a fill with
        // none yet before it can only be sitting on bare paper (the base
        // layer already painted it identically), so it's skipped rather
        // than needlessly redrawn.
        var strokesSeen = 0
        var maskCache: [Int: CGPath] = [:]
        var visibleAreaCache: [Int: CGPath] = [:]

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext

            for entry in actionLog {
                if case .fill = entry {
                    let index = fillIndex
                    fillIndex += 1
                    guard strokesSeen > 0, index < filledRegionIDs.count,
                          let regionIndex = regionIndexByID[filledRegionIDs[index]]
                    else { continue }
                    let region = template.regions[regionIndex]
                    guard region.path.count >= 3,
                          let rgb = template.palette.first(where: { $0.number == region.colorNumber })?.rgb
                    else { continue }

                    var pathTransform = CGAffineTransform(scaleX: scale, y: scale)
                    let scaledRegionPath = templateSpaceCGPath(region).copy(using: &pathTransform)
                        ?? CGMutablePath()
                    let visibleArea = visibleAreaCache[regionIndex] ?? {
                        var transform = CGAffineTransform(scaleX: scale, y: scale)
                        let scaled = visibleRegionAreaMask(regionIndex: regionIndex, template: template)
                            .copy(using: &transform) ?? CGMutablePath()
                        visibleAreaCache[regionIndex] = scaled
                        return scaled
                    }()

                    // Clip to the region's VISIBLE area (nothing painted
                    // here can bleed into a shape stacked on top of it),
                    // then fill the region's own path so its holes still
                    // read as holes.
                    cg.saveGState()
                    cg.addPath(visibleArea)
                    cg.clip(using: .evenOdd)
                    cg.addPath(scaledRegionPath)
                    cg.setFillColor(CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
                    cg.fillPath(using: .evenOdd)
                    cg.restoreGState()

                    // Re-stroke the region's own outline on top, unclipped
                    // — same draw order as the base layer's per-region
                    // fill-then-stroke (`CanvasView.draw`), so this fill
                    // doesn't bury its own printed edge under the color it
                    // just repainted.
                    cg.saveGState()
                    cg.addPath(scaledRegionPath)
                    cg.setStrokeColor(outlineColor)
                    cg.setLineWidth(1.2)
                    cg.setLineJoin(.round)
                    cg.strokePath()
                    cg.restoreGState()
                    continue
                }

                guard let count = entry.substrokeCount else { continue }
                guard cursor < strokes.count else { break }
                let slice = Array(strokes[cursor ..< min(cursor + count, strokes.count)])
                cursor += count
                strokesSeen += 1

                // Pin light traits: PKDrawing.image resolves each ink's
                // light/dark color pair against the CURRENT traits, and
                // this renderer can run under unspecified ones — same
                // trait-pinning rationale as DrawingCanvas.makeTool.
                var gestureImage = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    gestureImage = PKDrawing(strokes: slice).image(from: templateRect, scale: scale)
                }

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

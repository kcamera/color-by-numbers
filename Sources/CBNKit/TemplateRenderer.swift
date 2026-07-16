import CoreGraphics
import CoreText
import Foundation

/// Renders CBNTemplates to bitmaps. One renderer, several faces of the same
/// document: the filled preview, the printable outline page, and (M5) the
/// legend and piece sheets.
public enum TemplateRenderer {
    public enum Mode: String, CaseIterable, Sendable {
        /// Every region filled with its palette color — "the finished art".
        case filled
        /// White page, region outlines, a number in each region — what the
        /// child colors, and the printable template.
        case outline
        /// Fills plus outlines, for judging boundary quality in tuning.
        case composite
    }

    /// Ink and paper tones per docs/DESIGN.md's soft-analog direction:
    /// warm dark gray lines on white, never harsh pure black.
    static let outlineGray: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.35, 0.33, 0.31)

    /// - Parameter filledRegionIDs: When nil (the default), every call site
    ///   renders exactly as before — the finished-art face, the printable
    ///   outline page, and the tuning composite. When non-nil, it restricts
    ///   which regions get their palette-color fill, baking one MORE face of
    ///   the same document: an in-progress attempt. This is deliberately not
    ///   a separate renderer — the Studio thumbnail (DESIGN.md: it must show
    ///   honest autosaved progress, not a pristine outline) is just the
    ///   interactive canvas's own appearance (CanvasView.draw), rasterized.
    ///   In `.outline` mode, a filled region gets its color painted before
    ///   the stroke pass (so the ring outline still shows on top) and its
    ///   number suppressed; an unfilled region is untouched — white, stroked,
    ///   numbered, exactly as it already renders with the set omitted. In
    ///   `.filled`/`.composite`, only regions in the set get colored and the
    ///   rest stay white; everything else about those modes is unchanged.
    public static func render(
        _ template: CBNTemplate,
        mode: Mode,
        scale: Double = 1.0,
        filledRegionIDs: Set<String>? = nil
    ) -> CGImage? {
        let width = Int((template.size.width * scale).rounded())
        let height = Int((template.size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Template coordinates are y-down; CGContext bitmaps are y-up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: template.size.width, height: template.size.height))

        let colorsByNumber = Dictionary(
            uniqueKeysWithValues: template.palette.map { ($0.number, $0.rgb) }
        )

        // Regions are stored in painter's order — draw front to back as-is.
        for region in template.regions {
            guard region.path.count >= 3 else { continue }
            // One CGPath per region: outer ring plus hole rings as
            // subpaths, filled even-odd so holes stay unpainted.
            let path = CGMutablePath()
            for ring in [region.path] + region.holes where ring.count >= 3 {
                path.move(to: CGPoint(x: ring[0].x, y: ring[0].y))
                for point in ring.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                path.closeSubpath()
            }

            // Nil filledRegionIDs reproduces the per-mode legacy behavior
            // exactly (outline never fills; filled/composite fill every
            // region). A non-nil set means "the in-progress face": EVERY
            // region paints — its palette color if the child filled it,
            // opaque WHITE if not. The white is load-bearing, not cosmetic:
            // painter's order stacks regions (a sail draws over the sky it
            // sits in), so skipping the fill on an unfilled region would
            // let a filled container bleed through it. The interactive
            // canvas paints unfilled regions white for the same reason;
            // the two renderings must agree pixel-for-pixel.
            var fillColor: CGColor? = nil
            if let filledRegionIDs {
                if filledRegionIDs.contains(region.id) {
                    let rgb = colorsByNumber[region.colorNumber].flatMap { $0 }
                    fillColor = CGColor(
                        srgbRed: CGFloat(rgb?.red ?? 0.5),
                        green: CGFloat(rgb?.green ?? 0.5),
                        blue: CGFloat(rgb?.blue ?? 0.5),
                        alpha: 1
                    )
                } else {
                    fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                }
            } else if mode != .outline {
                let rgb = colorsByNumber[region.colorNumber].flatMap { $0 }
                fillColor = CGColor(
                    srgbRed: CGFloat(rgb?.red ?? 0.5),
                    green: CGFloat(rgb?.green ?? 0.5),
                    blue: CGFloat(rgb?.blue ?? 0.5),
                    alpha: 1
                )
            }

            if let fillColor {
                context.setFillColor(fillColor)
                context.addPath(path)
                context.fillPath(using: .evenOdd)
            }
            if mode != .filled {
                context.setStrokeColor(
                    CGColor(srgbRed: outlineGray.r, green: outlineGray.g, blue: outlineGray.b, alpha: 1)
                )
                context.setLineWidth(1.5 / scale)
                context.setLineJoin(.round)
                context.addPath(path)
                context.strokePath()
            }
        }

        if mode == .outline {
            for region in template.regions where region.path.count >= 3 {
                // A filled region's number is already meaningless — the
                // child colored it, there's nothing left to look up — so
                // the in-progress face omits it, matching the interactive
                // canvas (CanvasView.draw only labels unfilled regions).
                if let filledRegionIDs, filledRegionIDs.contains(region.id) { continue }
                // Net area — outer ring minus holes — so a thin outline
                // mesh sizes its number by its actual ink, not by the
                // whole drawing its outer ring happens to enclose.
                let netArea = max(
                    abs(PolygonGeometry.signedArea(of: region.path))
                        - region.holes.reduce(0) { $0 + abs(PolygonGeometry.signedArea(of: $1)) },
                    1
                )
                drawNumber(
                    region.colorNumber,
                    at: region.labelPoint,
                    regionArea: netArea,
                    in: context
                )
            }
        }

        return context.makeImage()
    }

    /// Number sizing: proportional to the region's rough diameter, clamped
    /// so tiny regions stay legible and huge regions don't shout.
    private static func drawNumber(
        _ number: Int,
        at point: CBNPoint,
        regionArea: Double,
        in context: CGContext
    ) {
        let diameter = regionArea.squareRoot()
        let fontSize = min(max(diameter * 0.22, 9), 40)

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(
                srgbRed: outlineGray.r, green: outlineGray.g, blue: outlineGray.b, alpha: 1
            ),
        ]
        let attributed = CFAttributedStringCreate(
            nil, "\(number)" as CFString, attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        context.saveGState()
        // Text draws y-up; flip locally around the label point.
        context.translateBy(x: CGFloat(point.x), y: CGFloat(point.y))
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(
            x: -bounds.width / 2,
            y: -bounds.midY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

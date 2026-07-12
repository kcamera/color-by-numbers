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

    public static func render(
        _ template: CBNTemplate,
        mode: Mode,
        scale: Double = 1.0
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
            let path = CGMutablePath()
            path.move(to: CGPoint(x: region.path[0].x, y: region.path[0].y))
            for point in region.path.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()

            if mode != .outline {
                let rgb = colorsByNumber[region.colorNumber].flatMap { $0 }
                context.setFillColor(
                    CGColor(
                        srgbRed: CGFloat(rgb?.red ?? 0.5),
                        green: CGFloat(rgb?.green ?? 0.5),
                        blue: CGFloat(rgb?.blue ?? 0.5),
                        alpha: 1
                    )
                )
                context.addPath(path)
                context.fillPath()
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
                drawNumber(
                    region.colorNumber,
                    at: region.labelPoint,
                    regionArea: abs(PolygonGeometry.signedArea(of: region.path)),
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

import CBNKit
import PencilKit
import UIKit

/// Answers "which regions ARE colored?" from the only honest source: the
/// rendered pixels.
///
/// The model deliberately has no answer (CBNAttempt's doc: it records
/// paint, never judgments). Stroke-to-region attribution can't be made
/// trustworthy — a freehand scribble crosses five regions and respects
/// nothing — but the QUESTION was never "which gesture filled what"; it's
/// "does this region visibly have ink on it," and that is directly
/// measurable: render the attempt's composite paint (tap fills + stroke
/// gestures, through the same `CommittedInkRenderer` every screen already
/// trusts) at a coarse scale, and count each region's inked pixels against
/// its VISIBLE area. Truth and perception become the same thing by
/// construction — what the child sees colored is what the app calls
/// colored, regardless of which tool laid the paint down.
///
/// Visibility comes from one INDEX raster — every region's index painted
/// in painter's order, antialiasing off — rather than per-region vector
/// masks: one O(pixels) pass instead of O(regions²) CGPath booleans, which
/// matters because this recomputes after every gesture and imported
/// templates carry hundreds of regions. The vector mask survives only as
/// the fallback for regions too small to win a single pixel at this scale.
///
/// Coverage is derived state, recomputed from the raster whenever the
/// attempt changes — never persisted, so it can never go stale or disagree
/// with the drawing it describes.
@MainActor
enum InkCoverage {
    /// Fraction of a region's visible pixels that must carry ink before it
    /// counts as colored. Forgiving on purpose: the child rarely inks the
    /// last sliver against a boundary line, and the failure mode is gentle
    /// in both directions (a hint number appears or doesn't — no reward,
    /// no judgment, nothing lost). `[design-sensitive]` — tune on real
    /// artwork, not in theory.
    nonisolated static let threshold: Double = 0.85

    /// Ink alpha above this counts as "a painted pixel" (out of 255).
    /// Low on purpose: the crayon is opaque monoline (DrawingFeel), so
    /// anything meaningfully above antialiasing fringe is real paint.
    nonisolated static let inkAlphaFloor: UInt8 = 25

    /// The measurement raster's longest side, in pixels. Coverage is a
    /// ratio, not a picture — 256px distinguishes "obviously colored" from
    /// "obviously not" at a fraction of the display renderer's cost, and
    /// the sub-pixel fallback below catches whatever is too small to
    /// measure at this scale.
    nonisolated static let maxRasterDimension: CGFloat = 256

    /// The set of region ids currently covered by paint. Tap-filled
    /// regions are covered by construction — a tap fill paints the
    /// region's entire visible area flat, so measuring it would only
    /// re-derive 100%. Everything else is measured against the composite
    /// ink raster. A region with no visible pixels at measurement scale is
    /// either genuinely occluded (fully painted over by later regions —
    /// counts as covered: the child can never see or touch it, so it must
    /// never hold the Done badge hostage or flash a hint number) or merely
    /// sub-pixel small — decided by the vector mask, with a tiny-but-real
    /// region falling back to a single honest ink sample at its label
    /// point.
    static func coveredRegionIDs(
        template: CBNTemplate,
        attempt: CBNAttempt,
        drawing: PKDrawing
    ) -> Set<String> {
        var covered = Set(attempt.tapFillRegionIDs)

        let regions = template.regions
        guard regions.contains(where: { !covered.contains($0.id) }) else { return covered }

        let maxSide = max(template.size.width, template.size.height)
        let scale = min(1, maxRasterDimension / max(maxSide, 1))
        let width = max(Int((template.size.width * scale).rounded()), 1)
        let height = max(Int((template.size.height * scale).rounded()), 1)

        // No strokes yet renders no image (CommittedInkRenderer's early
        // out); an all-transparent raster keeps everything on one code path.
        let ink = AlphaBitmap(
            image: CommittedInkRenderer.image(
                drawing: drawing,
                actionLog: attempt.actionLog,
                tapFillRegionIDs: attempt.tapFillRegionIDs,
                template: template,
                scale: scale,
                screenScale: 1
            )?.cgImage,
            width: width,
            height: height
        )

        // One joint pass over the index raster and the ink raster: how many
        // pixels each region visibly owns, and how many of those carry ink.
        var visibleCount = [Int](repeating: 0, count: regions.count)
        var inkedCount = [Int](repeating: 0, count: regions.count)
        let indexes = regionIndexRaster(template: template, width: width, height: height, scale: scale)
        for pixel in 0 ..< (width * height) {
            let index = indexes[pixel]
            guard index != UInt32.max else { continue }
            visibleCount[Int(index)] += 1
            if ink.pixels[pixel] > inkAlphaFloor {
                inkedCount[Int(index)] += 1
            }
        }

        for (index, region) in regions.enumerated() where !covered.contains(region.id) {
            if visibleCount[index] > 0 {
                if Double(inkedCount[index]) / Double(visibleCount[index]) >= threshold {
                    covered.insert(region.id)
                }
            } else if visibleRegionAreaMask(regionIndex: index, template: template).isEmpty
                || region.path.count < 3 {
                // Genuinely invisible — occluded by later regions (or
                // degenerate geometry). Covered by definition.
                covered.insert(region.id)
            } else {
                // Real but sub-pixel at measurement scale: one honest
                // sample where its number sits.
                let x = min(max(Int(region.labelPoint.x * scale), 0), width - 1)
                let y = min(max(Int(region.labelPoint.y * scale), 0), height - 1)
                if ink.pixels[y * width + x] > inkAlphaFloor {
                    covered.insert(region.id)
                }
            }
        }
        return covered
    }

    /// The topmost region index at every pixel (`UInt32.max` = bare
    /// paper), by painting each region's index as a flat color in
    /// painter's order with antialiasing OFF — the raster twin of the
    /// renderer's sequential-occlusion masks, produced in one pass.
    /// Region indexes are encoded as `index + 1` across the R (low byte)
    /// and G (high byte) channels, so up to 65535 regions survive the
    /// round trip exactly; antialiasing must stay off or blended edge
    /// pixels would decode as unrelated indexes.
    private static func regionIndexRaster(
        template: CBNTemplate,
        width: Int,
        height: Int,
        scale: CGFloat
    ) -> [UInt32] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setAllowsAntialiasing(false)
            context.setShouldAntialias(false)
            // Template coordinates are y-down; CGContext bitmaps are y-up —
            // the same flip TemplateRenderer applies.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)

            for (index, region) in template.regions.enumerated() where region.path.count >= 3 {
                let encoded = index + 1
                context.setFillColor(CGColor(
                    srgbRed: CGFloat(encoded & 0xFF) / 255,
                    green: CGFloat((encoded >> 8) & 0xFF) / 255,
                    blue: 0,
                    alpha: 1
                ))
                context.addPath(templateSpaceCGPath(region))
                context.fillPath(using: .evenOdd)
            }
        }

        var indexes = [UInt32](repeating: .max, count: width * height)
        for pixel in 0 ..< (width * height) {
            let base = pixel * 4
            guard rgba[base + 3] != 0 else { continue }
            let encoded = Int(rgba[base]) | (Int(rgba[base + 1]) << 8)
            if encoded > 0 {
                indexes[pixel] = UInt32(encoded - 1)
            }
        }
        return indexes
    }
}

/// An 8-bit alpha-only snapshot of a rendered image — "is there paint at
/// this pixel" is the only question coverage ever asks of the ink.
private struct AlphaBitmap {
    let width: Int
    let height: Int
    /// Row-major, row 0 = top scanline (UIKit image convention preserved
    /// by drawing the source image over the full context bounds).
    let pixels: [UInt8]

    init(image: CGImage?, width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        var data = [UInt8](repeating: 0, count: self.width * self.height)
        if let image {
            let w = self.width
            let h = self.height
            data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
                ) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        pixels = data
    }
}

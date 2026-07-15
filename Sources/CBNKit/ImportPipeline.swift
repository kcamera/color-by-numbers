import Foundation

/// The flat-art import pipeline: RasterImage in, CBNTemplate out.
///
/// Stages: quantize (Lab-space, flat-art aware) → connected components →
/// small-region merge → boundary trace → simplify → label placement.
/// Each stage is a pure function in its own file; this type only sequences
/// them and owns the parameter-to-stage mapping.
public enum ImportPipeline {
    /// How `ImportParameters.detail` (0…1, higher = more faithful) becomes
    /// a simplification tolerance in pixels. Constants isolated here for
    /// tuning via `cbnc tune`.
    ///
    /// DORMANT — `detail` defaults to 1.0 everywhere and is scheduled for
    /// removal (see its doc in ImportParameters). When it goes, this
    /// becomes a fixed *physical* tolerance (~0.2mm at display size, via
    /// `referenceLongEdgeMM`) so simplification hygiene scales with source
    /// resolution instead of being a raw pixel constant.
    static func simplifyTolerance(detail: Double) -> Double {
        let clamped = min(max(detail, 0), 1)
        // detail 1 → 0.75px (faithful), detail 0 → 5px (calm and chunky).
        return 5.0 - clamped * 4.25
    }

    /// The physical size a template's long edge is assumed to display or
    /// print at, anchoring `ImportParameters.minRegionMM` to real
    /// millimeters. 240mm ≈ an iPad's landscape screen width, and close to
    /// the printable width of a letter/A4 page in landscape.
    public static let referenceLongEdgeMM = 240.0

    /// Converts a `minRegionMM` dot diameter into a pixel-area threshold
    /// for a given source image: the area of a circle of that diameter at
    /// the scale where the image's long edge spans `referenceLongEdgeMM`.
    public static func minRegionPixelArea(mm: Double, imageWidth: Int, imageHeight: Int) -> Int {
        let pixelsPerMM = Double(max(imageWidth, imageHeight)) / referenceLongEdgeMM
        let diameterPixels = mm * pixelsPerMM
        return max(1, Int((Double.pi / 4 * diameterPixels * diameterPixels).rounded()))
    }

    public static func importTemplate(
        from image: RasterImage,
        title: String,
        parameters: ImportParameters
    ) -> CBNTemplate {
        let quantized = Quantizer.quantize(image, maxColors: parameters.colorCount)

        let raw = RegionExtractor.extractRegions(from: quantized)
        let minArea = minRegionPixelArea(
            mm: parameters.minRegionMM,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let merged = RegionExtractor.mergeSmallRegions(in: raw, minArea: minArea)

        let tolerance = simplifyTolerance(detail: parameters.detail)

        // Only palette colors that survived merging appear in the template,
        // renumbered densely so the child never sees a gap in the legend.
        var usedPaletteIndices = Set<Int>()
        for region in 0..<merged.regionCount {
            usedPaletteIndices.insert(merged.regionColors[region])
        }
        let orderedPalette = usedPaletteIndices.sorted()
        var paletteIndexToNumber = [Int: Int]()
        var palette: [CBNPaletteEntry] = []
        for (offset, paletteIndex) in orderedPalette.enumerated() {
            let color = quantized.palette[paletteIndex]
            let number = offset + 1
            paletteIndexToNumber[paletteIndex] = number
            palette.append(
                CBNPaletteEntry(
                    number: number,
                    name: ColorNamer.name(r: color.r, g: color.g, b: color.b),
                    hex: String(format: "#%02X%02X%02X", color.r, color.g, color.b)
                )
            )
        }

        // Trace every region up front — outer contour and hole contours.
        // Holes are what make real line art render correctly: an outline
        // mesh or an eye-ring-with-pupil paints exactly its own ink under
        // the even-odd rule, instead of relying on draw order (which no
        // ordering can get right for regions spanning several nesting
        // depths — see BoundaryTracer's doc comment).
        let boxes = RegionExtractor.boundingBoxes(in: merged)
        var paths = [[CBNPoint]?](repeating: nil, count: merged.regionCount)
        var holes = [[[CBNPoint]]](repeating: [], count: merged.regionCount)
        var polygonAreas = [Double](repeating: 0, count: merged.regionCount)
        for regionID in 0..<merged.regionCount {
            let contour = BoundaryTracer.traceOuterBoundary(of: regionID, in: merged)
            guard contour.count >= 3 else { continue }
            let simplified = PolygonGeometry.simplify(contour, tolerance: tolerance)
            guard simplified.count >= 3 else { continue }
            paths[regionID] = simplified
            for hole in BoundaryTracer.traceHoleBoundaries(
                of: regionID, in: merged, bounds: boxes[regionID]
            ) {
                guard hole.count >= 3 else { continue }
                let simplifiedHole = PolygonGeometry.simplify(hole, tolerance: tolerance)
                guard simplifiedHole.count >= 3 else { continue }
                holes[regionID].append(simplifiedHole)
            }
            // Area of the *traced* outer contour, not the simplified one:
            // simplification jitters areas by up to the tolerance, and the
            // draw order should reflect true containment.
            polygonAreas[regionID] = abs(PolygonGeometry.signedArea(of: contour))
        }

        // Painter's order, largest outer polygon first. With explicit holes
        // this no longer carries correctness — every region fills exactly
        // its own pixels — but containers-first keeps hairline overlaps
        // from simplification resolving in favor of the smaller, contained
        // region, which is the less noticeable artifact.
        let regionOrder = (0..<merged.regionCount).sorted {
            polygonAreas[$0] != polygonAreas[$1]
                ? polygonAreas[$0] > polygonAreas[$1]
                : $0 < $1
        }

        // Computed once from the pixel mask for every region — see
        // labelPoints' doc comment for why this can't be done from each
        // region's traced polygon (rings and other nested shapes).
        let labelPoints = RegionExtractor.labelPoints(for: merged)

        var regions: [CBNRegion] = []
        regions.reserveCapacity(merged.regionCount)
        for regionID in regionOrder {
            guard let path = paths[regionID] else { continue }
            regions.append(
                CBNRegion(
                    id: "r\(regions.count)",
                    colorNumber: paletteIndexToNumber[merged.regionColors[regionID]]!,
                    path: path,
                    holes: holes[regionID],
                    labelPoint: labelPoints[regionID]
                )
            )
        }

        return CBNTemplate(
            title: title,
            size: CBNSize(width: Double(image.width), height: Double(image.height)),
            palette: palette,
            regions: regions
        )
    }
}

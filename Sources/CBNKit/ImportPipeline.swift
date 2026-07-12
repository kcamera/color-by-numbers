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
    static func simplifyTolerance(detail: Double) -> Double {
        let clamped = min(max(detail, 0), 1)
        // detail 1 → 0.75px (faithful), detail 0 → 5px (calm and chunky).
        return 5.0 - clamped * 4.25
    }

    /// Label-placement precision for the pole-of-inaccessibility search,
    /// in pixels. Coarser would visibly off-center labels in small regions.
    static let labelPrecision = 1.0

    public static func importTemplate(
        from image: RasterImage,
        title: String,
        parameters: ImportParameters
    ) -> CBNTemplate {
        let quantized = Quantizer.quantize(image, maxColors: parameters.colorCount)

        let raw = RegionExtractor.extractRegions(from: quantized)
        let minArea = max(
            1,
            Int(Double(image.width * image.height) * parameters.minRegionAreaFraction)
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

        // Painter's order: largest area first, so contained regions draw
        // over their containers (see BoundaryTracer for why holes work
        // this way).
        let regionOrder = (0..<merged.regionCount).sorted {
            merged.regionAreas[$0] != merged.regionAreas[$1]
                ? merged.regionAreas[$0] > merged.regionAreas[$1]
                : $0 < $1
        }

        var regions: [CBNRegion] = []
        regions.reserveCapacity(merged.regionCount)
        for (index, regionID) in regionOrder.enumerated() {
            let contour = BoundaryTracer.traceOuterBoundary(of: regionID, in: merged)
            guard contour.count >= 3 else { continue }
            let simplified = PolygonGeometry.simplify(contour, tolerance: tolerance)
            guard simplified.count >= 3 else { continue }
            let label = PolygonGeometry.poleOfInaccessibility(
                of: simplified,
                precision: labelPrecision
            )
            regions.append(
                CBNRegion(
                    id: "r\(index)",
                    colorNumber: paletteIndexToNumber[merged.regionColors[regionID]]!,
                    path: simplified,
                    labelPoint: label
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

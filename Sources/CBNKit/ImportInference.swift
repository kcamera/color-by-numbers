import Foundation

/// Per-image inference for the Workshop's two live import knobs (DESIGN.md
/// "The transformation experience": "good inferred defaults are a hard
/// requirement on the pipeline: not touching the knobs must yield a decent
/// template"). No global preset fits every photo — the right color count is
/// a property of the artwork, and the right region floor depends on whether
/// the art has small features worth keeping — so this measures the actual
/// image instead of guessing.
///
/// Ported from the `cbnc suggest` prototype (Sources/cbnc/SuggestCommand.swift),
/// which dealt several candidate cards off a wider (colors × tiers) sweep of
/// the same measurements; the app only ever wants the single starting point,
/// so `inferredParameters` keeps just the color-count and min-mm inference,
/// not the multi-card dealing/distinctness logic. The shared grid, slack
/// constants, and measurement helpers below are `package`-visible so
/// `SuggestCommand` can keep using its wider sweep against the exact same
/// numbers, rather than a second copy that could quietly drift.
public enum ImportInference {
    // MARK: - The candidate grid and selection thresholds

    /// Colors to try when hunting the fidelity elbow.
    package static let colorCandidates = [6, 8, 10, 12, 16]
    /// Min-region-mm tiers to try, finest first, for the region floor
    /// search. Detail stays pinned at 1.0 (DORMANT, see
    /// `ImportParameters.detail` — the parameter is slated for removal).
    package static let minRegionMMTiers: [Double] = [3, 5, 8, 12]

    /// "Within 15% (and half a ΔE) of the 16-color error" defines the
    /// fidelity elbow — the image's natural color count. Past that elbow,
    /// extra palette entries only encode noise (JPEG artifacts, AA halos),
    /// not artwork.
    package static let fidelitySlackRatio = 1.15
    package static let fidelitySlackAbsolute = 0.5
    /// A region hugging the floor — within this many mm above it — counts
    /// as dust; a tier where more than a third of regions are dust flunks
    /// (noise promoted into regions, not features). An absolute band, not a
    /// multiple: at a 12mm floor, a 15mm region is a perfectly good
    /// colorable region, but a 13mm one right at the cut line is usually a
    /// fragment that barely dodged the merge.
    package static let dustBandMM = 1.5
    package static let maxDustShare = 0.35
    /// Sanity bounds on a colorable template.
    package static let minRegions = 4
    package static let maxRegions = 200

    /// One measured (minRegionMM) cell at the inferred color count.
    private struct Cell {
        var minRegionMM: Double
        var regionCount: Int
        var dustShare: Double

        var isViable: Bool {
            regionCount >= ImportInference.minRegions
                && regionCount <= ImportInference.maxRegions
                && dustShare <= ImportInference.maxDustShare
        }
    }

    /// Infers a starting `ImportParameters` for `image`: the fewest colors
    /// that capture the image's own fidelity curve, then the finest region
    /// floor at that color count that isn't dusty. `detail` stays pinned at
    /// 1.0 (dormant, see `ImportParameters.detail`).
    public static func inferredParameters(for image: RasterImage) -> ImportParameters {
        let curve = colorCandidates.map { colorCount -> Double in
            let quantized = Quantizer.quantize(image, maxColors: colorCount)
            return Quantizer.meanQuantizationError(of: quantized, in: image)
        }
        let naturalColors = inferNaturalColors(curve: curve)

        let cells = minRegionMMTiers.map { mm -> Cell in
            let template = ImportPipeline.importTemplate(
                from: image,
                title: "",
                parameters: ImportParameters(colorCount: naturalColors, minRegionMM: mm, detail: 1.0)
            )
            let diameters = regionDiametersMM(of: template, imageWidth: image.width, imageHeight: image.height)
            let dustLimit = mm + dustBandMM
            let dustCount = diameters.filter { $0 < dustLimit }.count
            return Cell(
                minRegionMM: mm,
                regionCount: template.regions.count,
                dustShare: diameters.isEmpty ? 0 : Double(dustCount) / Double(diameters.count)
            )
        }

        // Finest tier that isn't dusty; fall back to the coarsest tier if
        // every tier flunked viability — the parent still needs *some*
        // starting point to react to, and coarsest degrades most gracefully.
        let chosen = cells.first { $0.isViable } ?? cells.last!

        return ImportParameters(colorCount: naturalColors, minRegionMM: chosen.minRegionMM, detail: 1.0)
    }

    // MARK: - Shared measurement (also used by SuggestCommand's wider sweep)

    /// The fidelity elbow: fewest candidate colors whose mean ΔE is within
    /// the slack of the most-colors error.
    package static func inferNaturalColors(curve: [Double]) -> Int {
        let best = curve.last ?? 0
        let threshold = max(best * fidelitySlackRatio, best + fidelitySlackAbsolute)
        for (candidate, error) in zip(colorCandidates, curve) where error <= threshold {
            return candidate
        }
        return colorCandidates.last!
    }

    /// Equivalent-circle diameter in mm per region, from net polygon area
    /// (outer contour minus holes) at the physical scale
    /// `ImportPipeline.referenceLongEdgeMM` anchors to. What both the dust
    /// share and the median-size readout are computed from.
    package static func regionDiametersMM(
        of template: CBNTemplate, imageWidth: Int, imageHeight: Int
    ) -> [Double] {
        let pixelsPerMM = Double(max(imageWidth, imageHeight)) / ImportPipeline.referenceLongEdgeMM
        return template.regions.map { region -> Double in
            let net = max(
                abs(PolygonGeometry.signedArea(of: region.path))
                    - region.holes.reduce(0) { $0 + abs(PolygonGeometry.signedArea(of: $1)) },
                0
            )
            return 2 * (net / Double.pi).squareRoot() / pixelsPerMM
        }
    }
}

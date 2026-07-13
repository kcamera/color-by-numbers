import ArgumentParser
import CBNKit
import CoreGraphics
import Dispatch
import Foundation

/// PROTOTYPE — the "per-image candidate cards" experiment.
///
/// Hypothesis (from tuning sessions): no three fixed parameter bundles fit
/// all images — the right color count is a property of the artwork, and the
/// right region floor depends on whether the art has small features worth
/// keeping. But a human can pick a winner off a contact sheet for any single
/// image instantly. So instead of blessing global presets, run a small sweep
/// *per image*, filter out degenerate cells by measurement, and deal the few
/// most distinct good candidates — what the app's import cards would offer.
///
/// This command exists to test that idea against the corpus before any of
/// it goes near the app.
struct SuggestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "PROTOTYPE: deal per-image candidate imports — what the app's import cards would offer.",
        discussion: """
        For each image, sweeps a small parameter grid, measures every cell, \
        and deals up to three distinct candidates (Simple / Just Right / \
        Detailed) chosen for THIS image:

          colors   Inferred from the image's own fidelity curve: the fewest
                   colors whose mean quantization error (ΔE) is within a
                   slack of the 16-color error. Past that elbow, extra
                   colors only encode noise. (Simple may step one down.)
          min-mm   Per tier: the finest floor whose result isn't full of
                   "dust" — regions barely above the floor, the signature
                   of noise promoted into numbered regions.
          detail   Pinned at 1.0 (dormant parameter, slated for removal).

        Cards that aren't meaningfully different (similar region counts)
        are dropped — an image that only supports one good answer deals
        one card, honestly.

        The console prints every measured cell per image; the sheet shows
        only the dealt cards. The test that matters: is one of the dealt
        cards the one you'd have picked from a full tune sweep?
        """
    )

    @Argument(help: "Image files and/or directories of images.")
    var inputs: [String]

    @Option(name: .shortAndLong, help: "Output directory for the contact sheet.")
    var output: String = "suggest-output"

    @Option(help: "Thumbnail width in pixels for sheet cells.")
    var cellWidth: Int = 420

    // MARK: - The candidate grid and selection thresholds (prototype knobs)

    /// Floor tiers, finest first. Detail is pinned at 1.0 (DORMANT — lower
    /// values only facet boundaries; the parameter is slated for removal,
    /// see ImportParameters.detail).
    private static let tiers: [(mm: Double, detail: Double)] = [
        (3, 1.0), (5, 1.0), (8, 1.0), (12, 1.0),
    ]
    private static let colorCandidates = [6, 8, 10, 12, 16]

    /// "Within 15% (and half a ΔE) of the 16-color error" defines the
    /// fidelity elbow — the image's natural color count.
    private static let fidelitySlackRatio = 1.15
    private static let fidelitySlackAbsolute = 0.5
    /// A region hugging the floor — within this many mm above it — counts
    /// as dust; a cell where more than a third of regions are dust flunks
    /// (noise promoted into regions, not features). An absolute band, not
    /// a multiple: at a 12mm floor, a 15mm region is a perfectly good
    /// colorable region, but a 13mm one right at the cut line is usually a
    /// fragment that barely dodged the merge.
    private static let dustBandMM = 1.5
    private static let maxDustShare = 0.35
    /// Sanity bounds on a colorable template.
    private static let minRegions = 4
    private static let maxRegions = 200
    /// Adjacent dealt cards must differ by ≥30% in region count, or the
    /// less interesting one is dropped.
    private static let distinctnessRatio = 1.3

    // MARK: - Measured cells

    private struct Cell {
        var colorCount: Int
        var tierIndex: Int
        var template: CBNTemplate
        var regionCount: Int
        var paletteCount: Int
        var dustShare: Double
        var medianRegionMM: Double

        var mm: Double { SuggestCommand.tiers[tierIndex].mm }
        var detail: Double { SuggestCommand.tiers[tierIndex].detail }

        var isViable: Bool {
            regionCount >= SuggestCommand.minRegions
                && regionCount <= SuggestCommand.maxRegions
                && dustShare <= SuggestCommand.maxDustShare
        }

        var summary: String {
            String(
                format: "c%-2d %4.0fmm d%.2f  %3d regions  %2d colors  dust %3.0f%%  median %.1fmm",
                colorCount, mm, detail, regionCount, paletteCount, dustShare * 100, medianRegionMM
            )
        }
    }

    private struct Card {
        var label: String
        var cell: Cell
    }

    func run() throws {
        let imageURLs = try ImageCollection.collect(from: inputs)
        guard !imageURLs.isEmpty else {
            throw ValidationError("No images found in: \(inputs.joined(separator: ", "))")
        }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let rasters = try imageURLs.map { try RasterImage.load(from: $0) }
        let stems = imageURLs.map { $0.deletingPathExtension().lastPathComponent }

        let colorCount = Self.colorCandidates.count
        let tierCount = Self.tiers.count
        let cellsPerImage = colorCount * tierCount

        print("Measuring \(imageURLs.count) image(s) × \(colorCount) color counts × \(tierCount) tiers = \(imageURLs.count * cellsPerImage) cells…")

        // Phase 1 — fidelity curves: mean ΔE per (image, colorCount).
        // Disjoint-index writes into a plain buffer, same pattern as tune.
        nonisolated(unsafe) let errors = UnsafeMutableBufferPointer<Double>.allocate(
            capacity: imageURLs.count * colorCount
        )
        errors.initialize(repeating: 0)
        defer { errors.deallocate() }
        DispatchQueue.concurrentPerform(iterations: imageURLs.count * colorCount) { index in
            let imageIndex = index / colorCount
            let quantized = Quantizer.quantize(
                rasters[imageIndex], maxColors: Self.colorCandidates[index % colorCount]
            )
            errors[index] = Quantizer.meanQuantizationError(of: quantized, in: rasters[imageIndex])
        }

        // Phase 2 — import every grid cell and measure it.
        nonisolated(unsafe) let cells = UnsafeMutableBufferPointer<Cell?>.allocate(
            capacity: imageURLs.count * cellsPerImage
        )
        cells.initialize(repeating: nil)
        defer { cells.deallocate() }
        DispatchQueue.concurrentPerform(iterations: imageURLs.count * cellsPerImage) { index in
            let imageIndex = index / cellsPerImage
            let colorIndex = (index % cellsPerImage) / tierCount
            let tierIndex = index % tierCount
            let tier = Self.tiers[tierIndex]
            let raster = rasters[imageIndex]

            let template = ImportPipeline.importTemplate(
                from: raster,
                title: stems[imageIndex],
                parameters: ImportParameters(
                    colorCount: Self.colorCandidates[colorIndex],
                    minRegionMM: tier.mm,
                    detail: tier.detail
                )
            )
            cells[index] = Self.measure(
                template,
                colorCount: Self.colorCandidates[colorIndex],
                tierIndex: tierIndex,
                imageWidth: raster.width,
                imageHeight: raster.height
            )
        }

        // Phase 3 — per image: infer colors, deal cards, render, report.
        var sections: [ContactSheetSection] = []
        for imageIndex in imageURLs.indices {
            let curve = (0..<colorCount).map { errors[imageIndex * colorCount + $0] }
            let imageCells = (0..<cellsPerImage).compactMap {
                cells[imageIndex * cellsPerImage + $0]
            }
            let naturalColors = Self.inferNaturalColors(curve: curve)
            let cards = Self.deal(cells: imageCells, naturalColors: naturalColors)

            let curveText = zip(Self.colorCandidates, curve)
                .map { String(format: "%d→%.1f", $0, $1) }
                .joined(separator: "  ")
            print("\n\(stems[imageIndex]): ΔE by colors  \(curveText)  → natural \(naturalColors)")
            for cell in imageCells.sorted(by: { ($0.colorCount, $0.tierIndex) < ($1.colorCount, $1.tierIndex) }) {
                let dealt = cards.first { $0.cell.colorCount == cell.colorCount && $0.cell.tierIndex == cell.tierIndex }
                let marker = dealt.map { "◀ \($0.label)" } ?? (cell.isViable ? "" : "  (degenerate)")
                print("  \(cell.summary)  \(marker)")
            }

            var sheetCells: [ContactSheetCell] = []
            for card in cards {
                let cell = card.cell
                let baseName = "\(stems[imageIndex])-\(card.label.lowercased().replacingOccurrences(of: " ", with: "-"))"
                var fileNames: [String] = []
                let scale = Double(cellWidth) / cell.template.size.width
                for mode in [TemplateRenderer.Mode.composite, .outline] {
                    guard let image = TemplateRenderer.render(cell.template, mode: mode, scale: scale) else { continue }
                    let fileName = "\(baseName)-\(mode.rawValue).png"
                    try RasterImage.writePNG(image, to: outputURL.appendingPathComponent(fileName))
                    fileNames.append(fileName)
                }
                sheetCells.append(
                    ContactSheetCell(
                        caption: "\(card.label) — c\(cell.colorCount) · \(cell.mm)mm · d\(cell.detail)",
                        detailLine: String(
                            format: "%d regions · %d colors · dust %.0f%%",
                            cell.regionCount, cell.paletteCount, cell.dustShare * 100
                        ),
                        imageFiles: fileNames
                    )
                )
            }
            sections.append(ContactSheetSection(title: stems[imageIndex], cells: sheetCells))
        }

        let sheetURL = outputURL.appendingPathComponent("index.html")
        try ContactSheet.html(sections: sections)
            .write(to: sheetURL, atomically: true, encoding: .utf8)
        print("\nDealt cards: \(sheetURL.path)")
        print("Judge each image: is one of its cards the one you'd have picked from a full sweep?")
    }

    // MARK: - Measurement and selection

    private static func measure(
        _ template: CBNTemplate,
        colorCount: Int,
        tierIndex: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> Cell {
        let pixelsPerMM = Double(max(imageWidth, imageHeight)) / ImportPipeline.referenceLongEdgeMM
        // Equivalent-circle diameter in mm per region, from net polygon area.
        let diameters = template.regions.map { region -> Double in
            let net = max(
                abs(PolygonGeometry.signedArea(of: region.path))
                    - region.holes.reduce(0) { $0 + abs(PolygonGeometry.signedArea(of: $1)) },
                0
            )
            return 2 * (net / Double.pi).squareRoot() / pixelsPerMM
        }
        let dustLimit = tiers[tierIndex].mm + dustBandMM
        let dustCount = diameters.filter { $0 < dustLimit }.count
        let sorted = diameters.sorted()
        return Cell(
            colorCount: colorCount,
            tierIndex: tierIndex,
            template: template,
            regionCount: template.regions.count,
            paletteCount: template.palette.count,
            dustShare: diameters.isEmpty ? 0 : Double(dustCount) / Double(diameters.count),
            medianRegionMM: sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        )
    }

    /// The fidelity elbow: fewest candidate colors whose mean ΔE is within
    /// the slack of the most-colors error.
    private static func inferNaturalColors(curve: [Double]) -> Int {
        let best = curve.last ?? 0
        let threshold = max(best * fidelitySlackRatio, best + fidelitySlackAbsolute)
        for (candidate, error) in zip(colorCandidates, curve) where error <= threshold {
            return candidate
        }
        return colorCandidates.last!
    }

    private static func deal(cells: [Cell], naturalColors: Int) -> [Card] {
        func cell(colors: Int, tier: Int) -> Cell? {
            cells.first { $0.colorCount == colors && $0.tierIndex == tier }
        }

        // Detailed: natural colors, finest floor that isn't dusty.
        let detailed = tiers.indices
            .compactMap { cell(colors: naturalColors, tier: $0) }
            .first { $0.isViable }

        // Simple: one color step down (if the curve allows one), coarsest
        // floor that still leaves something to color.
        let simpleColors = colorCandidates.last { $0 < naturalColors } ?? naturalColors
        let simple = tiers.indices.reversed()
            .compactMap { cell(colors: simpleColors, tier: $0) }
            .first { $0.isViable }

        // Just Right: natural colors, the tier between the two.
        var justRight: Cell? = nil
        if let detailed, let simple, simple.tierIndex - detailed.tierIndex >= 2 {
            let middle = (detailed.tierIndex + simple.tierIndex) / 2
            justRight = cell(colors: naturalColors, tier: middle).flatMap { $0.isViable ? $0 : nil }
        }

        // Assemble busiest-first, then enforce distinctness by region count:
        // a card too similar to the one before it is noise, not a choice.
        var cards: [Card] = []
        for (label, candidate) in [("Detailed", detailed), ("Just Right", justRight), ("Simple", simple)] {
            guard let candidate else { continue }
            if let last = cards.last?.cell,
               Double(last.regionCount) < Double(candidate.regionCount) * distinctnessRatio {
                continue
            }
            cards.append(Card(label: label, cell: candidate))
        }
        // Never deal zero cards: if every cell flunked viability, offer the
        // least-bad one (lowest dust, then most regions) rather than
        // nothing — the parent still needs *an* import to react to.
        if cards.isEmpty {
            let pool = cells.filter { $0.regionCount >= 2 && $0.regionCount <= maxRegions }
            let preferred = pool.filter { $0.colorCount == naturalColors }
            let fallback = (preferred.isEmpty ? pool : preferred).min {
                ($0.dustShare, -$0.regionCount) < ($1.dustShare, -$1.regionCount)
            }
            if let fallback { cards.append(Card(label: "Just Right", cell: fallback)) }
        }

        // A single card keeps its honest name: the image supports one answer.
        if cards.count == 1 { cards[0].label = "Just Right" }
        return cards
    }
}

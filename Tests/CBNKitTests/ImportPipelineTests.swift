import Foundation
import Testing
@testable import CBNKit

// MARK: - Tiny synthetic rasters (no files, no CoreGraphics — pure buffers)

/// Builds a RasterImage from rows of single-character color codes, e.g.
/// ["rrbb", "rrbb"]. Test scenes stay readable at a glance.
private func raster(_ rows: [String], colors: [Character: (UInt8, UInt8, UInt8)]) -> RasterImage {
    let height = rows.count
    let width = rows[0].count
    var rgba = [UInt8]()
    rgba.reserveCapacity(width * height * 4)
    for row in rows {
        for code in row {
            let (r, g, b) = colors[code]!
            rgba.append(contentsOf: [r, g, b, 255])
        }
    }
    return RasterImage(width: width, height: height, rgba: rgba)
}

private let inks: [Character: (UInt8, UInt8, UInt8)] = [
    "r": (200, 40, 40),
    "b": (40, 80, 200),
    "w": (250, 250, 250),
    "g": (60, 160, 60),
]

// MARK: - Quantizer

@Test func quantizerKeepsDistinctFillsSeparate() {
    let image = raster(
        ["rrrbbb",
         "rrrbbb",
         "rrrbbb"],
        colors: inks
    )
    let quantized = Quantizer.quantize(image, maxColors: 8)
    #expect(quantized.palette.count == 2)
}

@Test func quantizerAbsorbsAntialiasingBlends() {
    // A near-red AA blend between fills should merge into red, not become
    // its own palette entry.
    var custom = inks
    custom["R"] = (205, 50, 48) // ΔE from "r" well under the merge threshold
    let image = raster(
        ["rrRbbb",
         "rrRbbb"],
        colors: custom
    )
    let quantized = Quantizer.quantize(image, maxColors: 8)
    #expect(quantized.palette.count == 2)
}

@Test func quantizerHonorsMaxColors() {
    let image = raster(
        ["rbwg",
         "rbwg"],
        colors: inks
    )
    let quantized = Quantizer.quantize(image, maxColors: 2)
    #expect(quantized.palette.count == 2)
    // Every pixel still labeled within the reduced palette.
    #expect(quantized.labels.allSatisfy { $0 >= 0 && $0 < 2 })
}

// MARK: - Region extraction

@Test func connectedComponentsSplitSameColorIslands() {
    // Two red squares separated by blue: same palette color, two regions.
    let image = raster(
        ["rrbrr",
         "rrbrr"],
        colors: inks
    )
    let quantized = Quantizer.quantize(image, maxColors: 4)
    let map = RegionExtractor.extractRegions(from: quantized)
    #expect(map.regionCount == 3)
}

@Test func smallRegionsMergeIntoLongestBorderNeighbor() {
    let image = raster(
        ["rrrrrr",
         "rrgrrr",
         "rrrrrr",
         "bbbbbb"],
        colors: inks
    )
    let quantized = Quantizer.quantize(image, maxColors: 4)
    let raw = RegionExtractor.extractRegions(from: quantized)
    #expect(raw.regionCount == 3)
    let merged = RegionExtractor.mergeSmallRegions(in: raw, minArea: 3)
    // The lone green pixel is absorbed by red (its only neighbor).
    #expect(merged.regionCount == 2)
    #expect(merged.regionAreas.reduce(0, +) == 24)
}

// MARK: - Boundary tracing

@Test func tracedSquareBoundsMatchTheRegion() {
    let image = raster(
        ["wwwww",
         "wrrrw",
         "wrrrw",
         "wrrrw",
         "wwwww"],
        colors: inks
    )
    let quantized = Quantizer.quantize(image, maxColors: 4)
    let map = RegionExtractor.extractRegions(from: quantized)
    let redRegion = (0..<map.regionCount).first { map.regionAreas[$0] == 9 }!
    let contour = BoundaryTracer.traceOuterBoundary(of: redRegion, in: map)
    #expect(contour.count >= 4)
    #expect(contour.map(\.x).min() == 1 && contour.map(\.x).max() == 3)
    #expect(contour.map(\.y).min() == 1 && contour.map(\.y).max() == 3)
}

// MARK: - End-to-end on the committed TestArt corpus

private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test func bannerImportsWithExactStructure() throws {
    let image = try RasterImage.load(from: repoRoot.appendingPathComponent("TestArt/banner.png"))
    let template = ImportPipeline.importTemplate(
        from: image,
        title: "banner",
        parameters: ImportParameters(colorCount: 8, minRegionAreaFraction: 0.001, detail: 0.6)
    )
    // Hard-edged synthetic blocks: structure must be exact, not approximate.
    #expect(template.palette.count == 4)
    #expect(template.regions.count == 4)
    #expect(template.validate().isEmpty)
}

@Test func confettiSpecklesMergeAway() throws {
    let image = try RasterImage.load(from: repoRoot.appendingPathComponent("TestArt/confetti.png"))
    let template = ImportPipeline.importTemplate(
        from: image,
        title: "confetti",
        parameters: PresetStore.preset(id: "simple")!.parameters
    )
    // 120 tiny dots all sit below Simple's min region size: only the
    // background and the large ellipse survive.
    #expect(template.regions.count == 2)
    #expect(template.validate().isEmpty)
}

/// The idempotence property from docs/PLAN.md: a rendering of an existing
/// CBN template, re-imported, must come back structurally unchanged.
@Test func sailboatRoundTripsThroughThePipeline() throws {
    let originalURL = repoRoot.appendingPathComponent("Samples/LittleSailboat/template.json")
    let original = try JSONDecoder().decode(
        CBNTemplate.self, from: Data(contentsOf: originalURL)
    )
    let rendered = try RasterImage.load(from: repoRoot.appendingPathComponent("TestArt/sailboat.png"))
    let reimported = ImportPipeline.importTemplate(
        from: rendered,
        title: "sailboat",
        parameters: ImportParameters(colorCount: 8, minRegionAreaFraction: 0.001, detail: 0.7)
    )

    #expect(reimported.regions.count == original.regions.count)
    #expect(reimported.palette.count == original.palette.count)
    #expect(reimported.validate().isEmpty)

    // Every original palette color survives quantization nearly exactly
    // (AA halos must collapse into the fills, not shift them).
    for entry in original.palette {
        let target = entry.rgb!
        let closest = reimported.palette
            .compactMap(\.rgb)
            .map { color in
                abs(color.red - target.red) + abs(color.green - target.green) + abs(color.blue - target.blue)
            }
            .min()!
        #expect(closest < 0.06, "palette color \(entry.hex) drifted through the pipeline")
    }
}

// MARK: - Presets

@Test func bundledPresetsLoadAndAreOrdered() {
    let presets = PresetStore.bundled()
    #expect(presets.map(\.id) == ["simple", "just-right", "detailed"])
    // Preset semantics: simpler presets mean fewer colors and bigger
    // minimum regions.
    #expect(presets[0].colorCount < presets[2].colorCount)
    #expect(presets[0].minRegionAreaFraction > presets[2].minRegionAreaFraction)
}

import CoreGraphics
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
        parameters: ImportParameters(colorCount: 8, minRegionMM: 7, detail: 0.6)
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

/// Regression test for a real bug: a ring's traced boundary is its outer
/// edge only (painter's order handles the hole, not a polygon hole — see
/// BoundaryTracer), so placing labels via that shape's pole of
/// inaccessibility put every concentric ring's number at the same shared
/// center. Concentric squares hit the identical hole/painter's-order
/// topology as concentric circles but are trivial to draw as ASCII rows.
@Test func concentricRegionsGetDistinctLabelPoints() {
    let image = raster(
        ["aaaaaaa",
         "abbbbba",
         "abcccba",
         "abcccba",
         "abcccba",
         "abbbbba",
         "aaaaaaa"],
        colors: [
            "a": (200, 40, 40),
            "b": (40, 160, 60),
            "c": (40, 80, 200),
        ]
    )
    let template = ImportPipeline.importTemplate(
        from: image,
        title: "rings",
        parameters: ImportParameters(colorCount: 8, minRegionMM: 2, detail: 0.9)
    )
    #expect(template.regions.count == 3)

    // No two regions' labels collapsed onto the same pixel...
    let labelKeys = template.regions.map { "\($0.labelPoint.x),\($0.labelPoint.y)" }
    #expect(Set(labelKeys).count == template.regions.count)

    // Each ring's even-odd path cuts out everything nested inside it.
    let holeCounts = template.regions
        .sorted { $0.holes.count > $1.holes.count }
        .map(\.holes.count)
    #expect(holeCounts == [1, 1, 0])

    // ...and each label actually sits on a pixel of its own color, not
    // merely somewhere unique.
    for region in template.regions {
        let x = Int(region.labelPoint.x)
        let y = Int(region.labelPoint.y)
        let pixelOffset = image.pixelOffset(x: x, y: y)
        let expectedColor = template.palette.first { $0.number == region.colorNumber }!.rgb!
        let actualRed = Double(image.rgba[pixelOffset]) / 255
        #expect(abs(actualRed - expectedColor.red) < 0.05, "label for region \(region.id) is not on its own color")
    }
}

/// Regression test for a real bug: in line art, the outline strokes form
/// one connected region with few *pixels* but an outer boundary enclosing
/// nearly the whole drawing. Painter's order used to sort by pixel count,
/// which drew that region after the larger fills it encloses — stamping a
/// giant dark silhouette over them ("black floods the picture"). The order
/// must follow traced-polygon area instead, so containers always draw
/// before their contents.
@Test func thinOutlineMeshDrawsBeforeTheFillsItEncloses() {
    // A 12×8 scene: white background, and a one-pixel black frame-with-a-
    // divider (an "ink mesh") enclosing a red room and a blue room. Black
    // has 25 pixels — fewer than red (18) and blue (12) — but its traced
    // outer boundary covers both rooms.
    let image = raster(
        ["wwwwwwwwwwww",
         "wkkkkkkkkkkw",
         "wkrrrrrkbbkw",
         "wkrrrrrkbbkw",
         "wkrrrrrkbbkw",
         "wkkkkkkkkkkw",
         "wwwwwwwwwwww",
         "wwwwwwwwwwww"],
        colors: [
            "w": (250, 250, 250),
            "k": (20, 20, 20),
            "r": (200, 40, 40),
            "b": (40, 80, 200),
        ]
    )
    let template = ImportPipeline.importTemplate(
        from: image,
        title: "mesh",
        parameters: ImportParameters(colorCount: 8, minRegionMM: 2, detail: 1.0)
    )
    #expect(template.regions.count == 4)

    // template.regions is stored in draw order. The frame must come after
    // the background but before both rooms it encloses.
    func region(ofHex hex: String) -> (index: Int, region: CBNRegion) {
        let number = template.palette.first { $0.hex == hex }!.number
        let index = template.regions.firstIndex { $0.colorNumber == number }!
        return (index, template.regions[index])
    }
    let frame = region(ofHex: "#141414")
    #expect(region(ofHex: "#FAFAFA").index < frame.index)
    #expect(frame.index < region(ofHex: "#C82828").index)
    #expect(frame.index < region(ofHex: "#2850C8").index)

    // Hole structure: the frame's even-odd path must cut out both rooms,
    // the background cuts out the whole framed block, the rooms are solid.
    #expect(frame.region.holes.count == 2)
    #expect(region(ofHex: "#FAFAFA").region.holes.count == 1)
    #expect(region(ofHex: "#C82828").region.holes.isEmpty)
    #expect(region(ofHex: "#2850C8").region.holes.isEmpty)
    #expect(template.validate().isEmpty)
}

/// The topology that no draw order can render: cartoon eyes. The dark ring
/// and the pupil are one connected region (joined by a "lash" spur), which
/// must paint both *around* the eye white and *inside* it. Explicit hole
/// rings with even-odd fill are the only correct answer, so this test
/// renders the template and checks actual pixels — pupil dark, eye white
/// intact — which held regardless of painter's order.
@Test func attachedPupilSurvivesRendering() {
    let image = raster(
        ["wwwwwwwwwwwwwwww",
         "wkkkkkkkkkkkkkkw",
         "wkrrrrrrkrrrrrkw",
         "wkrrrrrrkrrrrrkw",
         "wkrrrrrkkkrrrrkw",
         "wkrrrrrkkkrrrrkw",
         "wkrrrrrrrrrrrrkw",
         "wkkkkkkkkkkkkkkw",
         "wwwwwwwwwwwwwwww"],
        colors: [
            "w": (250, 250, 250),
            "k": (20, 20, 20),
            "r": (200, 40, 40), // stands in for the eye white
        ]
    )
    let template = ImportPipeline.importTemplate(
        from: image,
        title: "eye",
        parameters: ImportParameters(colorCount: 8, minRegionMM: 2, detail: 1.0)
    )
    #expect(template.regions.count == 3)

    // The ring+spur+pupil is one dark region with exactly one hole (the
    // "eye white" is one connected pocket); the pocket region is solid.
    let darkNumber = template.palette.first { $0.hex == "#141414" }!.number
    let dark = template.regions.first { $0.colorNumber == darkNumber }!
    #expect(dark.holes.count == 1)
    let redNumber = template.palette.first { $0.hex == "#C82828" }!.number
    #expect(template.regions.first { $0.colorNumber == redNumber }!.holes.isEmpty)

    // Render filled at 4× and check ground truth per template pixel.
    let rendered = TemplateRenderer.render(template, mode: .filled, scale: 4)!
    func sample(_ x: Double, _ y: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        pixelColor(in: rendered, x: Int(x * 4), y: Int(y * 4))
    }
    // Pupil center: dark ink inside the eye white — the pixel painter's
    // order always got wrong one way or the other.
    #expect(sample(8, 4.5).r < 60, "pupil was painted over")
    // Eye white on both sides of the lash spur.
    #expect(sample(4, 4.5).r > 150, "left eye white lost")
    #expect(sample(11.5, 4.5).r > 150, "right eye white lost")
    // The ring itself and the lash spur stay dark.
    #expect(sample(8, 1.5).r < 60, "top ring lost")
    #expect(sample(8, 2.5).r < 60, "lash spur lost")
    // Outside the ring stays white.
    #expect(sample(0.4, 0.4).r > 200, "background lost")
}

/// Reads one pixel from a rendered CGImage (top-left origin, matching
/// template coordinates).
private func pixelColor(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var rgba = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &rgba,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Draw the image so that (x, y) — measured from the top-left, like
    // template coordinates — lands on this 1×1 context's only pixel.
    context.draw(
        image,
        in: CGRect(
            x: -CGFloat(x),
            y: CGFloat(y) - CGFloat(image.height - 1),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
    )
    return (rgba[0], rgba[1], rgba[2])
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
        parameters: ImportParameters(colorCount: 8, minRegionMM: 7, detail: 0.7)
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

// MARK: - Studio thumbnail face (filledRegionIDs)

/// A tiny two-region template, hand-built rather than imported: the Studio
/// thumbnail tests only care about TemplateRenderer's `filledRegionIDs`
/// bookkeeping, not the import pipeline, so a synthetic document keeps them
/// from depending on quantizer/tracer behavior incidentally.
private func twoRegionTemplate() -> CBNTemplate {
    CBNTemplate(
        title: "two-region",
        size: CBNSize(width: 20, height: 10),
        palette: [
            CBNPaletteEntry(number: 1, name: "left", hex: "#C82828"),
            CBNPaletteEntry(number: 2, name: "right", hex: "#2850C8"),
        ],
        regions: [
            CBNRegion(
                id: "left",
                colorNumber: 1,
                path: [
                    CBNPoint(x: 0, y: 0), CBNPoint(x: 10, y: 0),
                    CBNPoint(x: 10, y: 10), CBNPoint(x: 0, y: 10),
                ],
                labelPoint: CBNPoint(x: 5, y: 5)
            ),
            CBNRegion(
                id: "right",
                colorNumber: 2,
                path: [
                    CBNPoint(x: 10, y: 0), CBNPoint(x: 20, y: 0),
                    CBNPoint(x: 20, y: 10), CBNPoint(x: 10, y: 10),
                ],
                labelPoint: CBNPoint(x: 15, y: 5)
            ),
        ]
    )
}

/// DESIGN.md's Studio-honesty requirement (the M2 gate feedback): a
/// thumbnail must show what the child has actually colored, not a pristine
/// outline. This is the renderer half of that — `.outline` mode with
/// `filledRegionIDs` set bakes exactly the interactive canvas's appearance
/// (CanvasView.draw) into a bitmap.
@Test func outlineModeWithFilledRegionIDsPaintsOnlyThoseRegions() {
    let template = twoRegionTemplate()
    let rendered = TemplateRenderer.render(
        template, mode: .outline, scale: 4, filledRegionIDs: ["left"]
    )!

    // Sampled near each region's corner, away from both its stroked border
    // and its centered number glyph (drawn at labelPoint, the region's
    // center) — a fill check must not accidentally hit ink instead of paint.
    let leftCorner = pixelColor(in: rendered, x: 2 * 4, y: 2 * 4)
    let rightCorner = pixelColor(in: rendered, x: 18 * 4, y: 2 * 4)

    // "left" is filled: its palette red, not white.
    #expect(leftCorner.r > 150 && leftCorner.g < 100, "filled region did not show its palette color")
    // "right" is untouched: stays white, exactly like an uncolored region
    // on the interactive canvas.
    #expect(rightCorner.r > 230 && rightCorner.g > 230 && rightCorner.b > 230, "unfilled region was not white")
}

/// Regression guard: omitting `filledRegionIDs` (every existing call site —
/// cbnc render/tune/suggest, and the Studio thumbnail's own old behavior)
/// must still render `.outline` as pure white-and-numbers, unchanged.
@Test func outlineModeWithNilFilledRegionIDsStaysAllWhite() {
    let template = twoRegionTemplate()
    let rendered = TemplateRenderer.render(template, mode: .outline, scale: 4)!

    let leftCorner = pixelColor(in: rendered, x: 2 * 4, y: 2 * 4)
    let rightCorner = pixelColor(in: rendered, x: 18 * 4, y: 2 * 4)

    #expect(leftCorner.r > 230 && leftCorner.g > 230 && leftCorner.b > 230, "unfilled region was not white")
    #expect(rightCorner.r > 230 && rightCorner.g > 230 && rightCorner.b > 230, "unfilled region was not white")
}

// MARK: - Presets

@Test func bundledPresetsLoadAndAreOrdered() {
    let presets = PresetStore.bundled()
    #expect(presets.map(\.id) == ["simple", "just-right", "detailed"])
    // Preset semantics: simpler presets mean fewer colors and bigger
    // minimum regions.
    #expect(presets[0].colorCount < presets[2].colorCount)
    #expect(presets[0].minRegionMM > presets[2].minRegionMM)
}

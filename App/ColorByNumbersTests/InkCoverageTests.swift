import CBNKit
import PencilKit
import Testing
import UIKit

@testable import ColorByNumbers

/// A 100×100 template split into two side-by-side 50×100 regions, each its
/// own color. Hand-authored: coverage measurement only needs geometry and
/// a palette, not the import pipeline.
@MainActor
private func sideBySideTemplate() -> CBNTemplate {
    CBNTemplate(
        title: "Side By Side",
        size: CBNSize(width: 100, height: 100),
        palette: [
            CBNPaletteEntry(number: 1, name: "Red", hex: "#E03C31"),
            CBNPaletteEntry(number: 2, name: "Blue", hex: "#2C6BED"),
        ],
        regions: [
            CBNRegion(
                id: "left", colorNumber: 1,
                path: [
                    CBNPoint(x: 0, y: 0), CBNPoint(x: 50, y: 0),
                    CBNPoint(x: 50, y: 100), CBNPoint(x: 0, y: 100),
                ],
                labelPoint: CBNPoint(x: 25, y: 50)
            ),
            CBNRegion(
                id: "right", colorNumber: 2,
                path: [
                    CBNPoint(x: 50, y: 0), CBNPoint(x: 100, y: 0),
                    CBNPoint(x: 100, y: 100), CBNPoint(x: 50, y: 100),
                ],
                labelPoint: CBNPoint(x: 75, y: 50)
            ),
        ]
    )
}

/// One synthetic monoline stroke in TEMPLATE space (the document's stroke
/// coordinate system — CanvasView persists gestures there): a straight
/// vertical line of the given width. `overshoot` extends it past both the
/// top and bottom edges so the round line caps can't leave uncovered
/// crescents inside the region.
@MainActor
private func verticalStroke(x: CGFloat, width: CGFloat, color: UIColor, height: CGFloat = 100) -> PKStroke {
    let points = stride(from: -10, through: height + 10, by: 5).map { y in
        PKStrokePoint(
            location: CGPoint(x: x, y: y),
            timeOffset: TimeInterval(y + 10) / 100,
            size: CGSize(width: width, height: width),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        )
    }
    return PKStroke(
        ink: PKInk(.monoline, color: color),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
}

/// A fat freehand stroke down the middle of the left region covers it
/// (width 60 over a 50-wide region reaches every pixel); the right region —
/// caught only by the stroke's spill-over — stays uncovered.
@MainActor
@Test func fatFreehandStrokeCoversItsRegionButNotTheSpilledNeighbor() {
    let template = sideBySideTemplate()
    let stroke = verticalStroke(x: 25, width: 60, color: .red)
    let drawing = PKDrawing(strokes: [stroke])
    var attempt = CBNAttempt()
    attempt.recordStroke(drawing.dataRepresentation())

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: drawing)
    #expect(covered.contains("left"))
    #expect(!covered.contains("right"))
}

/// A thin line through a region is drawing, not coloring-in — nowhere near
/// the coverage threshold.
@MainActor
@Test func thinStrokeDoesNotCoverItsRegion() {
    let template = sideBySideTemplate()
    let stroke = verticalStroke(x: 25, width: 4, color: .red)
    let drawing = PKDrawing(strokes: [stroke])
    var attempt = CBNAttempt()
    attempt.recordStroke(drawing.dataRepresentation())

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: drawing)
    #expect(covered.isEmpty)
}

/// A boundary-assist gesture's spill-over is masked out of the composite
/// (CommittedInkRenderer clips its paint to the crayon's regions), so even
/// a stroke that would flood the neighbor raw leaves it untouched — the
/// coverage measurement sees exactly what the child sees.
@MainActor
@Test func clippedGestureSpillNeverCountsTowardTheNeighbor() {
    let template = sideBySideTemplate()
    // Red crayon (color 1, the LEFT region), drawn straddling the shared
    // boundary: raw it would paint a 30pt-wide band into the right region.
    let redColor = UIColor(red: 0xE0 / 255, green: 0x3C / 255, blue: 0x31 / 255, alpha: 1)
    let stroke = verticalStroke(x: 50, width: 60, color: redColor)
    let drawing = PKDrawing(strokes: [stroke])
    var attempt = CBNAttempt()
    attempt.recordStroke(drawing.dataRepresentation(), clipped: true)

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: drawing)
    #expect(!covered.contains("right"))
}

/// Tap fills cover by construction — flat paint over the region's whole
/// visible area — with no strokes anywhere.
@MainActor
@Test func tapFillCoversItsRegionWithoutAnyStrokes() {
    let template = sideBySideTemplate()
    var attempt = CBNAttempt()
    attempt.recordTapFill("right")

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: PKDrawing())
    #expect(covered == ["right"])
}

/// A pristine attempt covers nothing.
@MainActor
@Test func pristineAttemptCoversNothing() {
    let template = sideBySideTemplate()
    let covered = InkCoverage.coveredRegionIDs(
        template: template, attempt: CBNAttempt(), drawing: PKDrawing()
    )
    #expect(covered.isEmpty)
}

/// Both regions covered — one by strokes, one by tap — is exactly the
/// mixed-mode completion the Done badge could never reach before coverage:
/// the fixed regression where stroke-colored regions never counted.
@MainActor
@Test func strokesAndTapFillsTogetherCoverTheWholeTemplate() {
    let template = sideBySideTemplate()
    let stroke = verticalStroke(x: 25, width: 60, color: .red)
    let drawing = PKDrawing(strokes: [stroke])
    var attempt = CBNAttempt()
    attempt.recordStroke(drawing.dataRepresentation())
    attempt.recordTapFill("right")

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: drawing)
    #expect(covered == ["left", "right"])
}

/// A real but SUB-PIXEL region (too small to win a single pixel of the
/// coarse measurement raster) must not be mistaken for an occluded one and
/// silently marked covered — it's exactly the kind of tiny region the
/// crayon-hint exists to point at. It falls back to a single ink sample at
/// its label point: covered only once ink actually sits there.
@MainActor
@Test func subPixelRegionFallsBackToLabelPointSample() {
    // 2000-unit template at a 256px raster → scale 0.128; a 1×1-unit
    // region rasterizes to nothing.
    let tiny = CBNRegion(
        id: "tiny", colorNumber: 2,
        path: [
            CBNPoint(x: 1000, y: 1000), CBNPoint(x: 1001, y: 1000),
            CBNPoint(x: 1001, y: 1001), CBNPoint(x: 1000, y: 1001),
        ],
        labelPoint: CBNPoint(x: 1000.5, y: 1000.5)
    )
    let backdrop = CBNRegion(
        id: "backdrop", colorNumber: 1,
        path: [
            CBNPoint(x: 0, y: 0), CBNPoint(x: 2000, y: 0),
            CBNPoint(x: 2000, y: 2000), CBNPoint(x: 0, y: 2000),
        ],
        labelPoint: CBNPoint(x: 200, y: 200)
    )
    let template = CBNTemplate(
        title: "Tiny",
        size: CBNSize(width: 2000, height: 2000),
        palette: [
            CBNPaletteEntry(number: 1, name: "Red", hex: "#E03C31"),
            CBNPaletteEntry(number: 2, name: "Blue", hex: "#2C6BED"),
        ],
        // Backdrop first, tiny painted over it — tiny is visible, just small.
        regions: [backdrop, tiny]
    )

    // No ink anywhere near it: not covered (and not mistaken for occluded).
    var untouched = CBNAttempt()
    let bareStroke = verticalStroke(x: 100, width: 40, color: .red, height: 2000)
    let bareDrawing = PKDrawing(strokes: [bareStroke])
    untouched.recordStroke(bareDrawing.dataRepresentation())
    let uncovered = InkCoverage.coveredRegionIDs(
        template: template, attempt: untouched, drawing: bareDrawing
    )
    #expect(!uncovered.contains("tiny"))

    // A fat freehand stroke straight through it: covered via the sample.
    var inkedOver = CBNAttempt()
    let coveringStroke = verticalStroke(x: 1000, width: 80, color: .blue, height: 2000)
    let coveringDrawing = PKDrawing(strokes: [coveringStroke])
    inkedOver.recordStroke(coveringDrawing.dataRepresentation())
    let covered = InkCoverage.coveredRegionIDs(
        template: template, attempt: inkedOver, drawing: coveringDrawing
    )
    #expect(covered.contains("tiny"))
}

/// A region fully hidden behind a later region (painter's order) has no
/// visible pixels — it can never be seen or touched, so it counts as
/// covered rather than holding completion hostage.
@MainActor
@Test func fullyOccludedRegionCountsAsCovered() {
    let template = CBNTemplate(
        title: "Occluded",
        size: CBNSize(width: 100, height: 100),
        palette: [
            CBNPaletteEntry(number: 1, name: "Red", hex: "#E03C31"),
            CBNPaletteEntry(number: 2, name: "Blue", hex: "#2C6BED"),
        ],
        regions: [
            // Drawn FIRST, then completely repainted by "cover" below.
            CBNRegion(
                id: "buried", colorNumber: 1,
                path: [
                    CBNPoint(x: 20, y: 20), CBNPoint(x: 40, y: 20),
                    CBNPoint(x: 40, y: 40), CBNPoint(x: 20, y: 40),
                ],
                labelPoint: CBNPoint(x: 30, y: 30)
            ),
            CBNRegion(
                id: "cover", colorNumber: 2,
                path: [
                    CBNPoint(x: 0, y: 0), CBNPoint(x: 100, y: 0),
                    CBNPoint(x: 100, y: 100), CBNPoint(x: 0, y: 100),
                ],
                labelPoint: CBNPoint(x: 70, y: 70)
            ),
        ]
    )
    // One stroke somewhere, so the measurement actually walks the raster
    // (the interesting path), and a tap fill on the visible region: the
    // buried one must not be the lone holdout.
    let stroke = verticalStroke(x: 50, width: 4, color: .blue)
    let drawing = PKDrawing(strokes: [stroke])
    var attempt = CBNAttempt()
    attempt.recordStroke(drawing.dataRepresentation())

    let covered = InkCoverage.coveredRegionIDs(template: template, attempt: attempt, drawing: drawing)
    #expect(covered.contains("buried"))
    #expect(!covered.contains("cover"))
}

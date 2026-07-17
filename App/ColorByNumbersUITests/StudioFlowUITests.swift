import XCTest

/// M2 runtime-verification driver — not a unit-test suite (CBNKit logic is
/// tested in the SwiftPM package). This drives the REAL app through the
/// studio → canvas → tap-to-fill → relaunch → undo flow on a simulator,
/// capturing screenshots as evidence at each checkpoint. The assertions are
/// existence checks that keep the drive honest; the screenshots and the
/// on-disk attempt JSON (inspected from outside via
/// `simctl get_app_container`) are the actual verification artifacts.
final class StudioFlowUITests: XCTestCase {

    @MainActor
    func testTapToFillPersistsAcrossRelaunch() throws {
        // Rotate the simulated device to landscape first: on iPadOS 26's
        // windowing model a landscape-only app in a portrait device renders
        // upright-but-scaled (not rotated), which would letterbox every
        // screenshot below and skew the normalized tap coordinates.
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        // Studio: the newest starter card is Little Sailboat (seed order).
        let card = app.staticTexts["Little Sailboat"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card never appeared")
        attachScreenshot(of: app, named: "1-studio")
        card.tap()

        // Canvas: the quiet back control marks arrival.
        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        // M3 active-color gate: a tap only fills the region that matches
        // the held crayon (little-sailboat.json's colorNumber per region),
        // so each artwork tap below is preceded by selecting that region's
        // crayon. Two taps spread across the artwork: sky (top middle,
        // color 1) and sea (bottom middle, color 3). Misses/wrong-crayon
        // taps are silent no-ops by design, so the screenshot is what
        // proves fills happened.
        let window = app.windows.firstMatch
        app.buttons["Color 1"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        app.buttons["Color 3"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        attachScreenshot(of: app, named: "2-canvas-after-taps")

        // Continuous autosave contract: kill the process outright, relaunch,
        // reopen the same card — the fills must still be there.
        app.terminate()
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio missing after relaunch")
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not reopen")
        attachScreenshot(of: app, named: "3-canvas-after-relaunch")

        // Undo removes only the most recent fill, and saves that too.
        app.buttons["Undo"].tap()
        attachScreenshot(of: app, named: "4-after-undo")

        // Studio-honesty check (M2 gate feedback): popping back to the
        // grid must show the card's CURRENT coloring state, not a pristine
        // outline — undo removed the sea fill but left the sky filled, so
        // the sailboat's thumbnail should visibly show a colored sky.
        app.staticTexts["Studio"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        attachScreenshot(of: app, named: "5-studio-after-coloring")
    }

    /// Drives one picture to completion and checks the quiet "Done" badge:
    /// absent while coloring, present once the last region fills, gone again
    /// after an undo (it states the attempt's current state, not a trophy).
    /// Banner is the target because it has the fewest regions (4: three
    /// stripes plus a centered square); the 5×3 tap grid below covers all of
    /// them, and the extra taps are silent no-ops by design.
    @MainActor
    func testDoneBadgeTracksCompletion() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Banner"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Banner card never appeared")
        card.tap()
        XCTAssertTrue(app.staticTexts["Studio"].waitForExistence(timeout: 10), "Canvas did not open")

        let done = app.staticTexts["Done"]
        XCTAssertFalse(done.exists, "Done badge visible before any coloring (needs a fresh install)")

        // M3 active-color gate: spray the same 5×3 grid once per palette
        // color in banner.json (1...4), holding that crayon selected. A tap
        // only fills a region matching the held crayon, so re-tapping the
        // whole grid for every color is still safe — a re-tap on an
        // already-filled region and a tap with the wrong crayon are both
        // silent no-ops by design — and it guarantees every region meets
        // its matching color regardless of exactly where it sits on screen.
        let window = app.windows.firstMatch
        for colorNumber in 1...4 {
            app.buttons["Color \(colorNumber)"].tap()
            for dy in [0.25, 0.5, 0.75] {
                for dx in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
                }
            }
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done badge never appeared after filling every region")
        attachScreenshot(of: app, named: "done-1-complete")
        // Element-level capture: `app.screenshot()` on the iPadOS 26 sim
        // draws the landscape app into a portrait frame and crops the
        // trailing edge — exactly where this badge lives — so grab the
        // badge's own pixels as direct evidence.
        let badgeShot = XCTAttachment(screenshot: done.screenshot())
        badgeShot.name = "done-1b-badge-closeup"
        badgeShot.lifetime = .keepAlways
        add(badgeShot)

        app.buttons["Undo"].tap()
        XCTAssertFalse(done.exists, "Done badge should retract when undo re-opens a region")
        attachScreenshot(of: app, named: "done-2-after-undo")
    }

    /// M3's headline flow: one Undo button taking back "the last thing that
    /// happened" across BOTH action kinds. Fills a region in tap mode,
    /// switches to freehand, drags a stroke, relaunches (continuous
    /// autosave must cover both), then undoes twice — stroke first, fill
    /// second, matching `effectiveActionLog`'s interleaved order. The
    /// on-disk attempt JSON's `actionLog` at each checkpoint is inspected
    /// externally via `simctl get_app_container` (see .claude/skills/verify);
    /// the assertions here are the same kind of existence checks the other
    /// two tests use, with screenshots as the visual evidence.
    @MainActor
    func testFreehandStrokePersistsAndUndoInterleaves() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Little Sailboat"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card never appeared")
        card.tap()

        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        // Tap mode first: fill the sky (little-sailboat.json's "sky" region
        // is colorNumber 1), same crayon/coordinate as
        // testTapToFillPersistsAcrossRelaunch — one known-good fill before
        // ever touching the mode switch.
        let window = app.windows.firstMatch
        app.buttons["Color 1"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        attachScreenshot(of: app, named: "freehand-1-after-fill")

        // Switch to Draw mode and drag a stroke across the artwork — a
        // press-and-drag on an XCUICoordinate is XCUITest's way of driving
        // a continuous touch, which PencilKit's `.anyInput` drawing policy
        // (finger/Pencil parity, DESIGN.md) accepts same as a real finger.
        app.buttons["Draw mode"].tap()
        let strokeStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        let strokeEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        strokeStart.press(forDuration: 0.1, thenDragTo: strokeEnd)
        attachScreenshot(of: app, named: "freehand-2-after-stroke")

        // Continuous autosave (DESIGN.md) must cover the stroke exactly
        // like it already covers fills: kill outright, relaunch, reopen —
        // both must still be there.
        app.terminate()
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio missing after relaunch")
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not reopen")
        attachScreenshot(of: app, named: "freehand-3-after-relaunch")

        // Undo unification (M3): the on-disk log is ["fill", "stroke"], so
        // one tap takes back the stroke (log -> ["fill"], drawing empties)...
        app.buttons["Undo"].tap()
        attachScreenshot(of: app, named: "freehand-4-after-first-undo")

        // ...and a second tap takes back the fill (log -> [], attempt
        // pristine again) — exactly the interleaved order the action log
        // exists to preserve.
        app.buttons["Undo"].tap()
        attachScreenshot(of: app, named: "freehand-5-after-second-undo")
    }

    /// Boundary-assist (M3's middle mode): ink lands only where the held
    /// crayon's number lives, and one Undo takes back the whole gesture.
    /// Drags one long horizontal stroke through the sailboat at ~45%
    /// height while holding the sky crayon — that row is sky, interrupted
    /// by both sails (Sailcloth, a different number), so the single
    /// gesture must bake into multiple sub-strokes with visible gaps at
    /// the sails. Visual proof: screenshots. Data proof: the on-disk
    /// actionLog records ONE "strokes:N" (N≥2) entry, inspected externally
    /// per .claude/skills/verify. Undo must then remove every sub-stroke
    /// at once — the child undoes her gesture, not the clipper's output.
    @MainActor
    func testBoundaryAssistClipsAndUndoesWholeGesture() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Little Sailboat"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card never appeared")
        card.tap()
        XCTAssertTrue(app.staticTexts["Studio"].waitForExistence(timeout: 10), "Canvas did not open")

        app.buttons["Color 1"].tap()
        app.buttons["Lines mode"].tap()
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        attachScreenshot(of: app, named: "boundary-1-clipped-stroke")

        // The per-stroke ink mask (allowedInkMask) must survive
        // serialization: kill outright, relaunch, reopen — the clipped
        // stroke must come back still pixel-clipped, no bloom past the
        // outlines. This is the checkpoint that would catch PencilKit
        // dropping PKStroke.mask on a data round trip.
        app.terminate()
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio missing after relaunch")
        card.tap()
        XCTAssertTrue(app.staticTexts["Studio"].waitForExistence(timeout: 10), "Canvas did not reopen")
        attachScreenshot(of: app, named: "boundary-2-after-relaunch")

        // One Undo, whole gesture: every sub-stroke disappears together.
        app.buttons["Undo"].tap()
        attachScreenshot(of: app, named: "boundary-3-after-undo")
    }

    /// M3's "Color it again" (DESIGN.md, amended): to the child it's a
    /// fresh page — canvas clears in place, no dialog, no animation — while
    /// the walked-away-from attempt is archived invisibly underneath
    /// (`CBNLibrary.newAttempt`'s ring buffer; on-disk survival is checked
    /// externally via `simctl get_app_container`, per .claude/skills/verify).
    /// Fills the sky, draws a short freehand stroke, checks the Studio
    /// thumbnail shows BOTH (this is Feature 2's visual evidence — strokes
    /// now composite into thumbnails), reopens the card, taps "Color it
    /// again", and checks the canvas comes back pristine: no fills, no ink,
    /// no Done badge, and the button itself gone (nothing left to reset).
    /// Back in the Studio, the thumbnail is a bare outline again.
    @MainActor
    func testColorItAgainResetsCanvasAndStudio() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Little Sailboat"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card never appeared")
        card.tap()

        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        // Fill the sky, same crayon/coordinate as the other canvas tests.
        let window = app.windows.firstMatch
        app.buttons["Color 1"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        // A short freehand stroke, so the thumbnail has ink to show
        // alongside the fill.
        app.buttons["Draw mode"].tap()
        let strokeStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
        let strokeEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        strokeStart.press(forDuration: 0.1, thenDragTo: strokeEnd)
        attachScreenshot(of: app, named: "again-1-canvas-fill-and-stroke")

        // Studio: the honest thumbnail (Feature 2) must show fill AND
        // stroke together.
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        attachScreenshot(of: app, named: "again-2-studio-fill-and-stroke")

        // Reopen and reset.
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not reopen")
        let colorItAgain = app.buttons["Color it again"]
        XCTAssertTrue(colorItAgain.waitForExistence(timeout: 5), "Color it again button missing on a non-pristine attempt")
        colorItAgain.tap()

        // Pristine canvas: no Done badge, and the button itself hides —
        // nothing left to reset (CBNLibrary.newAttempt's mash-guard would
        // no-op a second tap anyway).
        XCTAssertFalse(app.staticTexts["Done"].exists, "Done badge should not survive Color it again")
        XCTAssertFalse(colorItAgain.exists, "Color it again should hide once the attempt is pristine again")
        attachScreenshot(of: app, named: "again-3-canvas-pristine")

        // Studio: the thumbnail resets to a bare outline.
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        attachScreenshot(of: app, named: "again-4-studio-pristine")
    }

    /// The M3 crayon-layering fix: real crayons stack by TIME, so a region
    /// tap-filled AFTER a freehand scribble crossed it must paint OVER that
    /// scribble, not under it (`CommittedInkRenderer.image`'s chronological
    /// fill repaint). Rings is the vehicle because its center region — the
    /// bullseye, `rings.json`'s innermost ring, colorNumber 5 ("Green") — sits
    /// at normalized (0.5, 0.5) of the landscape window: Rings is a square
    /// template centered in that window, so window-center IS artwork-center,
    /// no geometry to work out by hand. Scribbles first with a DIFFERENT
    /// crayon (Color 4, "Red" — the ring just outside the bullseye), so any
    /// ink visible at dead-center after the late fill can only be the
    /// bullseye's own fill, not a coincidence of matching colors.
    @MainActor
    func testLateFillCoversEarlierScribble() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Rings"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Rings card never appeared")
        card.tap()

        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        // Draw mode, a different crayon than the bullseye's, two short
        // crossing drags through dead-center — freehand ink lands wherever
        // the pen goes, no boundary clipping to fight here.
        app.buttons["Draw mode"].tap()
        app.buttons["Color 4"].tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        attachScreenshot(of: app, named: "cover-1-scribbled")

        // Tap mode, the bullseye's own crayon, dead-center: this fill
        // happens AFTER the scribble above, so it must render on top of it
        // inside the bullseye (the scribble stays visible OUTSIDE the
        // bullseye, where it was never re-filled — that part is correct,
        // unchanged behavior).
        app.buttons["Tap mode"].tap()
        app.buttons["Color 5"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(of: app, named: "cover-2-late-fill")

        // Continuous autosave must cover the chronological repaint exactly
        // like it covers every other action: kill outright, relaunch,
        // reopen — the late fill must still be on top after restore.
        app.terminate()
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio missing after relaunch")
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not reopen")
        attachScreenshot(of: app, named: "cover-3-after-relaunch")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// M2 runtime-verification driver — not a unit-test suite (CBNKit logic is
/// tested in the SwiftPM package). This drives the REAL app through the
/// studio → canvas → tap-to-fill → relaunch → undo flow on a simulator,
/// capturing screenshots as evidence at each checkpoint. The assertions are
/// existence checks that keep the drive honest; the screenshots and the
/// on-disk attempt JSON (inspected from outside via
/// `simctl get_app_container`) are the actual verification artifacts.
final class StudioFlowUITests: XCTestCase {

    /// Press-and-hold reveal (Kevin's design, replacing an earlier
    /// fixed-duration flash he flagged as either missable or, if
    /// re-checked by repeat-tapping, "a flashing light simulator"):
    /// holding a swatch selects that crayon immediately — same as a tap
    /// always has — and shows its unfilled regions' numbers oversized for
    /// as long as the finger stays down. XCUITest can't assert on the
    /// transient highlight's own pixels (confirmed by hand instead, via a
    /// throwaway sticky-state build during development — screenshot
    /// showed a clearly oversized "2" against its normal-sized neighbors),
    /// so this proves the surrounding functional contract: the press
    /// selects the crayon and the canvas stays fully responsive straight
    /// through press, hold, and release — the overlay driving the
    /// highlight must never intercept touches or leave stray state behind.
    @MainActor
    func testHeldCrayonSelectsAndRevealsWithoutBreakingCanvas() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Rings"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card 'Rings' never appeared")
        card.tap()
        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        let colorButton = app.buttons["Color 2"]
        XCTAssertTrue(colorButton.waitForExistence(timeout: 5), "Color 2 swatch missing")
        colorButton.press(forDuration: 1.0)
        attachScreenshot(of: app, named: "held-crayon-highlight")

        XCTAssertTrue(back.exists, "Canvas broke after a held crayon press")
        XCTAssertTrue(colorButton.isHittable, "Color 2 swatch unreachable after release")
    }

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
    /// second, matching `actionLog`'s interleaved order. The
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

    /// M4's headline flow: the Workshop door, the parental gate, and the one
    /// real Workshop feature shipped this milestone (drawing width). The
    /// gate deals three random digits as lowercase words (WorkshopGateView's
    /// "Gate words" element exposes them as its label) — this test reads
    /// them, types a deliberately WRONG sequence, and checks the calm
    /// silent reset: still at the gate, but with NEW words dealt (never an
    /// error message, per DESIGN.md's no-error-feedback contract). It then
    /// reads the re-dealt words and types them correctly, landing in the
    /// Workshop (the "Drawing" section header is the arrival signal). A
    /// width choice there must survive a full relaunch — through the gate
    /// again — the same continuous-persistence bar every other Canvas
    /// setting in this suite clears.
    @MainActor
    func testWorkshopGateAndWidthSetting() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let doorButton = app.buttons["Workshop"]
        XCTAssertTrue(doorButton.waitForExistence(timeout: 10), "Workshop door never appeared")
        doorButton.tap()

        let gateWords = app.staticTexts["Gate words"]
        XCTAssertTrue(gateWords.waitForExistence(timeout: 10), "Gate did not appear")
        attachScreenshot(of: app, named: "workshop-1-gate")

        let firstDealt = digits(from: gateWords.label)
        XCTAssertEqual(firstDealt.count, 3, "Gate words did not parse to three digits: \(gateWords.label)")

        // A deliberately wrong sequence: the dealt first digit shifted by
        // one (wrapped back to 1 past 9), then two arbitrary digits — the
        // gate only judges once all three taps land, so a mismatch anywhere
        // in the sequence is enough.
        let wrongFirst = firstDealt[0] == 9 ? 1 : firstDealt[0] + 1
        app.buttons["\(wrongFirst)"].tap()
        app.buttons["1"].tap()
        app.buttons["1"].tap()

        // Still at the gate — a miss never unlocks — but with NEW words
        // dealt: the calm silent reset, no error message anywhere.
        XCTAssertTrue(gateWords.waitForExistence(timeout: 5), "Gate should still be showing after a wrong entry")
        let secondDealt = digits(from: gateWords.label)
        XCTAssertEqual(secondDealt.count, 3, "Re-dealt gate words did not parse to three digits: \(gateWords.label)")
        XCTAssertNotEqual(firstDealt, secondDealt, "Gate words did not change after a wrong entry")
        attachScreenshot(of: app, named: "workshop-2-after-wrong-entry")

        // The re-dealt words, entered correctly this time, unlock the
        // Workshop.
        for digit in secondDealt {
            app.buttons["\(digit)"].tap()
        }
        let drawingHeader = app.staticTexts["Drawing"]
        XCTAssertTrue(drawingHeader.waitForExistence(timeout: 10), "Workshop did not appear after correct entry")
        attachScreenshot(of: app, named: "workshop-3-unlocked")

        // Pick a freehand width and let it persist.
        let widthFour = app.buttons["Freehand width 4"]
        XCTAssertTrue(widthFour.waitForExistence(timeout: 5), "Freehand width 4 control missing")
        widthFour.tap()
        attachScreenshot(of: app, named: "workshop-4-width-selected")

        // Continuous persistence, same bar as every other Canvas setting in
        // this suite: kill outright, relaunch, walk back through the gate,
        // and the width-4 choice must still be selected.
        app.terminate()
        app.launch()

        XCTAssertTrue(doorButton.waitForExistence(timeout: 10), "Workshop door missing after relaunch")
        doorButton.tap()
        XCTAssertTrue(gateWords.waitForExistence(timeout: 10), "Gate did not reappear after relaunch")
        let thirdDealt = digits(from: gateWords.label)
        XCTAssertEqual(thirdDealt.count, 3, "Gate words did not parse to three digits on relaunch: \(gateWords.label)")
        for digit in thirdDealt {
            app.buttons["\(digit)"].tap()
        }
        XCTAssertTrue(drawingHeader.waitForExistence(timeout: 10), "Workshop did not reappear after relaunch")

        XCTAssertTrue(widthFour.isSelected, "Freehand width 4 should still be selected after relaunch")
        attachScreenshot(of: app, named: "workshop-5-width-persisted")
    }

    /// M4's import flow: PhotosPicker → live outline preview → two knobs →
    /// add to Studio (`ImportFlowView.swift`). Requires the simulator's
    /// photo library to already contain
    /// `Fixtures/import-fixture.png` — XCUITest itself has no API to seed
    /// Photos, so the drive script (.claude/skills/verify) must run
    /// `xcrun simctl addmedia <udid> App/ColorByNumbersUITests/Fixtures/import-fixture.png`
    /// BEFORE launching this suite. An empty library here is a setup gap,
    /// not a regression in the flow, so the test skips rather than fails.
    @MainActor
    func testImportFlowFromSeededPhoto() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        try openWorkshop(app)
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 10), "Workshop did not appear after correct gate entry")

        let chooseAPhoto = app.buttons["Choose a photo"]
        XCTAssertTrue(chooseAPhoto.waitForExistence(timeout: 5), "Bring in a picture button missing")
        chooseAPhoto.tap()

        // The system PhotosPicker (out-of-process PHPickerViewController) —
        // its photo cells surface as `app.images`. Generous wait: a cold
        // simulator's Photos process can be slow to come up.
        // Match actual photo CELLS, not just any Image: the picker shows a
        // "Private Access to Photos" banner whose app icon is also an
        // Image, and `app.images.firstMatch` can land on it. Real photo
        // cells carry labels beginning with "Photo".
        //
        // The grid orders OLDEST-seeded first (confirmed empirically —
        // not the "most recent first" a Recents view would suggest), so
        // the SECOND cell is whatever got seeded second. This test needs
        // `import-fixture.png` specifically (flat 3-color art, so it
        // always leaves headroom below the 16-color ceiling for "More
        // colors" to move) — seeded AFTER rainbow-fixture.png, so it's
        // cell index 1. See `testManyColorImportKeepsCanvasControlsReachable`'s
        // doc comment, which targets the FIRST cell (rainbow, seeded
        // first) for the opposite reason.
        let photoMatches = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        let firstPhoto = photoMatches.element(boundBy: 1)
        guard firstPhoto.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "Simulator photo library needs at least 2 photos, seeded in this "
                    + "exact order (the picker grid puts the FIRST-seeded photo "
                    + "first): xcrun simctl addmedia <udid> "
                    + "App/ColorByNumbersUITests/Fixtures/rainbow-fixture.png && "
                    + "xcrun simctl addmedia <udid> "
                    + "App/ColorByNumbersUITests/Fixtures/import-fixture.png"
            )
        }
        // Coordinate tap, not element tap: the picker is a remote process
        // (out-of-process PHPicker), and its cells report existence but
        // fail XCUITest's hittability check — "Failed to not hittable" —
        // while a tap at the cell's on-screen coordinates lands fine.
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Single-select PhotosPicker dismisses itself on tap; some
        // presentations still show an explicit confirm step, so tap it if
        // one shows up rather than assuming either behavior.
        let confirmAdd = app.buttons["Add"]
        if confirmAdd.waitForExistence(timeout: 2) {
            confirmAdd.tap()
        }

        // The knobs only render once a picture is loaded and inferred —
        // "More colors"'s appearance IS the "the preview is up" signal.
        let moreColors = app.buttons["More colors"]
        XCTAssertTrue(moreColors.waitForExistence(timeout: 20), "Import preview/knobs never appeared after picking a photo")
        attachScreenshot(of: app, named: "import-1-preview")

        // Visual evidence the live preview reacts to the knob (M4 spec).
        // Each tap must wait for the button to be ENABLED, not just exist:
        // the very first inferred preview can still be rendering when this
        // test reaches here, and a tap during that window is correctly a
        // no-op under the new press-lock (see `waitForEnabled`).
        XCTAssertTrue(waitForEnabled(moreColors), "More colors never became enabled (stuck locked?)")
        moreColors.tap()
        XCTAssertTrue(waitForEnabled(moreColors), "More colors never re-enabled after the first tap's render")
        moreColors.tap()
        attachScreenshot(of: app, named: "import-2-more-colors")

        let backToSuggested = app.buttons["Back to suggested"]
        XCTAssertTrue(backToSuggested.waitForExistence(timeout: 5), "Back to suggested should appear once a knob moved off its inferred default")
        backToSuggested.tap()
        XCTAssertFalse(app.buttons["Back to suggested"].exists, "Back to suggested should hide again once values match the inferred defaults")

        // The field starts empty (placeholder "New Picture"), so typing
        // needs no select-all-and-clear dance.
        let titleField = app.textFields["Title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Title field missing")
        titleField.tap()
        titleField.typeText("Test Import")

        let addToStudio = app.buttons["Add to Studio"]
        XCTAssertTrue(addToStudio.exists, "Add to Studio button missing")
        addToStudio.tap()

        // Back in the Workshop once the import cover dismisses. The new
        // picture must show up in "Pictures" right here, without leaving
        // and re-entering the Workshop — `PicturesSection` is a sibling of
        // the import button, not something the cover's dismissal used to
        // notify at all (Kevin's report: a completed import never showed
        // up in Pictures until leaving and re-entering the Workshop).
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 15), "Workshop did not reappear after Add to Studio")
        XCTAssertTrue(
            app.staticTexts["Test Import"].waitForExistence(timeout: 10),
            "New picture 'Test Import' never appeared in the Workshop's Pictures list"
        )

        app.buttons["Close"].firstMatch.tap()

        let newCard = app.staticTexts["Test Import"]
        XCTAssertTrue(newCard.waitForExistence(timeout: 10), "New Studio card 'Test Import' never appeared")
        attachScreenshot(of: app, named: "import-3-studio-with-new-card")
    }

    /// M4's color-count knob goes up to 16 (`ImportFlowView.colorRange`),
    /// but `PaletteRail` (CanvasView.swift) was built assuming "our
    /// templates top out at 6 colors" — a 12+ color import overflowed its
    /// unbounded VStack, which stretched the WHOLE layer past the screen
    /// and pushed every OTHER corner control (Undo, Back, ModeSwitch) off
    /// screen with it (Kevin's report). A synthetic rainbow-gradient source
    /// image (`rainbow-fixture.png`) whose own natural fidelity elbow sits
    /// exactly at the knob's 16-color ceiling puts the import straight at
    /// that ceiling with no tapping needed; this confirms every other
    /// canvas control stays reachable, plus that the palette rail itself
    /// becomes scrollable rather than silently dropping swatches.
    ///
    /// Needs a source image with real color variety — `import-fixture.png`
    /// is flat 3-color art that can never quantize past 3 colors no matter
    /// what the knob asks for. Targets the FIRST grid cell: the picker
    /// grid orders OLDEST-seeded first (confirmed empirically — not a
    /// Recents-style newest-first), so seeding rainbow-fixture.png FIRST
    /// puts it at cell index 0. `testImportFlowFromSeededPhoto` claims
    /// cell index 1 (`import-fixture.png`, seeded second) for the
    /// opposite reason — it needs headroom below the color ceiling for
    /// its own knob taps to do anything, and this fixture's inferred
    /// count sits AT that ceiling, which would make "More colors" a
    /// permanent no-op there. Seed order:
    /// `xcrun simctl addmedia <udid> .../rainbow-fixture.png &&
    /// xcrun simctl addmedia <udid> .../import-fixture.png`.
    @MainActor
    func testManyColorImportKeepsCanvasControlsReachable() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        try openWorkshop(app)
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 10), "Workshop did not appear after correct gate entry")

        let chooseAPhoto = app.buttons["Choose a photo"]
        XCTAssertTrue(chooseAPhoto.waitForExistence(timeout: 5), "Bring in a picture button missing")
        chooseAPhoto.tap()

        // First grid cell — rainbow-fixture, seeded first. See the doc
        // comment above for why this isn't cell index 1.
        let firstPhoto = app.images.matching(
            NSPredicate(format: "label BEGINSWITH 'Photo'")
        ).firstMatch
        guard firstPhoto.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "Simulator photo library is empty, or seeded in the wrong order "
                    + "(rainbow-fixture.png must be seeded FIRST). Seed it before "
                    + "running this suite: xcrun simctl addmedia <udid> "
                    + "App/ColorByNumbersUITests/Fixtures/rainbow-fixture.png && "
                    + "xcrun simctl addmedia <udid> "
                    + "App/ColorByNumbersUITests/Fixtures/import-fixture.png"
            )
        }
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let confirmAdd = app.buttons["Add"]
        if confirmAdd.waitForExistence(timeout: 2) {
            confirmAdd.tap()
        }

        // The rainbow gradient's own natural fidelity elbow (confirmed via
        // `cbnc suggest`) sits exactly at the knob's ceiling, 16 — no
        // tapping needed; the INFERRED default already puts the palette
        // rail at the exact size this test exists to exercise. "More
        // colors" is correctly disabled from the first frame here (there's
        // nowhere higher to go), so this only waits for the knobs to
        // render at all, not for them to become enabled.
        let moreColors = app.buttons["More colors"]
        XCTAssertTrue(moreColors.waitForExistence(timeout: 45), "Import preview/knobs never appeared after picking a photo")

        let titleField = app.textFields["Title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Title field missing")
        titleField.tap()
        titleField.typeText("Rainbow Test")

        let addToStudio = app.buttons["Add to Studio"]
        XCTAssertTrue(addToStudio.exists, "Add to Studio button missing")
        addToStudio.tap()

        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 15), "Workshop did not reappear after Add to Studio")
        XCTAssertTrue(
            app.staticTexts["Rainbow Test"].waitForExistence(timeout: 10),
            "New picture 'Rainbow Test' never appeared in the Workshop's Pictures list"
        )
        app.buttons["Close"].firstMatch.tap()

        let card = app.staticTexts["Rainbow Test"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio card 'Rainbow Test' never appeared")
        card.tap()

        // Canvas: the regression itself. Every OTHER corner control must
        // stay reachable regardless of how tall the palette rail's full
        // content would be — this is what broke before the fix (the whole
        // layer stretched past the screen and took these controls with it).
        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")
        XCTAssertTrue(back.isHittable, "Back control pushed off screen by an oversized palette rail")
        XCTAssertTrue(app.buttons["Tap mode"].isHittable, "Mode switch pushed off screen by an oversized palette rail")
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), "Undo control missing")
        XCTAssertTrue(app.buttons["Undo"].isHittable, "Undo control pushed off screen by an oversized palette rail")

        let firstSwatch = app.buttons["Color 1"]
        XCTAssertTrue(firstSwatch.waitForExistence(timeout: 5), "First palette swatch missing")
        XCTAssertTrue(firstSwatch.isHittable, "First palette swatch unreachable")
        attachScreenshot(of: app, named: "many-colors-1-canvas")

        // The last swatch proves the rail actually scrolls rather than
        // just clipping content off — it must EXIST (never silently
        // dropped) even before scrolling reaches it. Dragged from a FIXED
        // screen coordinate over the rail's trailing-edge column, not from
        // any specific swatch element — `firstSwatch.swipeUp()` scrolls
        // that very element out from under itself after one pass, and
        // every retry after that fails with "visible frame is empty."
        let window = app.windows.firstMatch
        let railStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.6))
        let railEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.1))
        let lastSwatch = app.buttons["Color 16"]
        XCTAssertTrue(lastSwatch.waitForExistence(timeout: 5), "Last palette swatch (16) missing from the tree entirely")
        // A fixed number of blind swipes, then a direct tap — polling
        // `isHittable` in a loop first was flaky (it lags the scroll
        // animation by a beat and reads as a false miss right when the
        // drag actually landed, confirmed by screenshot evidence of a
        // successful scroll+tap on a run where that loop still failed).
        // `.tap()` already retries internally, same as every other
        // element interaction in this file.
        for _ in 0..<8 {
            railStart.press(forDuration: 0.05, thenDragTo: railEnd)
        }
        // No pre-flight `isHittable` assertion here on purpose (see
        // above) — `.tap()` fails loudly on its own if the element
        // genuinely never became reachable, which is all the diagnostic
        // value that check was adding.
        lastSwatch.tap()
        attachScreenshot(of: app, named: "many-colors-2-scrolled-to-last")
    }

    /// M4's Pictures management (WorkshopView.swift's `PicturesSection`):
    /// rename, restore-from-archive, and remove. Banner is the target
    /// (nobody else's tests touch it beyond `testDoneBadgeTracksCompletion`,
    /// and test order within this suite is alphabetical, so that test's
    /// leftover fill state may already be sitting on Banner by the time
    /// this one runs) — this drives Banner to a known state itself rather
    /// than trusting anything left behind: it fills every region fresh (a
    /// re-tap on an already-filled region, or a tap with the wrong crayon,
    /// is always a silent no-op, so this is safe regardless of starting
    /// point), archives that completed attempt with "Color it again,"
    /// restores it from the Workshop's archive, then renames and finally
    /// removes the picture — all three verbs, in the order the M4 spec
    /// walks through them.
    @MainActor
    func testLibraryManagementRenameRestoreRemove() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let card = app.staticTexts["Banner"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Banner card never appeared")
        card.tap()
        let back = app.staticTexts["Studio"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not open")

        // Fill every region fresh, same 5x3-grid-per-color spray as
        // `testDoneBadgeTracksCompletion` — safe regardless of whatever a
        // prior test left behind.
        let window = app.windows.firstMatch
        for colorNumber in 1...4 {
            app.buttons["Color \(colorNumber)"].tap()
            for dy in [0.25, 0.5, 0.75] {
                for dx in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
                }
            }
        }
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 5), "Done badge never appeared after filling every region")

        // Archive this completed attempt and reset — `CanvasModel.colorItAgain`,
        // exactly like `testColorItAgainResetsCanvasAndStudio`, just on Banner.
        let colorItAgain = app.buttons["Color it again"]
        XCTAssertTrue(colorItAgain.waitForExistence(timeout: 5), "Color it again button missing on a completed attempt")
        colorItAgain.tap()
        XCTAssertFalse(app.staticTexts["Done"].exists, "Done badge should not survive Color it again")
        attachScreenshot(of: app, named: "library-1-banner-archived")

        // Into the Workshop.
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        try openWorkshop(app)
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 10), "Workshop did not appear after correct gate entry")

        // Pictures: Banner's row now has exactly one archived attempt (the
        // one just completed and reset above) — "Earlier versions" only
        // shows once an item has MORE than its current attempt (M4 spec).
        // Title-suffixed because every item with an archive shows this
        // control at once (Little Sailboat has one too, from
        // `testColorItAgainResetsCanvasAndStudio`, which runs first
        // alphabetically) — plain "Earlier versions" would be ambiguous.
        let earlierVersions = app.buttons["Earlier versions Banner"]
        scrollToHittable(earlierVersions, in: app)
        XCTAssertTrue(earlierVersions.waitForExistence(timeout: 5), "Earlier versions disclosure missing for Banner")
        attachScreenshot(of: app, named: "library-2-pictures-section")
        earlierVersions.tap()

        // Bring the just-archived (fully filled) version back as Banner's
        // current attempt. Title-prefixed match, not an exact label: the
        // control's own accessibility label also carries the archived
        // attempt's date, which this test doesn't know in advance.
        let bringBack = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bring back Banner'")).firstMatch
        scrollToHittable(bringBack, in: app)
        XCTAssertTrue(bringBack.waitForExistence(timeout: 5), "Bring back control missing for Banner's archived attempt")
        attachScreenshot(of: app, named: "library-3-earlier-versions-expanded")
        bringBack.tap()

        // Close the Workshop and reopen Banner: a crisp existence check that
        // the restore actually landed. Banner was filled completely before
        // the archive, so a successful restore means the Done badge is back
        // immediately, with no coloring in between — exactly the check the
        // M4 spec calls for in place of asserting on thumbnail pixels.
        scrollToTop(app)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear after closing the Workshop")
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Canvas did not reopen")
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 5), "Done badge should reappear after restoring the completed attempt")
        attachScreenshot(of: app, named: "library-4-banner-restored")

        // Back to the Workshop to rename Banner.
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        try openWorkshop(app)
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 10), "Workshop did not reappear after correct gate entry")

        let renameBanner = app.buttons["Rename Banner"]
        scrollToHittable(renameBanner, in: app)
        XCTAssertTrue(renameBanner.waitForExistence(timeout: 5), "Rename control missing for Banner")
        renameBanner.tap()

        // Pre-filled with the CURRENT title (an edit, not a naming) — select
        // it with a double-tap (one word, "Banner," so this selects the
        // whole thing) and type over it, rather than guessing at a cursor
        // position to backspace from.
        let renameField = app.textFields["Rename field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "Rename field never appeared")
        XCTAssertEqual(renameField.value as? String, "Banner", "Rename field should be pre-filled with the current title")
        renameField.tap()
        renameField.doubleTap()
        renameField.typeText("Flag")

        let saveRename = app.buttons["Save Banner"]
        scrollToHittable(saveRename, in: app)
        XCTAssertTrue(saveRename.exists, "Save control missing after tapping Rename")
        saveRename.tap()
        attachScreenshot(of: app, named: "library-5-renamed-to-flag")

        // Close the Workshop; the Studio must reflect the rename via the
        // existing cover-dismissal reload (StudioView.swift) — nothing
        // reinvented here.
        scrollToTop(app)
        app.buttons["Close"].firstMatch.tap()
        let flagCard = app.staticTexts["Flag"]
        XCTAssertTrue(flagCard.waitForExistence(timeout: 10), "Studio card 'Flag' never appeared after renaming Banner")
        XCTAssertFalse(app.staticTexts["Banner"].exists, "Old title 'Banner' should no longer be in the Studio")
        attachScreenshot(of: app, named: "library-6-studio-shows-flag")

        // Back into the Workshop to remove "Flag" with its inline confirm —
        // starters reseed only into an EMPTY library, so removing one here
        // with other pictures present is permanent (CBNLibrary.seedIfEmpty's
        // own guard; correct parent-zone behavior, not a bug).
        try openWorkshop(app)
        XCTAssertTrue(app.staticTexts["Drawing"].waitForExistence(timeout: 10), "Workshop did not reappear after correct gate entry")

        let removeFlag = app.buttons["Remove Flag"]
        scrollToHittable(removeFlag, in: app)
        XCTAssertTrue(removeFlag.waitForExistence(timeout: 5), "Remove control missing for Flag")
        removeFlag.tap()

        XCTAssertTrue(app.staticTexts["Remove this picture?"].waitForExistence(timeout: 5), "Inline remove confirmation never appeared")
        attachScreenshot(of: app, named: "library-7-remove-confirm")
        // Same "Remove Flag" query re-resolves to the CONFIRM button now
        // that the row swapped state — XCUIElement queries are live, not
        // snapshots, so re-tapping the same reference is correct here.
        scrollToHittable(removeFlag, in: app)
        removeFlag.tap()
        attachScreenshot(of: app, named: "library-8-flag-removed")

        // Close the Workshop; the card must be gone from the Studio.
        scrollToTop(app)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Flag"].waitForExistence(timeout: 5), "'Flag' should be gone from the Studio after Remove")
        attachScreenshot(of: app, named: "library-9-studio-without-flag")
    }

    // MARK: - Shared helpers

    private static let wordToDigit: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    /// Reads WorkshopGateView's dealt words ("Gate words" element's spoken
    /// label) back into the digits they encode.
    private func digits(from wordsText: String) -> [Int] {
        wordsText.split(separator: " ").compactMap { Self.wordToDigit[String($0)] }
    }

    /// Waits for `element` to be enabled, not just present — the import
    /// flow's knob buttons (`ImportFlowView.swift`'s `isRenderingPipeline`
    /// lock, added for Kevin's "how do I know my tap registered" report)
    /// exist the instant the knobs row appears but stay disabled while the
    /// very first inferred preview is still rendering. `waitForExistence`
    /// alone doesn't see that: a tap that lands during that window is
    /// correctly swallowed (that's the lock working), but a test that
    /// doesn't wait for `isEnabled` first would tap into the same silent
    /// no-op a real fast-tapping parent could hit, and read it as broken.
    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens the Workshop door and solves the gate with whatever words it
    /// deals, landing inside the Workshop. `testWorkshopGateAndWidthSetting`
    /// deliberately doesn't use this — it exercises the gate's own
    /// wrong-entry/silent-reset behavior directly — but every other test
    /// that just needs to get past the gate can.
    @MainActor
    private func openWorkshop(_ app: XCUIApplication) throws {
        let doorButton = app.buttons["Workshop"]
        XCTAssertTrue(doorButton.waitForExistence(timeout: 10), "Workshop door never appeared")
        doorButton.tap()

        let gateWords = app.staticTexts["Gate words"]
        XCTAssertTrue(gateWords.waitForExistence(timeout: 10), "Gate did not appear")
        let dealt = digits(from: gateWords.label)
        XCTAssertEqual(dealt.count, 3, "Gate words did not parse to three digits: \(gateWords.label)")
        for digit in dealt {
            app.buttons["\(digit)"].tap()
        }
    }

    /// Scrolls the Workshop's `ScrollView` up in small steps until `element`
    /// is hittable, or gives up after a generous cap. The M4 Pictures
    /// section is a plain (non-lazy) `VStack`, so every row already EXISTS
    /// in the tree the moment the section appears — `waitForExistence`
    /// alone is never the problem here, only on-screen position is, since
    /// XCUITest never auto-scrolls the way a real finger's assistive scroll
    /// would for a `.tap()` on something below the fold.
    @MainActor
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 12) {
        var remaining = maxSwipes
        while element.exists, !element.isHittable, remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
    }

    /// Scrolls the Workshop's `ScrollView` back to its top — used before
    /// tapping the Close control, which can otherwise have scrolled out of
    /// reach after `scrollToHittable` walked down toward a Pictures row.
    /// Over-swiping past the top is a harmless bounce, not an error, so no
    /// hittability check is needed here the way `scrollToHittable` needs one.
    @MainActor
    private func scrollToTop(_ app: XCUIApplication, swipes: Int = 12) {
        for _ in 0..<swipes {
            app.swipeDown()
        }
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

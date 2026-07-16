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

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

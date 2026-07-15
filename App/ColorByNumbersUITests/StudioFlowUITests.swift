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

        // Three taps spread across the artwork: sky (top middle), sea
        // (bottom middle), and a left-side point. Misses are silent no-ops
        // by design, so the screenshot is what proves fills happened.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
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
        // outline — undo removed the sea and side-point fills but left the
        // sky filled, so the sailboat's thumbnail should visibly show a
        // colored sky.
        app.staticTexts["Studio"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Studio grid did not reappear")
        attachScreenshot(of: app, named: "5-studio-after-coloring")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

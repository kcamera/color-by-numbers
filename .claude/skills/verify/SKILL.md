---
name: verify
description: Build, launch, and drive the ColorByNumbers iPad app on a simulator to verify changes at the GUI surface, with screenshot + on-disk evidence.
---

# Verifying ColorByNumbers changes

Two surfaces in this repo:

- **CBNKit / cbnc (CLI)**: `swift build -c release` then drive
  `./.build/release/cbnc import|render|tune|suggest` against `TestArt/`
  and *look at the rendered PNGs* (the Read tool displays them). Always
  use `-c release` — debug is ~30× slower.
- **The iPad app (GUI)**: XCUITest is the driving harness — `simctl` has
  no tap primitive, and idb/cliclick aren't installed.
- **App-side logic (UIKit/PencilKit-dependent)**: `ColorByNumbersTests`, a
  hosted unit bundle (e.g. InkCoverage's pixel measurement) — code that
  can't live in CBNKit's SwiftPM tests because CBNKit must stay
  UI-framework-free. Run with `-only-testing:ColorByNumbersTests`; needs no
  photo seeding and runs in well under a second.

## App drive recipe (works, verified 2026-07-15)

```sh
cd App && xcodegen                       # .xcodeproj is gitignored, always regen
xcrun simctl boot "iPad (A16)"           # if not already Booted (simctl list devices)
rm -rf /tmp/verify.xcresult
xcodebuild -project ColorByNumbers.xcodeproj -scheme ColorByNumbers \
  -destination 'platform=iOS Simulator,name=iPad (A16)' \
  test -only-testing:ColorByNumbersUITests \
  -resultBundlePath /tmp/verify.xcresult
```

The driver lives in `App/ColorByNumbersUITests/StudioFlowUITests.swift` —
extend it (or add siblings) to reach new flows. It captures named
screenshot attachments at checkpoints; keep that pattern.

## Evidence extraction

```sh
# Screenshots out of the result bundle (manifest.json maps names → files):
xcrun xcresulttool export attachments --path /tmp/verify.xcresult --output-path /tmp/shots

# The app's real persisted state (autosave contract evidence):
CONTAINER=$(xcrun simctl get_app_container booted com.kcamera.ColorByNumbers data)
find "$CONTAINER/Documents/Library" -name '*.json'   # items + attempts
```

## Gotchas

- `cd App` first or use paths relative to repo root consistently —
  the project is `App/ColorByNumbers.xcodeproj`.
- A UI-test target needs `GENERATE_INFOPLIST_FILE: YES` in project.yml
  (already set); regen with xcodegen after any project.yml edit.
- `-resultBundlePath` refuses to overwrite: `rm -rf` it first.
- Portrait-simulator screenshots of this landscape-locked app letterbox
  with black bars — cosmetic, not a bug.
- Uninstall the app (`simctl uninstall booted com.kcamera.ColorByNumbers`)
  to reset the library and re-test first-launch seeding.
- UI-test buttons: undo is reachable as `app.buttons["Undo"]`
  (accessibility label), back control via `app.staticTexts["Studio"]`,
  studio cards via their title text.

## Stale test bundle (xcodebuild test runs 0 or N-1 tests)

A test method added moments before `xcodebuild ... test` can silently
miss the compiled bundle — the run reports "Executed 3 tests" (or
`-only-testing:` a new test reports "Executed 0 tests, TEST SUCCEEDED",
which looks like a pass but ran NOTHING). `touch` on the file is not
always enough. Fix: `xcodebuild ... clean` first, then run the suite.
Always check the "Executed N tests" count matches the number of test
methods you expect.

## One simulator, one test run

Never start an xcodebuild test run while another may still be running
against the same simulator — including a background run abandoned by an
interrupted session. Two runners fight over the app: tests die with
"Restarting after unexpected exit, crash, or test timeout" on arbitrary
tests, with NO crash report anywhere (the app never crashed — the other
runner killed it). Before any suite run: `ps aux | grep xcodebuild` and
kill strays. If tests "crash" with no .ips file in
~/Library/Logs/DiagnosticReports, suspect this first.

## EVERY suite run leaves a poisoned app library — uninstall before each

The UI tests assume the freshly-seeded starter library, but several of
them MUTATE it as they run: `testLibraryManagementRenameRestoreRemove`
REMOVES the Banner picture outright (even on a fully PASSING run — it's
the test's finale), and both import tests add items. Seeding is
seed-if-EMPTY, so nothing ever comes back on its own. The next run then
inherits the wreckage: "Banner card never appeared", duplicate "Rainbow
Test" cards matching ambiguously. So: ALWAYS
`xcrun simctl uninstall booted com.kcamera.ColorByNumbers` before a full
suite run (photos stay; only the app container resets). Related trap: a
backgrounded xcodebuild piped through plain `grep` block-buffers — an
"empty" output file does NOT mean no tests ran (a killed "silent" run may
have executed most of the suite); use `grep --line-buffered` or check the
xcresult.

## Two-fixture photo seeding: order matters, and `addmedia` never dedupes

`testImportFlowFromSeededPhoto` and
`testManyColorImportKeepsCanvasControlsReachable` both drive the system
PhotosPicker and pick a photo by GRID POSITION, not by filename — PHPicker
doesn't expose one. Confirmed empirically (screenshot the grid itself if
this ever seems to drift): the grid orders **oldest-seeded first**, NOT
newest-first the way a Recents view would suggest. `firstMatch` =
rainbow-fixture (seeded first, needed by
`testManyColorImportKeepsCanvasControlsReachable`); `.element(boundBy: 1)`
= import-fixture (seeded second, needed by
`testImportFlowFromSeededPhoto` — it needs headroom below the color
ceiling for its own knob taps to do anything, and the rainbow fixture's
inferred count already sits AT that 16-color ceiling, which would make
"More colors" a permanent no-op).

Seed BOTH fixtures, in this exact order, before running the suite:

```sh
UDID=$(xcrun simctl list devices | grep -i "iPad (A16)" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl addmedia "$UDID" App/ColorByNumbersUITests/Fixtures/rainbow-fixture.png
xcrun simctl addmedia "$UDID" App/ColorByNumbersUITests/Fixtures/import-fixture.png
```

**`addmedia` ADDS, it never replaces or dedupes** — calling it again
(e.g. on a later verification pass) adds a SECOND copy, shifting grid
positions and silently breaking both tests' index assumptions. This bit
one session hard: repeated `addmedia` calls across several verification
passes left FOUR duplicate rainbow-fixture copies in the grid, so
`.element(boundBy: 1)` kept landing on a fifth rainbow copy instead of
the flag. Uninstalling the APP (`simctl uninstall`) does NOT touch the
Photos library — only a full `xcrun simctl erase <udid>` (then reboot)
clears seeded photos. Erase before RE-seeding if either test's photo
selection ever looks wrong; don't just addmedia again.

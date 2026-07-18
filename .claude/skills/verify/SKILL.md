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

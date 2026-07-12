# color-by-numbers

A "color by numbers" app that actually works well, for iPadOS.

Calm, kid-first, and honest: no ads, no in-app purchases, no reward loops,
no network — ever. Any picture your family loves becomes art your child
makes herself: source image → color-by-numbers template → finished art.

## Documentation

- [`docs/PLAN.md`](docs/PLAN.md) — the full project plan, milestones, and
  execution protocol.
- [`docs/DESIGN.md`](docs/DESIGN.md) — the design principles that govern
  every screen, sound, and interaction. Read before touching UI/UX.

## Layout

| Path | What it is |
|---|---|
| `Sources/CBNKit/` | Pure Swift core: document model, import pipeline (M1), renderers. Builds on macOS and iOS |
| `Sources/cbnc/` | macOS CLI over CBNKit: import, preview, and the preset tuning workflow (M1) |
| `Tests/CBNKitTests/` | `swift test` from the repo root |
| `Samples/` | Hand-authored and starter templates |
| `App/` | The iPad app (SwiftUI). `project.yml` is the source of truth |
| `docs/` | Plan, design principles, and future collateral |

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
# Core library + CLI (from repo root)
swift test
swift run cbnc Samples/LittleSailboat/template.json

# iPad app
cd App && xcodegen        # regenerate the .xcodeproj (it is gitignored)
open ColorByNumbers.xcodeproj
```

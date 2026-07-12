# Color By Numbers (CBN) — iPadOS App Plan

## Execution protocol — READ FIRST

**HALT after plan acceptance.** When this plan is approved, do NOT begin executing.
Wait for the user's explicit "go." The user may switch models or pace work to fit
a Pro subscription. This rule survives context summarization and session restarts.

**First act of execution (before any other work):** create `docs/` in the repo
and copy this plan into it verbatim as `docs/PLAN.md` — the founding member of
the project's collateral documentation (DESIGN.md joins it in M0). The repo copy
is the durable, git-versioned record; the `~/.claude` plan file is working state.

**Milestone gate — binding on every agent, in every session, forked or future:**
at the end of each milestone, STOP and prompt the user for confirmation. Do not
begin a new milestone without explicit user permission from the current session
— even in Auto mode, even if the next step seems obvious. The user may grant
more than one milestone at a time; permission must be present, never assumed or
carried over. Milestone boundaries are where the user validates and re-aligns
the work.

**Branch & tag workflow:** each milestone is built on a `claude-Mn` branch
(multiple commits welcome; `main` untouched mid-milestone). After the user
accepts the milestone at the gate: merge `--no-ff` into `main`, annotated
tag `Mn` on the merge commit, branch kept alive as a visual ledger. The
user pushes everything himself (see push policy in CLAUDE.md).

Work proceeds **one milestone at a time**, with a check-in at each milestone
boundary. Small commits. The user is a strong engineer with **zero Swift/iOS
experience** — explain iOS/Swift idioms as they first appear, and treat toolchain
steps (signing, provisioning, TestFlight) as hand-holding territory.

### Model handoff hints
The user may hand milestones to Sonnet. Tags used throughout:
- `[sonnet-ok]` — mechanical implementation against a settled spec; guardrails are
  the principles in DESIGN.md, not micro-instructions.
- `[design-sensitive]` — taste and judgment matter (animation feel, algorithm
  tuning, calm aesthetics). Do with a stronger model or with the user closely in
  the loop; if handed to Sonnet, instruct it to implement the mechanism but leave
  tuning constants/curves clearly isolated for later refinement.

The intended guardrail mechanism is **DESIGN.md (created in M0)** — a distilled
principles doc any subagent must read before touching UI or sound. Hint, don't
over-specify: implementation details may evolve; principles do not.

---

## Context

A calm, kid-first color-by-numbers app for iPad, built by a parent for his
5-year-old daughter — and potentially the App Store later. Everything on the
market is riddled with ads, IAP, and stimulation loops. This app's identity:
**transformation** — *any picture your family loves becomes art your child makes
herself*. Source image → CBN template → the child's finished art (the "triptych"
that would be the App Store panels).

The import pipeline is the engine: it is the **only content producer**. There is
no licensed art library and **no genAI artwork, ever**. Premade content = public-
domain flat art run through the same importer. A well-quantized CBN image should
pass through the pipeline roughly unchanged (idempotence as a pipeline sanity
check).

## Locked design decisions (from ideation — do not relitigate)

| Area | Decision |
|---|---|
| Identity | Kid-first coloring experience; transformation is the shared magic; tuning knobs stay in the parent zone |
| Agency | **Parent curates, child creates.** One parental gate at the "workshop" door. Everything kid-side is safe by construction |
| Import v1 | Flat art only (line art, existing CBN pages). Photo import = v2 (same pipeline + pre-processing stages) |
| Import UX | Preset cards ("Simple / Just Right / Detailed") rendered as live thumbnails of the actual image; raw sliders behind an "Adjust…" escape hatch in the workshop. Co-op couch ritual: kid points, parent drives, shared reveal |
| Palette | Fixed, importer-assigned. No palette editing (that's a paint app; out of scope) |
| Canvas modes | 1) Tap-to-fill (toddler) 2) Boundary-assist: strokes clipped to active region (preschool) 3) Freehand over template (elementary) |
| Safety | No destructive actions in kid space: continuous autosave, generous undo, "color it again" creates a new attempt (old attempts kept; parent prunes) |
| Export | Parent-gated: finished art → Photos / AirPrint; **outline + numbered legend → printable PDF** (kids who want paper + real supplies); **cut-and-glue piece sheets** — colored, numbered pieces with cut lines, grouped by color, for gluing onto the blank template ("stickers by numbers" on paper) |
| Rewards | **None.** No stars, confetti, streaks, celebrations. The reward is seeing your art beside the original |
| Sound | No launch sound, no music, no celebration audio. Only soft, unpitched, sub-100ms "material" confirmation sounds (felt/paper/wood — materials, not melodies); parent switch for full silence. iPads have **no haptic engine** — these tiny sounds are the only tactile channel |
| Session limits | Optional, parent-set. **"Sunset" wind-down**: the desk surround around the canvas slowly warms/dims over the final minutes; no countdowns/bars/numbers; finish-your-area grace; calm goodnight screen. Artwork colors never shift — only the room around it. **Must be explained in words**: a small fixed quiet text cue on the desk ("Almost time to rest") with a tiny setting-sun mark for pre-readers — the text explains, the light sets the feeling; otherwise the shift reads as a failing screen |
| Aesthetic | **"Soft analog" craft-table north star**: paper-warm surfaces, a desk the artwork sits on, soft shadows; a subtle pencil-pocket/tray hint along the top edge where the Pencil 2 docks. Dosage rule: *hint at materials, don't cosplay them* — no fake wood grain, stitched leather, or page-curl animations (Procreate/GoodNotes restraint, not 2010 skeuomorphism). North star, not binding pixel spec |
| Orientation | **Landscape only + `requiresFullScreen`** (no Split View / Stage Manager). One layout. Pencil 2 home = top edge, always |
| Network | **Zero network code, ever.** No analytics, accounts, or CDN. Trivializes Kids Category / COPPA; it's a feature |
| Marketing | Never promote importing copyrighted characters ("your favorite pictures", not "favorite characters") |
| Hardware/OS | iPad Air 4 + Apple Pencil 2, family device. Dev on M1 MacBook. Target **iPadOS 17 floor** (18 available; drop to 17 only if free) |

## Architecture

Three targets in one repo:

1. **`CBNKit`** — pure Swift package (macOS + iOS). The heart. Contains:
   - **Document model**: `.cbn` document package (folder): `template.json`
     (vector region boundaries as closed paths, fixed palette, region→color
     assignments, number-label anchor points), source image, `attempts/`
     (per-attempt state: fill map for tap mode, serialized `PKDrawing` for
     drawing modes), metadata.
   - **Import pipeline** (flat art v1): normalize → color quantization (k-means
     or median-cut in Lab space) → connected-component labeling → small-region
     merge (`minRegionArea`) → boundary tracing (marching squares / Moore) →
     path simplification + smoothing (Douglas-Peucker + curve fit) → number
     placement (pole of inaccessibility per region) → emit document.
     Tunables: `colorCount`, `minRegionArea`, `detail`. Presets = named
     parameter bundles. v2 photo stages (edge-preserving smoothing, superpixel
     merge) bolt onto the front later.
   - **Renderers**: template (outlines + numbers), fills, composite; PNG + PDF
     output. The outline+legend paper export is just another renderer over the
     same document, as is the cut-and-glue piece-sheet renderer (numbered
     colored pieces with thin cut lines, grouped by color, simple row-based
     bounding-box packing onto pages).
   - **Presets are data, not code**: a versioned `presets.json` in the repo is
     the single source of truth, consumed by both the app and the CLI.
     Retuning later = regenerate that file; no app-code changes.
2. **`cbnc`** — macOS CLI wrapping CBNKit. Import/tune/preview from Terminal on
   the M1 at night: flags for tunables, writes preview PNGs/PDFs. This is where
   preset defaults get earned, and how the family starter library gets built.
3. **`ColorByNumbers`** iPad app — SwiftUI shell, PencilKit canvas.
   - **Studio** (kid space): library grid (newest first), canvas, mode switch,
     undo. Nothing destructive exists here.
   - **Workshop** (behind parental gate): import flow (PhotosPicker → preset
     triptych → reveal), library management (attempts, delete, rename), export,
     session-limit settings, sound switch.
   - Canvas layering: template outlines+numbers / fills / PKCanvasView drawing
     layer; boundary-assist = clip strokes to active region mask.
   - Parental gate: a standard grown-up gate (e.g., hold two corners / spoken-
     number style); pick a recognized Kids Category-compliant pattern.

## Milestones

- **M0 — Scaffolding + docs** `[sonnet-ok]`
  `docs/PLAN.md` copy (see execution protocol), **project `CLAUDE.md` carrying
  the milestone gate rule** (so every future session loads it automatically,
  plan file or not), repo layout (SwiftPM package +
  Xcode project), `swift test` green with a trivial test, **`docs/DESIGN.md`
  distilling the ideation transcript's principles** (calm rules, agency model,
  sound rules, soft-analog craft-table north star + dosage rule, no-network,
  no-rewards — the subagent guardrail doc), a hand-authored sample
  `template.json`.
- **M1 — Pipeline + CLI + durable tuning workflow** `[design-sensitive: algorithm tuning; mechanics sonnet-ok]`
  CBNKit import pipeline + `cbnc`. Golden-image tests on the committed
  `TestArt/` corpus of public-domain flat art; idempotence check (CBN-like
  input ≈ unchanged output).
  **The preset tuner is a maintained capability, not a one-off**: `cbnc tune`
  is a first-class subcommand — point it at `TestArt/`, give parameter ranges,
  and it emits a **contact sheet** (HTML/PDF grid of results, each cell labeled
  with its exact parameters). Loop: *sweep → look → bless into `presets.json`*.
  Corpus lives in the repo so future tuning sessions (e.g., "the app struggled
  with this image") re-run against the same baseline plus new problem images.
  README documents the loop so future-user or Sonnet can run it cold.
  Exit criteria: presets produce genuinely good templates on flat art without
  touching sliders.
- **M2 — iPad walking skeleton** `[sonnet-ok]`
  Landscape-locked SwiftUI app, bundled starter templates, studio grid,
  **tap-to-fill mode**, continuous autosave. Runs on the real Air 4.
  *Daughter-testable milestone.*
- **M3 — Drawing modes** `[design-sensitive: canvas feel]`
  PencilKit integration: boundary-assist (region-clipped strokes) + freehand;
  undo; finger/Pencil parity; "color it again" attempts model.
- **M4 — Workshop + import on device** `[mechanics sonnet-ok; reveal design-sensitive]`
  Parental gate, co-op import flow with preset thumbnails, the **reveal**
  (slow quiet crossfade — a designed moment, no fanfare), library management.
- **M5 — Export** `[sonnet-ok]`
  Finished art → Photos + AirPrint; outline+legend printable PDF; optional
  **cut-and-glue piece-sheet mode** — pieces carry their number on them (a
  spilled pile stays recoverable); export screen gently suggests it works best
  on simpler templates (add a "piece too small to cut" warning later only if
  needed). Renderers already in CBNKit; this is mostly share-sheet/print
  plumbing.
- **M6 — Calm systems + polish** `[design-sensitive]`
  Session sunset **including the wind-down text cue** ("Almost time to rest" +
  setting-sun mark, fixed position, no motion), the soft material sound set (or
  ship silent if sounds can't be made non-stimulating), app icon, empty states,
  goodnight screen, pencil-pocket hint at the top edge.
- **M7 — App Store track (when/if desired)**
  Kids Category review prep, privacy labels (trivial: no data collected),
  signing/provisioning/TestFlight walkthrough — heavy hand-holding expected.

## Verification

- **CBNKit**: `swift test` — geometry/pipeline unit tests + golden-image
  regression on committed test art; the idempotence property test.
- **CLI**: run `cbnc` against `TestArt/` on the Mac; eyeball PNG/PDF previews.
- **App**: build to iPad Simulator for layout; real Air 4 for touch/Pencil feel
  (feel is not verifiable in the Simulator — user validates M2/M3 in hand).
  Per-milestone acceptance = the milestone's exit criteria demonstrated on
  device, user in the loop.
- **Standing checks**: zero network entitlements/symbols; no destructive action
  reachable from the studio; sound inventory matches the rules in DESIGN.md.

## Out of scope (explicitly)

Photo import (v2), palette editing, any genAI artwork, accounts/cloud sync,
analytics, portrait layouts, rewards of any kind, background music.

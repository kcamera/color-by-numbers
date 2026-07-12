# Color By Numbers — agent instructions

A calm, kid-first color-by-numbers iPad app. Full plan: `docs/PLAN.md`.
Design principles (read before touching UI, sound, or UX): `docs/DESIGN.md`.

## Milestone gate — binding on every agent, every session

Work proceeds by the milestones in `docs/PLAN.md`. At the end of each
milestone, STOP and ask the user for confirmation. Do not begin a new
milestone without explicit permission granted in the current session — even
in Auto mode, even if the next step seems obvious. Permission is never
assumed or carried over; the user may grant several milestones at once.
Likewise, an approved plan is not a go signal: halt after plan approval and
wait for the user's explicit "go."

**Never `git push`.** Agents commit locally; the user pushes himself as his
final sign-off on each stopping point. (His `gh` credential on this machine
is a work account — never use it for this personal repo.)

## Branch & tag workflow

Each milestone's work happens on a branch named `claude-Mn` (e.g.
`claude-M1`), with as many commits as the implementation naturally wants —
`main` stays untouched mid-milestone. At the milestone gate, only after the
user reviews and accepts: merge into `main` with `--no-ff` (every milestone
gets a real merge commit), create an annotated tag `Mn` on that merge
commit, and keep the branch alive as a visual ledger. The user then pushes
`main`, the branch, and the tag himself.

## Non-negotiables (details and rationale in docs/DESIGN.md)

- Zero network code, ever. No analytics, no accounts.
- No rewards: no stars, confetti, streaks, or celebration effects/audio.
- No destructive actions reachable from kid space (the Studio).
- Sound: silence by default; only soft, unpitched, sub-100ms material
  confirmation sounds. No music, no launch sound.
- Landscape only, `requiresFullScreen`. iPad-only, iPadOS 17 floor.
- No genAI artwork. Never market importing copyrighted characters.

## Working notes

- The user is a strong engineer with zero Swift/iOS experience: explain
  Swift/iOS idioms on first use; hand-hold signing/provisioning/TestFlight.
- Build/test: `swift test` at repo root (CBNKit + cbnc are SwiftPM targets).
- iPad app: `App/project.yml` is the source of truth; regenerate the project
  with `xcodegen` from `App/` (the `.xcodeproj` is gitignored).
- Presets are data (`presets.json`), not code. Tuning happens via `cbnc tune`
  contact sheets against the committed `TestArt/` corpus (from M1 on).

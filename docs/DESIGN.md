# DESIGN.md — principles that govern every screen, sound, and interaction

This is the guardrail document. Any agent or contributor must read it before
touching UI, sound, copy, or interaction design. It states principles, not
pixel specs: implementation details may evolve; these principles do not.
When a proposed feature conflicts with this document, the document wins or
the user explicitly amends it — never silently.

## Identity

**Transformation is the magic: any picture your family loves becomes art your
child makes herself.** Source image → color-by-numbers template → the child's
finished art. That triptych is the app's story, its library language, and its
eventual App Store panels. The coloring canvas and the transformation reveal
share top billing; tuning knobs serve them silently from the parent zone.

This is a kid-first coloring experience, not a converter utility and not a
paint app. The palette is fixed and importer-assigned: guiding the child to a
pleasing outcome is the app's function. Palette editing is out of scope.

## The calm contract

The app must be calm, relaxing, and reassuring — as architecture, not as a
coat of paint.

- **No rewards, ever.** No stars, stickers, confetti, streaks, unlocks,
  celebration animations, or celebration sounds. The reward is intrinsic:
  seeing your finished art beside the original. If a design idea's purpose is
  "to make completion feel exciting," it is wrong for this app.
- **No popups, no interruptions, no urgency.** Nothing jumps at the child.
  No modal "are you sure?" dialogs in kid space — safety is structural (see
  agency model), so confirmation anxiety has nothing to guard.
- **No network, ever.** Zero network code, no analytics, no accounts, no
  remote content. Family photos and a child's artwork never leave the device.
  This is a trust feature and it makes Kids Category / COPPA compliance
  near-trivial. Any dependency that phones home is disqualified.

## Sound: materials, not melodies

iPads have **no haptic engine**, so tiny sounds are the only tactile channel.
The rules:

- Silence is the default state. **No launch sound, no music, no ambient
  audio, no celebration audio — ever.**
- The only permitted sounds are soft, unpitched, sub-100ms **material
  confirmations** (felt, paper, wood, a real felt-tip stroke) for direct
  interactions — feedback that says "that happened," never "you did great."
- Pitched/musical sounds (chimes, bells, rising intervals) are prohibited;
  they are reward-circuitry bait.
- Never layered, never louder than quiet, one at a time. Finishing a picture
  makes **no sound at all** — silence frames the moment.
- A parent switch reduces the app to full silence. If a sound cannot be made
  non-stimulating, ship silence instead.

## Agency model: the parent curates, the child creates

One parental gate, at the **Workshop** door. Everything on the child's side
(the **Studio**) is safe by construction:

- **Nothing destructive exists in the Studio.** Not discouraged — impossible.
  Deletion, renaming, resets, export, and settings live in the Workshop.
- **Continuous autosave.** No save button, no prompts; state survives
  anything, including mid-stroke power loss.
- **Generous, always-available undo.** Mistakes are how fine motor skills
  grow; undo is what makes them safe.
- **"Color it again," never "start over."** Re-coloring a template creates a
  new attempt; old attempts remain (parents prune in the Workshop). Attempts
  over months become a visible record of a child's growing motor control.
- **Import is a co-op couch ritual.** Kid points and chooses ("that one!"),
  parent operates the gate and the knobs. New projects appear at the front
  of the Studio library as fresh outlines — zero navigation friction
  between "we made this together" and "go play."

## The transformation experience

*(Amended by the user at the M1 gate, 2026-07-14 — supersedes the original
"preset cards + reveal" ideation. Rationale in docs/PLAN.md.)*

- **Two knobs, live preview.** The Workshop import flow is two dials —
  palette size and smallest-region floor — re-rendering near-instantly as
  the parent ratchets. Starting positions are inferred per image and
  restorable via a reset control. The app never *recommends* (a bad
  suggestion is the app failing; a transient knob state is just driving),
  and good inferred defaults are a hard requirement on the pipeline: not
  touching the knobs must yield a decent template.
- **No reveal.** The old "designed crossfade moment" was front-loaded
  reward stimulus — payoff before any work — and showing the app's filled
  rendering before coloring frames the activity as matching an answer key.
  Filled previews exist only in the Workshop (parent quality control). A
  new page arrives in the Studio as what it honestly is: fresh outlines on
  the desk, no ceremony. The only celebrated moment remains the child's
  finished art beside the original, at the end.
- Templates should err toward big, friendly, colorable regions. A region too
  small for a small finger (or scissors, for the cut-and-glue export) is a
  pipeline bug, not a user error.

## Aesthetic north star: the soft analog craft table

The UI is inspired by a real notebook and craft table: paper-warm surfaces,
a desk the artwork sits on, soft shadows. It aligns with the material sound
palette and the analog intent (including the paper exports for kids who want
real supplies).

**Dosage rule: hint at materials, don't cosplay them.** Paper-warm color and
soft depth, yes. Fake wood grain, stitched leather, page-curl animations, no.
The restraint of Procreate or GoodNotes, not 2010 skeuomorphism.

One sanctioned flourish: a subtle pencil-pocket/tray hint along the top edge
where the Apple Pencil docks (landscape lock makes that location permanent),
quietly teaching the put-the-pencil-away ritual.

## Session wind-down: the sunset

Session limits are optional and parent-set. When enabled:

- Over the final minutes, the desk surround **slowly warms and dims** like
  evening light entering a room. The artwork's colors never shift — only the
  room around it.
- **The shift must be explained in words**: a small, fixed, quiet text cue on
  the desk ("Almost time to rest") with a tiny setting-sun mark for
  pre-readers. The text explains; the light sets the feeling. An unexplained
  color shift reads as a failing screen.
- No countdowns, progress bars, numbers, or motion — those manufacture the
  urgency this feature exists to avoid.
- Time's up = finish-your-area grace, then a calm goodnight screen. Never a
  mid-stroke cutoff.

## Skill ladder: three modes, one document

1. **Tap-to-fill** (toddler): tap a region, it fills with its assigned color.
2. **Boundary-assist** (preschooler): real drawing, strokes clipped to the
   active region — fun without frustration.
3. **Freehand** (elementary): unclipped drawing over the template — fine
   motor practice with training wheels off.

Same document, same canvas, one setting. The app grows with the child.

## Fixed constraints

- Landscape only, `requiresFullScreen`, iPad-only, iPadOS 17 floor.
- Reference hardware: iPad Air 4 + Apple Pencil 2 (Pencil home = top edge).
- No genAI artwork anywhere in the product or its content pipeline.
- Marketing copy never promotes importing copyrighted characters — "your
  favorite pictures," never "your favorite characters."

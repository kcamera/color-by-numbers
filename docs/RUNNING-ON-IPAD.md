# Running the app: Simulator and the real iPad

The hand-holding guide, written for someone with zero prior iOS
deployment experience. Two halves: the Simulator (no signing, no Apple
ID, works immediately) and the physical Air 4 (signing/provisioning).

## Running in the Simulator (no setup beyond Xcode)

1. ```sh
   cd App && xcodegen        # regenerates the gitignored .xcodeproj
   open ColorByNumbers.xcodeproj
   ```
2. In Xcode's toolbar (top center) there are two dropdowns next to the
   ▶ button: the **scheme** (leave it on "ColorByNumbers") and the
   **destination**. Click the destination and pick any iPad under
   "iOS Simulators" — e.g. "iPad (A16)". No iPad listed? Xcode →
   Settings… → Components and download an iOS Simulator runtime.
3. **⌘R**. First launch takes a minute (the simulator boots like a real
   device); after that it's seconds. The app is landscape-only — if the
   simulator window comes up in portrait you'll see the app letterboxed;
   rotate with **⌘→** (Device → Rotate Right).
4. Interact with the mouse: click = tap. Quit the simulator app entirely
   with ⌘Q when done (leaving it running is also fine and makes the next
   ⌘R faster).

Simulator limits worth knowing: no Apple Pencil, no real touch feel, and
performance isn't representative — it's for layout and logic. The feel
test (the one that matters for a 5-year-old) only happens on the device.

# Running on the real iPad (signing, provisioning, deploying)

Everything below is device-only — the Simulator needs none of it.

## One-time setup

### 1. An Apple Developer identity

Two options:

- **Free ("Personal Team")** — sign in with any Apple ID in Xcode. Apps
  installed this way stop launching after **7 days** and must be
  re-deployed from Xcode (fine for testing, annoying for a kid's daily
  driver). Max 3 apps per device.
- **Paid ($99/yr)** — apps last a year per provisioning, TestFlight becomes
  available (M7 territory), and the 7-day nag disappears. Worth it once
  the app is real for your daughter; not needed to start.

Either way: Xcode → **Settings… → Accounts → “+” → Apple ID**, sign in.
You'll see a "team" appear (e.g. "Kevin Camera (Personal Team)").

### 2. Tell the project about your team — in project.yml, NOT in Xcode

The `.xcodeproj` is **gitignored and regenerated** by `xcodegen`, so any
signing setting you click into Xcode's *Signing & Capabilities* tab is
erased on the next regeneration. Signing config belongs in
`App/project.yml`:

```yaml
    settings:
      base:
        # ...existing settings...
        DEVELOPMENT_TEAM: XXXXXXXXXX   # your Team ID
        CODE_SIGN_STYLE: Automatic
```

Find your Team ID in Xcode → Settings… → Accounts → (select the team) —
it's the 10-character string, or shown as "Team ID" on
developer.apple.com/account for paid accounts. Then:

```sh
cd App && xcodegen && open ColorByNumbers.xcodeproj
```

(Committing the team ID to this personal repo is fine — it's embedded in
every app binary you ship anyway.)

### 3. Prepare the iPad (once per device)

1. Plug the iPad into the Mac with a cable (first pairing wants a wire;
   Wi-Fi deploys work after that).
2. On the iPad: tap **Trust** when asked, enter its passcode.
3. Enable **Developer Mode**: iPad Settings → Privacy & Security →
   Developer Mode → on → the iPad reboots → confirm. (This switch only
   appears once Xcode has seen the device at least once.)

## Every deploy after that

1. `cd App && xcodegen` if project.yml changed (harmless to run always).
2. Open `ColorByNumbers.xcodeproj`, select the **ColorByNumbers** scheme,
   and pick the iPad in the destination dropdown (top center of the
   window — it lists as e.g. "Kevin's iPad" once paired).
3. **⌘R**. First time per device+team, the iPad will refuse to launch the
   app until you trust the developer profile: iPad Settings → General →
   VPN & Device Management → tap your Apple ID → Trust.
4. Subsequent runs: just ⌘R (or deploy over Wi-Fi with the cable
   unplugged, as long as iPad and Mac share a network).

## When things get weird

- **"Failed to prepare device / device not eligible"** — Xcode and iPadOS
  versions have drifted apart; update Xcode first, it's almost always that.
- **App icon appears then won't launch (free account)** — the 7-day
  provisioning expired; re-run from Xcode.
- **Signing errors after editing project.yml** — regenerate
  (`cd App && xcodegen`) and clean build folder (⇧⌘K) before retrying.
- **The kid test protocol**: hand her the iPad with the app already
  launched. Watch, don't coach — where she hesitates is M2/M3 feedback.

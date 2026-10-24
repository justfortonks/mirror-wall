# Current focus

What's in progress now, what's next, and what's parked. Update it when a piece of work lands or
the plan changes.

_Last updated: October 22, 2026._

## Current delivery state

October 22: the rebrand landed on `cody-changes` (own look, system light/dark, Connect with QR
Code, Android app ID back to upstream's). The Mac build is installed on Cody's MacBook; the
Android build goes through the Android workflow. Below is the state before that.

`cody-changes` (build 0.141) has the branded Stage-first app, presenter controls,
reconnect grace, optional PIN, Stop Sharing and Freeze Stage, the model-specific frame catalog,
and the upstream photo frames and Android rotation. It builds and passes all tests on the Mac and
is installed on Cody's MacBook Pro. The Android app 0.141 (then `com.imprivata.mirrorwallcast`,
test key) has been built and handed out.

## Completed foundation

- Fork created from justfortonks/mirror-wall; DemoCast retired in favor of it.
- Company branding on the Mac and Android (replaced October 22 by Mirror Wall's own look).
- Stage-first single window; the Wall moved behind Show Wall.
- AI UX and code review pass and its fixes (see [se-handoff.md](se-handoff.md)).
- Presenter keys that work on any keyboard (C, P, Esc, Control or Option).
- Reconnect grace with the held last picture.
- Optional iPhone PIN for events.
- Updates pointed at this fork.
- Freeze Stage and Stop Sharing from the right-click menu and the Devices chip.
- Android app ID changed to `com.imprivata.mirrorwallcast` (reverted October 22; see ADR 0006).
- Upstream merge: photo frames (Zebra HC50, Honeywell CT37, Spectralink Versity 95/96 and 97),
  Android rotation, OBS feeds named after the slot, early-portrait fix.

## Next step

- **Check the rebrand on screen** in both appearances (System Settings › Appearance), then build
  the Android app in CI and reinstall it on one handheld (new app ID: uninstall the old one first).
- **Decide the vocabulary with the upstream author:** grid view "Ensemble", slots "Marks", relay
  "Catwalk" (proposals in the design system). Nothing in the UI changes until that's agreed.
- **Wire the apps to the relay** (`relay/` is deployed at mirror-wall-relay.fly.dev): Settings ›
  Relay on the Mac, `RelayClient` per slot, the code under the QR, `relay=`/`code=` in the
  connect link; Mirror Wall Cast dials the relay when the direct addresses don't answer.
- **Then the iPhone companion app** (Xcode and the Apple account are ready on the Mac mini).
- **Publish the first fork release** (Actions › Release › Publish) so the README download links
  and Check for Update work for the rest of the SE team.

## Parked

- Team signing key for Android (needs uninstall-once on every device when it switches).
- Encrypted, authenticated Android pairing; the PIN currently covers iPhones only.
- Windows parity for the Stage-first window, presenter controls, branding and bezel catalog.
- More photo frames (Samsung, iPhone) if the drawn frames aren't convincing enough in demos.
- Fleet rehearsal from the [checklist](se-handoff.md#verification-and-remaining-rehearsal):
  long sessions, lock/wake timing, MDM install and update on Intune, Workspace ONE and SOTI.

## Working agreements

- `main` is upstream's; all SE work is on `cody-changes`.
- Upstream changes come in on a separate branch, are built and checked on the Mac, then merged.
- Decisions that will matter later get an ADR in `docs/adr/`.

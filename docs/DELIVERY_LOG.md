# Delivery log

What has shipped, summarized from the Git history and [CHANGELOG.md](../CHANGELOG.md). Newest
first. The changelog has the user-facing detail; this is the project view.

## October 24, 2026: The relay, end to end

- `relay/`: a Go byte pump on Fly.io (mirror-wall-relay.fly.dev, TLS at the edge, dedicated IPv4
  and IPv6). Mac: `RelayClient` per slot, Settings › Phones › Relay, code under the QR and on the
  Stage, `relay=`/`code=` in the connect link. Android: joins the relay when no direct host
  answers. Verified through Fly with a test phone: hello, welcome, ping, bye.
- Lesson recorded: a relayed `CastConnection` needs an owner, as `CastServer` owns LAN ones.

## October 24, 2026: Signed Mac builds; QR connect verified on a handheld

- Mac builds signed with a Developer ID (hardened runtime; receiver libraries included); first
  notarization submitted. Release workflow signs and notarizes from secrets when they are set.
- Mirror Wall Cast 0.145 tested on a handheld: Scan QR Code connected to the slot the Mac's code
  named, and picking an open slot from the list still works. Android app ID is upstream's again.
- Mac mini set up as a build machine (Xcode 27.1, JDK 17 and the Android SDK via Homebrew); the
  repo clone lives on the Sidehustle drive.

## October 22, 2026: Own branding, system appearance, QR connect

- Stripped the previous company's branding (palette, Barlow, logo, hex pattern) from the Mac and
  Android apps and docs. New identity from the Mirror Wall Design System (stagecraft direction):
  lamp/gel/hot on house black and scrim cream, Fraunces + Inter, a new icon and menu bar glyph.
- `Brand` now resolves surfaces and ink on the current appearance; the Wall and Settings follow
  the system, the Stage stays dark. Android got `values-night` colors and a DayNight theme.
- Connect with QR Code (Mac: `ConnectLink`, `LocalAddresses`, `ConnectCodePanel`; Android:
  `ConnectLink.kt`, zxing scanner, `mirrorwall://` intent filter, first-address-that-answers).
- Android app ID returned to upstream's `com.justfortonks.mirrorwall.cast` (ADR 0006).
- `docs/relay-design.md`: the AirDroid Cast teardown and the relay options.

## October 16-17, 2026: Upstream photo frames and Android rotation (fork)

- Merged upstream's photo frames for Zebra HC50, Honeywell CT37 and Spectralink Versity 95/96 and
  97 into the fork's Bezel Model picker. Automatic now prefers a photo frame; the HC50 moved from
  its drawn frame to the photo.
- Android phones report how they're held, and frames turn to match. OBS feeds follow slot
  renames.
- Kept updates pointed at the fork. Rebuilt the branded Android app as 0.141.
- Rewrote the README and added product, design, agent, index, focus, delivery and ADR docs.

## October 16, 2026: SE demo reliability and device frames (fork, Cody)

- Explicit Android stop message, Freeze Stage naming with a visible scope reminder, hidden devices
  stay hidden through reconnects.
- Restored the UxPlay idle/wake fix and five-minute screen-off grace for iOS.
- Off-main-thread receiver teardown, single-instance lock, bounded Android send queue.
- Recording reliability: unique names, visible failure and saving states.
- Bezel Model picker with drawn presets for iPhone 12-18 families, SE, e models, Zebra HC50 and
  TC53e, iPad A16; Demo Label…; compact Stage controls.
- Tests for transport, lifecycle, recording and layout; package compatibility checks.

## October 16, 2026: Android branding and app ID (fork)

- Mirror Wall Cast got the Imprivata look (Barlow, Blue, red pill buttons, hex accent).
- App ID changed to `com.imprivata.mirrorwallcast`; still signed with the public test key.

## October 16, 2026: Presenter controls and recovery (fork)

- Freeze Stage and Stop Sharing from the right-click menu, the Devices chip and the P key.
- Reconnect grace: "reconnecting" after 4.5 s of silence, last picture held for 45 s.
- Presenter keys on any keyboard: C to pin, Control or Option to peek, Esc to hide.
- Optional iPhone PIN for events, off by default.
- Check for Update pointed at the fork.

## October 16, 2026: Imprivata branding and Stage-first (fork)

- Imprivata Blue wall, Blue-gradient Stage with hex pattern and caption bar, Barlow font, optional
  white logo kept out of git.
- The Stage became the main window and opens at launch; devices are added to it automatically;
  the Wall moved behind Show Wall.

## October 11-16, 2026: Upstream foundation (justfortonks/mirror-wall)

- **Oct 11:** first version: one AirPlay receiver per iPhone in a grid; pop-out windows for OBS;
  faster disconnect detection and fresh receivers; recording; frame-rate limit and Stats for
  Nerds; Smoother Motion; Sharper Picture (H.265); reliable reconnects; Syphon output.
- **Oct 12:** downloadable releases with a changelog; Windows app; Android phones through Mirror
  Wall Cast.
- **Oct 13:** Settings for OBS and own windows.
- **Oct 14:** stays awake, menu bar / tray icon, phone bezels; Android app on the releases page;
  Check for Update; the Stage window; Beta updates.
- **Oct 15:** Windows fixes; photo frames for Android healthcare devices; Android rotation.
- **Oct 16:** OBS feeds follow slot renames; a list of test builds for Beta.

## Updating this log

When a piece of work lands on `cody-changes`, add a dated section at the top with the outcome,
not the commit list. Keep [CURRENT_FOCUS.md](CURRENT_FOCUS.md) in step.

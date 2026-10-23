# Mirror Wall

Share iPhone, iPad and Android demo devices in a Teams or Zoom meeting from a Mac. Phones mirror
wirelessly into one **Stage** window that you share like any other app window, at their true
relative sizes, in a phone frame that matches the real device. No cables, no cloud: everything
runs on your own Mac.

This repository is developed alongside
[justfortonks/mirror-wall](https://github.com/justfortonks/mirror-wall); the two share the Cast
protocol and exchange changes by pull request. The working branch here is **`cody-changes`**;
`main` tracks upstream and is left alone. The look is Mirror Wall's own: see
[DESIGN.md](DESIGN.md).

---

## What it does

- **Stage-first window** - the app opens straight to the Stage: a single dark window (the devices
  stand in a pool of light, "Live demo" caption bar) showing every mirroring phone. Share that
  one window in the meeting. Phones are added to the Stage automatically as they connect.
- **iPhone and iPad over AirPlay** - nothing to install. Control Center › Screen Mirroring › pick
  a Mirror Wall slot.
- **Android over Mirror Wall Cast** - a small companion app (`com.justfortonks.mirrorwall.cast`)
  that finds the Mac's slots on the network and streams the screen. Works on any Android 10+
  device, including Zebra, Honeywell and Spectralink handhelds.
- **Connect with QR Code** (⌘K) - when the network blocks discovery (guest Wi-Fi, a VPN on each
  device), the Mac shows a code with every address it has; the Cast app scans it and shares to
  the first address that answers. Works over Tailscale.
- **Light and dark** - the Wall, Settings and the Android app follow the system appearance. The
  Stage stays dark in both, because the customer is looking at it.
- **Up to eight devices at once** - iPhones and Android phones mix freely, one device per slot.
- **Device frames** - every device can wear a frame on the Stage, in its own window and in the OBS
  feed:
  - *Photo frames* of the real front for Zebra HC50, Honeywell CT37 (white), Spectralink Versity
    95/96 and Versity 97, picked automatically when the phone reports its model.
  - *Drawn frames* for iPhone 12 through 18 Pro (including mini, Plus, Pro Max, Air, SE and e
    models), Zebra TC53e and iPad (A16 / 11th generation).
  - A **Bezel Model** picker on each device to choose a frame by hand when the model isn't
    recognized.
  - Frames turn with the phone in portrait and landscape. Android phones on the current Cast app
    also report upside-down and which way they're turned.
- **Presenter controls** - hidden until you want them, so the audience sees only phones:
  - **C** pins or unpins the control bar; hold **Control** or **Option** to peek; **Esc** hides it.
  - **P** or **Freeze Stage** holds the Stage on the current picture while you do something
    private on the phone. Recordings, screenshots, own windows and OBS feeds stay live.
  - **Stop Sharing** (right-click a device, or the Devices chip) ends an Android share from the
    Mac.
  - **Demo Label…** changes the caption under a device without renaming it.
  - **On Stage** hides or shows a device; a hidden device stays hidden through reconnects.
- **Reconnect grace** - if a phone drops (Wi-Fi blip, airplane mode), the Stage dims its last
  picture and says *reconnecting* after about 4.5 seconds, and holds its place for 45 seconds
  instead of the layout jumping.
- **Optional PIN for events** - Settings can require a 4-digit PIN before an iPhone can mirror. Off
  by default for home-office demos. The PIN shows on the Stage's waiting screen. It does not apply
  to Android.
- **Stage layouts** - Side by Side, Stacked or Grid, plus **Fit Window to Devices**.
- **Screenshots and recordings** - per device or all at once, saved to
  `~/Documents/MirrorWall/Screenshots` and `~/Documents/MirrorWall/Recordings` (video only, never
  framed).
- **OBS output** - each device can publish straight to OBS through Syphon, framed or unframed, or
  open in its own window titled `MacMirror-<name>` for window capture. The Stage itself is
  `MacMirror-Stage`.
- **Wall view** - the original tiled grid of every slot with status, logs and troubleshooting.
  Open it from **Show Wall** in the Stage's More menu or the menu bar icon.
- **Updates from this fork** - Check for Update looks at
  [yurtbeer/mirror-wall releases](https://github.com/yurtbeer/mirror-wall/releases), never
  upstream, so an upstream release can't overwrite this fork's changes.

Not included: controlling the phone from the Mac, audio, or USB mirroring. DRM-protected video
(Netflix and similar) shows black.

---

## How it works

```
iPhone / iPad ── AirPlay ──▶ uxplay (one per slot, patched) ── RTP over localhost ─┐
                                                                                    ├─▶ Mirror Wall (SwiftUI/AppKit)
Android phone ── Mirror Wall Cast (TCP, H.264) ──▶ CastServer (one port per slot) ──┘     │
                                                                                          ├─ Stage window  (share this)
                                                                                          ├─ Wall window   (grid, status, logs)
                                                                                          ├─ Own windows   (MacMirror-<name>)
                                                                                          ├─ Syphon feeds  (OBS)
                                                                                          └─ Recordings and screenshots
```

Each slot runs its own patched [UxPlay](https://github.com/FDH2/UxPlay) receiver, which forwards
the iPhone's H.264 or H.265 video to the app. The app decodes it once with VideoToolbox and shows
it everywhere it's needed. Android uses a small protocol of its own, described in
[docs/mirror-wall-cast.md](docs/mirror-wall-cast.md).

| Slot | AirPlay ports | Android Cast port |
|------|---------------|-------------------|
| 1    | 7300-7302     | 7350              |
| 2    | 7400-7402     | 7450              |
| n    | 7200+100n …   | 7250+100n         |

### Repository structure

```
mirror-wall/
├── Sources/
│   ├── MirrorCore/          # Platform-free logic: bezels and presets, Stage layout, Cast protocol,
│   │                        #   RTP/H.264 parsing, session policy, release lookup, changelog
│   └── MirrorWall/          # The Mac app
│       ├── StageWindow.swift        # The branded Stage, presenter controls, keys
│       ├── Views.swift              # The Wall grid and each slot's ⋯ menu
│       ├── Slot.swift / SlotStore.swift   # Per-slot receiver, state, reconnect grace, PIN
│       ├── CastServer.swift         # Android Cast receiver
│       ├── PhoneBezelDrawing.swift / PhoneBezelView.swift / BezelModelPicker.swift
│       ├── SyphonFeed.swift         # OBS output
│       ├── Brand.swift              # colors (light/dark), Inter and Fraunces, the mark
│       └── Resources/               # App icon, Brand (fonts; logo kept out of git), Bezels (photo frames)
├── Tests/                   # MirrorCoreTests and MirrorWallTests (swift test)
├── android/                 # Mirror Wall Cast (Kotlin), app ID com.justfortonks.mirrorwall.cast
├── windows/                 # Upstream Windows app (C#/WPF); not updated for the SE changes
├── patches/                 # UxPlay patches the receiver needs (idle/wake and others)
├── scripts/                 # build-uxplay, build-syphon, build-app, make-dmg, compatibility checks
└── docs/                    # Project docs; start at docs/PROJECT_INDEX.md
```

---

## Installing

**Releases:** the fork has not published a release yet, so the download links below will work only
after the first one. Until then, build from source (next section) or get a build from Cody.

| Platform | Download | Requirements |
|---|---|---|
| macOS | [MirrorWall.dmg](https://github.com/yurtbeer/mirror-wall/releases/latest/download/MirrorWall.dmg) | Apple Silicon; the minimum macOS is set from the bundled libraries (see `Contents/Info.plist`) |
| Android | [MirrorWallCast.apk](https://github.com/yurtbeer/mirror-wall/releases/latest/download/MirrorWallCast.apk) | Android 10 or later |

**Mac:** drag Mirror Wall to Applications. It's ad-hoc signed and not notarized, so the first open
may need System Settings › Privacy & Security › **Open Anyway**. Allow local-network access when
asked.

**Android:** install the APK or push it through MDM (Intune, Workspace ONE, SOTI). The app ID is
`com.justfortonks.mirrorwall.cast`, the same as upstream's, so there is one Mirror Wall Cast on a
device whichever repo built it. Builds use the repository's public test key until a team key is
set up; each build installs over the last as long as the key doesn't change.

### Connecting devices

Keep the Mac and the phones on the same network with device-to-device traffic allowed.

- **iPhone or iPad:** Control Center › Screen Mirroring › choose a Mirror Wall slot. Enter the PIN
  if the Stage shows one.
- **Android:** open Mirror Wall Cast, tap a slot, approve Android's screen-sharing prompt. If no
  slots appear (multicast blocked), type the Mac's address and the slot's Cast port.

---

## Running locally

Mac (Xcode command-line tools, Homebrew, and Apple's Metal Toolchain for Syphon):

```sh
brew install cmake pkgconf libplist openssl@3 gstreamer
xcodebuild -downloadComponent MetalToolchain
scripts/build-uxplay.sh      # patched receiver; all patches are required
scripts/build-syphon.sh      # optional, for OBS output
scripts/build-app.sh         # builds MirrorWall.app
scripts/make-dmg.sh          # optional disk image
```

Inter and Fraunces (both OFL, licenses alongside) and the menu bar glyphs live in
`Sources/MirrorWall/Resources/Brand`; `scripts/build-app.sh` copies the folder into the app. The
app icon is `Sources/MirrorWall/Resources/AppIcon.png`, rendered from the design system's mark.

Android (Java 17, Android SDK 35):

```sh
cd android
export MIRROR_WALL_BUILD=$(git rev-list --count HEAD)
./gradlew --no-daemon assembleRelease
# APK: android/app/build/outputs/apk/release/app-release.apk
```

More detail: [Building the Mac app](docs/building-mac.md) and the
[SE handoff and test checklist](docs/se-handoff.md).

## Validating changes

Run the smallest relevant set before pushing:

```sh
swift build && swift test
bash scripts/tests/test-uxplay-idle.sh build/UxPlay           # receiver idle/wake patch
python3 -m unittest discover -s scripts/tests -p 'test_*.py'  # packaging scripts
cd android && ./gradlew --no-daemon assembleRelease
```

Offscreen previews of every frame and layout:

```sh
MIRRORWALL_REVIEW_RENDERS=/tmp/mirror-wall-previews swift test --filter VisualReviewTests
```

Before a big demo, rehearse on the real devices: see the checklist at the end of
[docs/se-handoff.md](docs/se-handoff.md).

---

## Configuration

Everything is in **Settings** (Stage › More › Settings…, or ⌘,):

| Setting | Default | Notes |
|---|---|---|
| Require a PIN to mirror an iPhone | Off | For events. Restarts the slots. New PIN generates another code. |
| Who can mirror | Off (any iPhone) | Allow-list phones that have mirrored before. |
| Phone bezels | Off | Frame every slot; each device can still override. |
| Standby picture | Waiting message | Or blank, or your own image. |
| Save to | `~/Documents/MirrorWall/…` | Folders for recordings and screenshots. |
| Send every slot to OBS (Syphon) | Off | Needs a build with Syphon. |
| Keep the Mac awake while mirroring | On | |
| Show in the menu bar | On | |
| Updates | Releases (Stable) | Beta also lists test builds. |

Stage-only toggles (More menu): Caption Bar, Logo in Caption, Device Bezels, Layout.

Android signing for a team key, set outside the repository: `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Switching from the test key
to a team key means uninstalling the app once on every device.

## Releases and updates

Releases are published from GitHub Actions on this fork: **Actions › Release › Run workflow** with
**Publish** ticked builds the Mac DMG, the Windows installer and the Android APK and publishes
`v0.<build number>`. The build number is the commit count, so versions always go up. Add a line to
[CHANGELOG.md](CHANGELOG.md) for anything people will notice; the About box and release notes come
from it.

---

## Limitations

- Android's connection is plain TCP and isn't encrypted; use a trusted demo network. The PIN only
  covers iPhones.
- iOS can end a sharing session on its own after the screen has been off a while. The Mac holds
  screen-off sessions for up to five minutes; after that, wake the phone and reconnect.
- Windows doesn't have the Stage-first window, presenter controls, branding or bezel catalog.
- Performance depends on the network and how many devices are streaming. 60 fps is a maximum, not
  a promise.

## Project guidance

- [Project index](docs/PROJECT_INDEX.md) is the entry point for current work, history, decisions
  and how-tos.
- [Current focus](docs/CURRENT_FOCUS.md) is what's being worked on now and what's parked.
- [Delivery log](docs/DELIVERY_LOG.md) summarizes what has shipped, fork and upstream.
- [Product context](PRODUCT.md) covers who it's for, the demo workflows, principles and anti-goals.
- [Design context](DESIGN.md) covers the look, Stage layout and presenter-control
  rules.
- [Agent guidance](AGENTS.md) gives instructions for coding agents and contributors.
- [Mirror Wall in detail](docs/details.md) covers how each Mac feature behaves.
- [Mirror Wall Cast protocol](docs/mirror-wall-cast.md) is the Android wire format and its
  compatibility rules.

## Fork rules: don't break these

- **Updates point at this fork.** The release URLs in `Sources/MirrorCore/LatestRelease.swift`
  must stay on `yurtbeer/mirror-wall`. Watch for this on every upstream merge.
- **Android app ID stays `com.justfortonks.mirrorwall.cast`.** Changing it makes every device
  install a second app.
- **The look is Mirror Wall's own.** No company marks, fonts or colors in either app; changes go
  through `Brand.swift`, `Brand.kt` and the design system together.
- **Don't commit to `main`.** It mirrors upstream. Bring upstream changes into `cody-changes` on a
  separate branch first, build and test on a Mac, then merge.

## License

GNU GPL v3, same as upstream ([LICENSE](LICENSE)). See [Third-party notices](THIRD_PARTY_NOTICES.md)
for UxPlay, GStreamer, Syphon, Inter and Fraunces. Not affiliated with Apple; AirPlay and iPhone
are Apple trademarks.

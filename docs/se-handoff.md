# SE demo handoff

This fork is an internal SE demo tool for home offices and events. The working branch is
`cody-changes` in <https://github.com/yurtbeer/mirror-wall>. Use the fork's release assets;
upstream releases do not contain these changes. Source changes alone do not publish a release.

## Build

Mac: use Xcode with its command-line tools, Homebrew, and Apple's Metal Toolchain for OBS.
From the repository root:

```sh
brew install cmake pkgconf libplist openssl@3 gstreamer
xcodebuild -downloadComponent MetalToolchain
scripts/build-uxplay.sh
scripts/build-syphon.sh
swift test
bash scripts/tests/test-uxplay-idle.sh build/UxPlay
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
scripts/build-app.sh
# Optional disk image:
scripts/make-dmg.sh
```

Use the receiver built from this checkout: all four patches are needed. An unrelated Homebrew
or older receiver binary will not contain the idle/wake fix. The built app carries its receiver,
libraries and Syphon. Package checking sets the minimum OS from every embedded Mach-O; a local
build may require a newer macOS than CI's macOS 26 build. Check `Contents/Info.plist` or run
`python3 scripts/bundle-compatibility.py MirrorWall.app`. Do not lower that requirement by hand.

The optional white logo is deliberately not tracked. Place the approved asset at
`Sources/MirrorWall/Resources/Brand/imprivata-logo-white.png` before building if needed.
Barlow fonts and their license are included. Store build outputs on Sidehustle when keeping
local disk usage down; the installed app can run without the source/build folder mounted.

Android: Java 17, Android SDK 35 and the checked-in Gradle wrapper:

```sh
cd android
export MIRROR_WALL_BUILD=$(git rev-list --count HEAD)
./gradlew --no-daemon testReleaseUnitTest assembleRelease
```

APK: `android/app/build/outputs/apk/release/app-release.apk`. Application ID:
`com.imprivata.mirrorwallcast`. This is a different installation identity from the upstream
companion and from the original DemoCast pilot. EMM assignments must target the new identity.
By default builds use the documented public test key. For team-managed signing set
`ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
`ANDROID_KEY_PASSWORD` outside the repository; match the deployed key for in-place updates.
Do not commit those values or the private key. A signed AAB can be built with `bundleRelease`.

## What changed in the review pass

| Review | Implementation |
| --- | --- |
| R1 Stop reconnects Android | Explicit `0x83` stop message, per-share identity and a legacy retry cooldown; updated companion ends capture |
| R2 Pause/output mismatch | Renamed Freeze Stage, visible scope notice; snapshot associated with device identity |
| R3 iOS idle/wake | Patched HTTP control loop; app owns liveness; screen-off iOS silence grace is 300 seconds; lock-screen frames do not count as resume |
| R4 Teardown race/stalls | Asynchronous transport/process draining, generation checks on queued work, decoder callback drain before reset |
| R5 Second app copy | Running-copy detection and process-owned file lock before orphan cleanup |
| R6 Android permissions | Pending destination, typed fields and permission-step state saved/restored across activity recreation |
| R7 Sender leaks | Bounded closeable outbox, guaranteed wakeup/close on every exit, 15-second post-welcome read deadline |
| R8 Recording | UUID file naming, visible failure/armed/saving states, shared tracking of outstanding finalization before normal quit |
| R9 Wall contrast | Explicit dark SwiftUI environment and readable semantic foreground colors on the branded surface |
| R10 Stage overflow | Compact Devices / Freeze Stage / More controls; scrolling waiting receivers |
| R11 Hidden phone reappears | Saved Stage visibility no longer overridden by a reconnect |

## Presenter controls

Press **C** to pin/unpin Stage controls, or hold **Control/Option** to reveal them. **P** toggles
Freeze Stage. In a narrow window or with many devices, **Devices** contains per-device actions;
**More (…)** contains layout, recording, bezels, screenshots, Wall and settings.

**Freeze Stage affects only the Stage picture.** Recordings, saved screenshots, pop-out windows
and independent OBS/Syphon sources remain live. Capture the Stage if you want the freeze in the
meeting output. Do not use this control as a privacy shield for those other outputs.
A freeze survives recovery for the same device and clears when a different device takes its slot.

**Stop Sharing** ends capture on an updated Android companion. A fresh Share action can start
again immediately. Older companions lack the stop message/share ID; the Mac refuses their
automatic retry for 70 seconds, during which they may show the stopped-sharing explanation.

**Demo Label…** sets a local caption without changing the device identity, receiver name or OBS
window identity. Hiding a device is persistent presenter intent; reconnecting does not reveal it.

## Bezels

Device menu → **Bezel Model** (also in Wall → More → Phone Bezel). Choose **Automatic** or an
explicit model; turn frames on using the bezel toggle. The choice persists per receiver slot,
including its independent OBS frame. Manual choice is useful when the phone reports an unknown
model code. An explicit model remains selected when replacing the device; reset to Automatic
when repurposing the slot.

Catalog: iPhone 12/13/14/15/16/17 variants, iPhone Air, SE generations 1–3, 16e/17e, 18 Pro/Pro Max,
Zebra HC50, Zebra TC53e, iPad A16/11th generation, and a generic phone. Newer iPhones whose AirPlay
model code is not mapped require manual selection. Both portrait and landscape are supported.
Frames are illustrative vector silhouettes, not photographic replicas. Source video keeps its
aspect ratio; a mismatched manual preset adds frame space instead of stretching the content.

Reference dimensions/model names: [Apple iPhone identification](https://support.apple.com/en-mide/108044),
[Apple iPad A16 specifications](https://support.apple.com/en-us/122240), and
[Zebra TC53e specifications](https://www.zebra.com/gb/en/products/spec-sheets/mobile-computers/handheld/tc53e-tc53e-rfid-tc58e.html).

## Verification and remaining rehearsal

Automated coverage includes core parsing/layout, actual TCP stop delivery, slow UDP callback
shutdown, stale lifetime rejection, screen-off grace, freeze identity, file-lock ownership,
recording collisions/rotation/playability, configuration compatibility and both bezel orientations.
The socket fixture exercises the actual patched UxPlay loop at 1, 61 and 299 seconds of simulated
inactivity. Optional offscreen previews:

```sh
MIRRORWALL_REVIEW_RENDERS=/tmp/mirror-wall-previews swift test --filter VisualReviewTests
```

Before a major demo, still run these on the actual managed fleet:

1. Samsung + Zebra + iPhone for 30–60 minutes; add iPad and rotate devices independently.
2. iPhone/iPad lock and wake at 15 seconds, 61 seconds, 5 minutes and 10 minutes, on charger and
   battery. After five minutes of complete silence the app may restart the receiver. iOS can
   terminate sharing independently; verify fresh video after wake, not merely a retained image.
3. Stop Android from the Mac, then start a fresh Share. Hide/freeze a phone and interrupt Wi-Fi;
   confirm recovery preserves intent. Replace a frozen phone and confirm its old image clears.
4. Rotate/background the Android app while each system permission screen is open; approve and
   check the chosen destination. Reconnect repeatedly and test a silently blocked network.
5. Inspect Stage capture, pop-out, Syphon, screenshots and recordings while Stage is frozen.
   Confirm the audience output uses the route you intended.
6. Record two identically named phones, rotate, stop and immediately quit; inspect saved movies.
7. Validate a second app launch, Mac sleep/wake and external monitor removal.
8. Validate Intune, Workspace ONE and SOTI installation/update with the actual signing identity,
   OS versions, capture policies and background restrictions for Samsung/Zebra/Honeywell.

Android still uses plain TCP and self-reported device IDs. Use a dedicated/trusted SE demo
network. AirPlay's event PIN does not secure Android. Authenticated encrypted Android pairing
and managed configuration were not added in this pass. Windows presentation/recording parity
has not been implemented or validated; the updated Android companion retains version-1 framing.

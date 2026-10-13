# Mirror Wall

A personal macOS app that shows several iPhones' screens on a Mac at once, over Wi-Fi, using
the iPhone's built-in **Screen Mirroring** (AirPlay). Nothing needs to be installed on the
phones. View only: the Mac can't control the phones.

Each tile is a "slot": its own AirPlay receiver that one iPhone mirrors to. The app starts two
slots ("Mirror Wall 1" and "Mirror Wall 2") and you can add up to eight.

## Download

**[Download MirrorWall.dmg](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWall.dmg)**
(the newest release; all of them are on the [Releases](https://github.com/justfortonks/mirror-wall/releases)
page). Open it, drag **Mirror Wall** to Applications, then follow "Install on another Mac" below
from step 2. It needs an Apple Silicon Mac with macOS 26 or later.

For Windows, **[download MirrorWall-Setup.exe](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWall-Setup.exe)**
and see [windows/README.md](windows/README.md).

Releases are built on GitHub's machines by `.github/workflows/release.yml`: in the Actions tab
pick **Release › Run workflow** with Publish ticked. It builds UxPlay with this repository's
patches, Syphon and the Mac app on a Mac, and the Windows installer on Windows
(`.github/workflows/windows.yml`), and makes a release `v0.<build number>` with the DMG, the
installer and the UxPlay source attached.

## How it works

The AirPlay protocol work is done by [UxPlay](https://github.com/FDH2/UxPlay) (GPLv3), run as
a separate `uxplay` process per slot, each with its own name, ports and device ID (one uxplay
instance only accepts one phone at a time). Instead of letting uxplay draw its own window, each
process forwards the decrypted H.264 video over RTP to a localhost UDP port (`-vrtp`). The app
reassembles the frames, decodes them once with VideoToolbox, and shows each picture through an
`AVSampleBufferDisplayLayer` in the slot's tile and in its own window, if open.

Frames are shown as they arrive (`-vsync no`). With UxPlay's default timestamp sync, testing
showed the picture freezes for good after a phone sleeps and wakes; without it, it recovers.

| Slot | Name shown on the iPhone | AirPlay ports | Video RTP port (localhost) |
|------|--------------------------|---------------|----------------------------|
| 1    | Mirror Wall 1            | 7300–7302     | 5600                       |
| 2    | Mirror Wall 2            | 7400–7402     | 5602                       |
| n    | Mirror Wall n            | 7200+100n …   | 5598+2n                    |

The Mac's own AirPlay Receiver (port 7000) can stay on; it doesn't conflict.

## Install on another Mac

Download the DMG (above), or build it yourself: `scripts/make-dmg.sh` builds `MirrorWall.dmg`,
a disk image holding the complete app: it carries its own uxplay and the parts of GStreamer uxplay needs, so the other Mac needs nothing installed
(no Homebrew, no Xcode).

1. Copy `MirrorWall.dmg` to the other Mac, open it and drag **Mirror Wall** to Applications.
2. Open it. The app is signed ad hoc, not by a registered developer, so macOS blocks the first
   launch: go to System Settings › Privacy & Security, find the message about Mirror Wall and
   click **Open Anyway**. This is needed once per Mac.
3. When macOS asks whether Mirror Wall may find devices on the local network, allow it.

The packaged app runs on the same kind of Mac and macOS version (or later) as the one that built
it: the libraries inside come from that Mac's Homebrew. Built on an Apple Silicon Mac with
macOS 27, it needs Apple Silicon and macOS 27.

## Requirements for building

- macOS 14 or later, Xcode (or the Swift toolchain).
- A `uxplay` build that supports `-vrtp` (UxPlay 1.72 or later). Homebrew has no UxPlay
  formula; `scripts/build-uxplay.sh` builds the exact one releases use (UxPlay at a fixed commit
  with all three patches below) into `build/UxPlay/build/uxplay`, after
  `brew install cmake pkgconf libplist openssl@3 gstreamer`.
  Run from the checkout, the app looks for it in `/opt/homebrew/bin`, `/usr/local/bin` and
  `~/Documents/Claude Code/casting app/UxPlay`, or you can pick it with **File › Choose uxplay…**.
  `scripts/build-app.sh` looks in the same places, or takes `UXPLAY=/path/to/uxplay`.
- For the latency figure in Stats for Nerds, build uxplay with
  `patches/uxplay-latency-report.patch` (`git apply` it in the UxPlay checkout, then rebuild).
  It makes uxplay report one frame's timing a second at `-d 1`, converting the phone's frame
  timestamp with uxplay's clock-sync offset. Unpatched, uxplay only reports latency in its full debug
  mode (which also dumps every packet), and in UxPlay 1.74 that report always reads 0. Everything
  else works without the patch.
- For Smoother Motion, build uxplay with `patches/uxplay-frame-timestamps.patch` too. With
  `-vsync no`, uxplay otherwise forwards frames unstamped, so their RTP timestamps say when they
  reached the Mac rather than when the phone captured them. The patch stamps each frame with the
  phone's capture time (counted from the first frame); the app's `udpsink sync=false` still sends
  every frame on at once. Without the patch, Smoother Motion has nothing to pace frames by and
  shows them as they arrive.
- Build uxplay with `patches/uxplay-quiet-crash.patch` as well. In H.265 mode uxplay sometimes
  crashes as a phone disconnects, and macOS then puts up a "uxplay quit unexpectedly" dialog,
  possibly in front of what OBS is capturing. With the patch a crashing uxplay exits quietly
  (it logs that it crashed); the app starts a fresh one either way.

## Build and run

```sh
swift test                 # unit tests for RTP parsing and H.264 reassembly
swift run MirrorWall       # run straight from the checkout, using the uxplay on this Mac
scripts/build-app.sh       # build MirrorWall.app (ad-hoc signed) with uxplay and GStreamer inside
scripts/make-dmg.sh        # the same, packed into MirrorWall.dmg for another Mac
```

`scripts/bundle-receiver.py` does the packaging: it copies uxplay, eight GStreamer plugins and
the libraries they load into `MirrorWall.app/Contents/Resources/receiver`, and rewrites their
load paths so they find each other there instead of in Homebrew. Three of the plugins (libav,
playback, autodetect) are there only because uxplay won't start without them. The app runs that
uxplay with GStreamer pointed at those plugins alone. It also copies each bundled library's
licence files into `receiver/licenses`.

Each build of MirrorWall.app is numbered by the commits it was built from (0.61, 0.62…), and
Mirror Wall › About Mirror Wall also shows the commit (linked) and when it was built, so two Macs'
copies can be told apart, and what changed in that build. Changes are listed in `CHANGELOG.md`:
add an entry there with any change people will notice; it also starts each release's notes.

Then on each iPhone: Control Center › Screen Mirroring › pick a slot's name. The iPhones must
be on the same Wi-Fi as the Mac. If macOS asks to allow incoming connections or local network
access, allow it.

## Using it

- Double-click a tile (or use its ⋯ menu) to show only that phone; do it again to go back.
- Right-click an empty part of the wall to add a slot (or use the + in the toolbar).
- **Own window (for OBS):** the arrow button in the top right corner of a tile's picture (it points back in while the window is open),
  or the ⋯ menu's **Open in Own Window**, puts that phone in a window of
  its own that shows only the picture, sized to the phone's shape. The tile keeps showing it too.
  Their size is set in View › Pop-out Window Size (or the window's own right-click menu), so an
  OBS layout never shifts: Small, Medium or Large, or Custom, where each window keeps a size of
  its own. The presets show phones at their real relative sizes: an iPhone 17 Pro Max's window is
  600, 800 or 1000 points along its longer side, and a smaller phone's is smaller in proportion to
  its screen (an iPhone SE's about two-thirds as tall). A model the app doesn't know gets the full
  size. With Custom, untick
  Lock Custom Size, drag the windows to the sizes you want (each slot's is remembered), then tick
  it again. A window always takes its phone's shape, so it turns wide if the phone rotates.
  The window is titled `MacMirror-<phone name>` (the slot's name until a phone has connected),
  and keeps that title after the phone disconnects, so an OBS Window Capture source finds it
  again. If two phones have the same name, the slot number is added (`MacMirror-iPhone-2`); giving
  each phone its own name in Settings › General › About avoids that. The window's buttons appear
  when the pointer is over it. Open windows stay closed when the app next starts, unless
  Settings › Reopen slots' own windows is on; then they come back where they were. OBS captures the window even behind other windows. It can't capture a minimized
  window, so these windows have no minimize button; leave them behind other windows instead.
- **Send to OBS (Syphon):** a tile's ⋯ menu can also send that slot's picture straight to OBS,
  remembered per slot. Settings › Send every slot to OBS turns it on for every slot, including
  ones added later; a slot's menu can still turn its own off. In OBS add a **Syphon Client** source and pick `[Mirror Wall] MacMirror-<phone
  name>` (the same name as the slot's own window). It gets every frame directly at the stream's
  full size, with no window needing to be open, even with Mirror Wall minimized. While the phone
  is away it shows the slot's standby picture, sized like the phone's picture. The tile shows a small broadcast icon while it's on. Window capture works as before; use
  whichever suits a scene. Needs the app built with Syphon (`scripts/build-syphon.sh`, which needs
  Xcode's Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`); without it the menu
  item doesn't appear.
- **Slot names:** new slots are named "Mirror Wall 1 · MacBook Air": the Mac's name without its
  owner, shortened to 14 characters at a word, so two Macs' slots can be told apart on the phone
  while staying distinct from the Mac's own AirPlay receiver (which uses the Mac's full name).
  Slots still on a name an earlier version gave them take the new one. Rename (⋯ menu) sets any name up to 30 characters, and
  restarts that slot; Use the Mac's Name goes back to the default.
- **Standby picture:** what a slot shows while no phone is mirroring: the waiting message
  (default), blank black, or an image of your choice, scaled to fit with black bars if its shape
  differs (a copy is kept in `~/Library/Application Support/Mirror Wall/Standby`). Settings sets it
  for all slots; a slot's ⋯ › Standby Picture can give that slot its own. It shows in the slot's
  own window and in its tile, whose footer still gives the status.
- **Record button:** the circle button in a tile's footer starts and stops that slot's
  recording, the same as ⋯ › Start Recording.
- **Screenshots:** the camera button in a tile's footer (or ⋯ › Take Screenshot, or File ›
  Screenshot All Slots) saves the picture at the stream's full size as a PNG in
  `~/Documents/MirrorWall/Screenshots`.
- **Settings** (the gear in the toolbar, or Mirror Wall › Settings):
  - *Who can mirror:* off by default, so any iPhone on the network can mirror. Turned on, only
    the ticked phones can (uxplay's `-restrict` and `-allow`). Phones are listed once they've
    mirrored to this Mac. Changing it restarts the slots.
  - *Save to:* the folders for recordings and screenshots (Documents › MirrorWall › Recordings
    and Screenshots by default). A chosen folder that can't be reached, such as an unplugged
    drive, falls back to the default, and Settings says so.
  - *Alerts:* the Dock icon bounces when a mirroring phone drops, until Mirror Wall is clicked.
- The ⋯ menu also has Restart, Show Log and Remove Slot. Each slot's log is also written to
  `~/Library/Logs/MirrorWall/slot-N.log`.
- The tile footer shows the phone's name and its state: Waiting, Connecting, Live, Screen off or
  Disconnected. Next to Live is how long the phone has been connected; next to Screen off is
  how long the screen has been off.
- **Screen off:** when an iPhone's screen turns off, its tile keeps the last picture and says
  Screen off. A locked phone whose screen lights up (button, notification) shows its lock
  screen live. iOS itself ends Screen Mirroring after about a minute with the screen off; the tile then says
  Disconnected, and the phone has to pick the slot again in Screen Mirroring (only the phone can
  start AirPlay). A phone on a charger may just go quiet instead of ending the session;
  the tile says Disconnected once it has gone 10 seconds without checking in.
  After any disconnect the slot restarts its receiver (uxplay sometimes fails to restart its
  video output on its own), so the slot's name disappears from Screen Mirroring for a second or two. To keep a phone on the wall, set Auto-Lock to Never and keep it charging.
- **Stats for Nerds** (View menu, ⌥⌘I, or a tile's ⋯ menu) puts each stream's numbers over its
  tile in the main window; the slots' own windows stay clean for OBS. It shows the phone model and
  codec, picture size, frames and bitrate per second, latency, network round trip, frame jitter,
  keyframes, losses, and the phone's check-ins. **Lag vs best** compares each frame's arrival
  with the phone's timestamp for it, relative to the best this connection has seen: it reads
  about +0 ms and rises if the stream falls behind. The absolute phone-to-Mac delay can't be read
  from the timestamps, which run ahead of the Mac's clock by a fixed amount that differs per
  phone (60–100 ms in testing). **Decode** is the Mac's time from a frame arriving to it going on
  screen. iOS only sends frames when the screen
  changes, so a still screen shows few frames per second. Losses are packets dropped between
  uxplay and the app; the phone's own connection to the Mac is TCP and doesn't lose any.
- **Recording:** a tile's ⋯ menu has Start Recording (File › Record All Slots, ⇧⌘R, does every
  slot). Recording starts at once with the picture on screen and writes to `~/Documents/MirrorWall/Recordings`.
  It records the pictures decoded for the tile and compresses them again with the Mac's video
  encoder (H.264), because the phone's own video can only be copied from a keyframe, and an
  iPhone sends one only when mirroring starts, the screen wakes or it rotates. Frames are timed
  from the stream's timestamps where it has them rather than their bursty arrival. The tile
  shows ● REC and the time. A recording carries on across disconnects and reconnects, starting
  a new file ("… part 2") each time, and also when the phone rotates. Video only: the receivers
  run without audio. Quitting the app finishes any recording properly.
- **Frame rate:** View › Frame Rate Limit asks phones for at most 30 (uxplay's default) or 60
  frames a second. A phone may still send fewer. Changing it restarts the receivers, so phones
  have to reconnect. 60 roughly doubles the data while the screen is busy.
- **Smoother Motion** (View menu, remembered, off by default): Wi-Fi delivers frames in bursts
  (two within 2 ms, then a 47 ms gap), which shows as slight judder in fast scrolling. With this
  on, each picture waits a moment and is shown at the pace the phone captured it: about a tenth
  of a second beyond the quickest recent trip from the phone. A frame that arrives later than that
  is shown at once. The extra delay is the cost, so leave it off where the lowest lag matters.
  Recordings and screenshots are unaffected.
- **Sharper Picture (H.265)** (View menu, remembered, off by default): offers phones H.265 at up to
  3840×2160 instead of H.264 at 1920×1080. In portrait that doubles the picture each way: an
  iPhone 17 Pro Max sends 994×2160 instead of 498×1080, an iPhone SE 1214×2160 instead of
  608×1080. It's about four times the pixels, so expect more Wi-Fi traffic. A phone that can't
  do H.265 still sends H.264; the app reads which from the stream. Changing it restarts the
  receivers, so phones have to reconnect. Recordings are still saved as H.264, at the larger size.
  If a receiver quits by itself after running a while, the slot starts a fresh one and shows
  Disconnected, as after any disconnect. (uxplay on macOS used to skip rebuilding its video
  pipeline from a receiver's second disconnect on, which in this mode crashed it; the app now
  runs it with `-nc no` so it rebuilds every time.)
- DRM-protected video (Netflix, Apple TV app, etc.) shows black. That's AirPlay, not a bug.

## Android phones

Android phones (Android 10 or newer) share their screens with the **Mirror Wall Cast** app in
`android/`, which speaks a small protocol of its own ([docs/mirror-wall-cast.md](docs/mirror-wall-cast.md))
rather than AirPlay. Open the app, tap a slot, and allow Android's "Start recording or casting?"
prompt (Android asks every time). The phone gets a tile like an iPhone; iPhones and Android
phones can share at once in different slots. A slot busy with one phone turns the other away.

- Builds come from Actions › Android as `MirrorWallCast`: an APK signed with the repository's test
  key (`android/test-signing.keystore`), so each build installs over the last. Once the
  `ANDROID_KEYSTORE_*` secrets hold your own key, builds are signed with it instead and an AAB
  comes too, for Intune (managed Google Play private app). Switching keys means uninstalling once.
- The phone and the Mac must be on the same network with multicast allowed for the slot list;
  otherwise type the Mac's address in the app (port 7350 for slot 1, 7450 for slot 2, ...).
- Apps that protect their screens (banking, DRM video) show black, and Android 15 hides
  notification contents while sharing. That's Android, by design.
- Staying alive: sharing runs in a foreground service that keeps the processor and Wi-Fi awake
  and carries on when the app is swiped away. Before the first share the app asks to run without
  battery limits (Android's "Let app always run in background?"); Intune can allow that for every
  phone instead (on Zebra phones, through Zebra's OEMConfig app). If Android ends the app anyway,
  sharing has to be started again, as Android only allows screen capture after the prompt.
- Log: Troubleshooting › Show Log / Share Log in the app. It records connections, what the slot
  asked for, encoder changes, the screen turning off and on, and why sharing stopped (up to
  about 1 MB, kept on the phone).
- Any version of the app works with any Mirror Wall that has Android support, older or newer;
  the rules that keep it that way are in [docs/mirror-wall-cast.md](docs/mirror-wall-cast.md#compatibility).
- Windows support for Android phones is not in yet.

## Not done yet

- USB-connected iPhones (planned next, via CoreMediaIO, the way QuickTime does it).
- Audio (deliberately off: `-as 0`).

## Licence

Mirror Wall is free software under the GNU General Public License v3 (`LICENSE`), the same
licence as UxPlay, the AirPlay receiver it ships. Anyone given the app can get its source here;
each release also attaches the exact UxPlay source it was built from. `THIRD_PARTY_NOTICES.md`
(also in the DMG as "Licenses and Source Code.txt") covers UxPlay, GStreamer and its libraries,
and Syphon. Mirror Wall isn't affiliated with Apple; AirPlay is Apple's trademark.

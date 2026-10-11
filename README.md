# Mirror Wall

A personal macOS app that shows several iPhones' screens on a Mac at once, over Wi-Fi, using
the iPhone's built-in **Screen Mirroring** (AirPlay). Nothing needs to be installed on the
phones. View only: the Mac can't control the phones.

Each tile is a "slot": its own AirPlay receiver that one iPhone mirrors to. The app starts two
slots ("Mirror Wall 1" and "Mirror Wall 2") and you can add up to eight.

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

`scripts/make-dmg.sh` builds `MirrorWall.dmg`, a disk image holding the complete app: it carries
its own uxplay and the parts of GStreamer uxplay needs, so the other Mac needs nothing installed
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
  formula, so build it from source following UxPlay's README (it needs Homebrew's `gstreamer`).
  Run from the checkout, the app looks for it in `/opt/homebrew/bin`, `/usr/local/bin` and
  `~/Documents/Claude Code/casting app/UxPlay`, or you can pick it with **File › Choose uxplay…**.
  `scripts/build-app.sh` looks in the same places, or takes `UXPLAY=/path/to/uxplay`.
- For the latency figure in Stats for Nerds, build uxplay with
  `patches/uxplay-latency-report.patch` (`git apply` it in the UxPlay checkout, then rebuild).
  It makes uxplay report one frame's timing a second at `-d 1`, converting the phone's frame
  timestamp with uxplay's clock-sync offset. Unpatched, uxplay only reports latency in its full debug
  mode (which also dumps every packet), and in UxPlay 1.74 that report always reads 0. Everything
  else works without the patch.

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
uxplay with GStreamer pointed at those plugins alone. UxPlay is GPLv3 and GStreamer LGPL, which
matters if the app is ever given to anyone else.

Then on each iPhone: Control Center › Screen Mirroring › pick a slot's name. The iPhones must
be on the same Wi-Fi as the Mac. If macOS asks to allow incoming connections or local network
access, allow it.

## Using it

- Double-click a tile (or use its ⋯ menu) to show only that phone; do it again to go back.
- **Own window (for OBS):** the ⋯ menu's **Open in Own Window** puts that phone in a window of
  its own that shows only the picture, sized to the phone's shape. The tile keeps showing it too.
  The window is titled `MacMirror-<phone name>` (the slot's name until a phone has connected),
  and keeps that title after the phone disconnects, so an OBS Window Capture source finds it
  again. If two phones have the same name, the slot number is added (`MacMirror-iPhone-2`); giving
  each phone its own name in Settings › General › About avoids that. The window's buttons appear
  when the pointer is over it. Open windows, and where they were, come back the next time the app
  starts. OBS captures the window even behind other windows. It can't capture a minimized
  window, so these windows have no minimize button; leave them behind other windows instead.
- The ⋯ menu also has Rename (changes the name on the iPhone and restarts that slot), Restart,
  Show Log and Remove Slot. Each slot's log is also written to
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
- DRM-protected video (Netflix, Apple TV app, etc.) shows black. That's AirPlay, not a bug.

## Not done yet

- USB-connected iPhones (planned next, via CoreMediaIO, the way QuickTime does it).
- Audio (deliberately off: `-as 0`).

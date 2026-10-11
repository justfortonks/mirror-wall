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

## Requirements

- macOS 14 or later, Xcode (or the Swift toolchain).
- A `uxplay` build that supports `-vrtp` (UxPlay 1.72 or later). Homebrew has no UxPlay
  formula, so build it from source following UxPlay's README. The app looks for it in
  `/opt/homebrew/bin`, `/usr/local/bin` and `~/Documents/Claude Code/casting app/UxPlay`,
  or you can pick it with **File › Choose uxplay…**.

## Build and run

```sh
swift test                 # unit tests for RTP parsing and H.264 reassembly
swift run MirrorWall       # run straight from the checkout
scripts/build-app.sh       # or build MirrorWall.app (ad-hoc signed) to keep in /Applications
```

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
  window, so these windows have no minimize button; leave them behind other windows instead. They also show on every desktop,
  so a full-screen OBS projector on the same display doesn't take them off screen.
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
- DRM-protected video (Netflix, Apple TV app, etc.) shows black. That's AirPlay, not a bug.

## Not done yet

- USB-connected iPhones (planned next, via CoreMediaIO, the way QuickTime does it).
- Audio (deliberately off: `-as 0`).

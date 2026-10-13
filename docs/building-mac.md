# Building the Mac app

How the Mac app works inside, and how to build it from source. For downloads and everyday use,
see the [README](../README.md). The Windows app has its own guide in
[windows/README.md](../windows/README.md).

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

## Installing your own build on another Mac

`scripts/make-dmg.sh` builds `MirrorWall.dmg`, a disk image holding the complete app: it carries
its own uxplay and the parts of GStreamer uxplay needs, so the other Mac needs nothing installed
(no Homebrew, no Xcode). Install it the same way as a downloaded release (see the README).

The packaged app runs on the same kind of Mac and macOS version (or later) as the one that built
it: the libraries inside come from that Mac's Homebrew. Built on an Apple Silicon Mac with
macOS 27, it needs Apple Silicon and macOS 27. Releases are built on GitHub's macOS 26 machines,
so they run on macOS 26 or later.

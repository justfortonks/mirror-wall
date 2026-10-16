# Mirror Wall in detail

The longer notes on how each Mac feature behaves, and on the Android app. The
[README](../README.md) has the short version; [building-mac.md](building-mac.md) covers building.

## Using it (Mac)

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
  screen live. The Mac keeps a screen-off session through up to five minutes without check-ins or
  frames. Live sessions still use a short disconnect timeout. The patched receiver accepts wake
  requests on an idle control socket. If iOS ends sharing, reconnect from Screen Mirroring.
  A charger does not prevent iOS from ending a session. After a real disconnect the receiver is
  restarted asynchronously, while the Stage can hold the last picture during recovery.

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
`android/`, which speaks a small protocol of its own ([docs/mirror-wall-cast.md](mirror-wall-cast.md))
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
  the rules that keep it that way are in [docs/mirror-wall-cast.md](mirror-wall-cast.md#compatibility).
- Mirror Wall for Windows takes Android phones too, the same way (see [windows/README.md](../windows/README.md)).

## Not done yet

- USB-connected iPhones (planned next, via CoreMediaIO, the way QuickTime does it).
- Audio (deliberately off: `-as 0`).

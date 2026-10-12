# What's changed in Mirror Wall

Newest first. Each release's notes, and Mirror Wall › About Mirror Wall, show the newest entry
that build includes. When a change people will notice is merged, add a line here in the same
pull request: under a new `## <date>: <short title>` heading at the top, or under the top one
if it hasn't been released yet.

## October 12, 2026: Android phones

- Android phones can share their screens to Mirror Wall on a Mac with the new Mirror Wall Cast
  app: open it, tap a slot, allow sharing. An Android phone gets a tile like an iPhone, with its
  own window for OBS, recording, screenshots and Stats for Nerds, and iPhones and Android phones
  can share at the same time in different slots.
- Android phones reconnect by themselves when Mirror Wall restarts their slot (for example after
  turning Sharper Picture on), and send H.265 at full screen resolution when Sharper Picture is
  on, if the phone can.
- Mirror Wall Cast keeps the phone's screen on while sharing (a switch in the app turns this off).

## October 12, 2026: Mirror Wall for Windows

- Mirror Wall now runs on Windows 10 and 11 too: the same tile wall, each slot's own window for
  OBS, and an OBS feed per slot through Spout (the Windows version of Syphon). Download
  MirrorWall-Setup.exe from the Releases page.
- The first time it opens, the Windows version checks that OBS has the Spout2 plugin and offers
  its download page if not, and asks again only when a feed is turned on without it.

## October 12, 2026: Download it, and see what changed

- Mirror Wall can be downloaded as a ready-made DMG from the Releases page, so nobody needs to
  build it.
- Mirror Wall is now free software under the GNU GPL v3. Licence notices for UxPlay, GStreamer
  and Syphon come with the app and the DMG.
- About Mirror Wall shows what changed in this build, links to the exact code it was built from,
  and links to this change log.

## October 11, 2026: Send to OBS (Syphon)

- A tile's ⋯ menu can send that phone straight to OBS through Syphon, remembered per slot. In OBS
  add a Syphon Client source and pick "[Mirror Wall] MacMirror-<phone name>". It works with
  Mirror Wall minimized and no window open.
- While the phone is away, the feed shows the slot's standby picture, and a phone that drops no
  longer leaves its last frames on it.
- Builds are numbered (0.65, 0.66…), and About Mirror Wall shows the commit and build date.

## October 11, 2026: Reliable reconnects

- Every time a phone disconnects, its slot rebuilds the receiver's video pipeline, so the next
  connection always gets a picture. This fixes a slot that stayed frozen after a reconnect, and
  the occasional crash with Sharper Picture.

## October 11, 2026: Sharper Picture

- View › Sharper Picture (off by default) has phones send H.265, which is noticeably sharper,
  especially in portrait.
- A receiver that crashes is replaced quietly, without macOS's "quit unexpectedly" dialog.

## October 11, 2026: Smoother Motion

- View › Smoother Motion (off by default) shows frames at the pace the phone captured them,
  evening out Wi-Fi judder for a slight delay. Recordings are evenly timed too.

## October 11, 2026: Settings, standby pictures and tile buttons

- A Settings window: an optional allow-list of phones, custom slot names, and where screenshots
  and recordings are saved.
- Slots are named "Mirror Wall N · <Mac name>", and tiles show friendly iPhone model names.
- Tile buttons for a screenshot, recording and the pop-out window.
- A standby picture for when no phone is connected, for all slots or one.
- Pop-out sizes Small, Medium and Large, sized to each phone's real screen, or a custom size.
- The Dock icon bounces when a phone disconnects.

## October 11, 2026: Recording

- Record any slot to a movie file. Rotating the phone starts a new file.

## October 11, 2026: Frame rate limit and Stats for Nerds

- View › Frame Rate Limit: 30 (the default) or 60 frames per second.
- View › Stats for Nerds shows each tile's frame rate, resolution, decode time and lag.

## October 11, 2026: Install on another Mac

- MirrorWall.dmg holds the complete app, receiver included, so another Mac needs nothing else
  installed.

## October 11, 2026: App icon

- Mirror Wall has its own icon.

## October 11, 2026: Better for OBS

- Pop-out windows can't be minimized (OBS can't capture a minimized window), and the app keeps
  running at full speed in the background.

## October 11, 2026: Fresh receiver after each phone

- Each slot restarts its receiver after a disconnect, so the next phone connects cleanly.

## October 11, 2026: Faster disconnect detection

- Phone events show up at once, and a phone that stops sending for 10 seconds is marked
  Disconnected.

## October 11, 2026: Pop-out windows for OBS

- Each phone can have a window of its own, titled "MacMirror-<phone name>", for OBS window
  capture.

## October 11, 2026: Phone names and timers

- Tiles show the phone's name, how long it has been live or had its screen off, and a
  Disconnected state.

## October 11, 2026: First version

- A Mac window with a tile per iPhone, mirrored over Wi-Fi with the iPhone's own Screen
  Mirroring. Up to eight phones at once.

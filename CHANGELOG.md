# What's changed in Mirror Wall

Newest first. Each release's notes, and Mirror Wall › About Mirror Wall, show the newest entry
that build includes. When a change people will notice is merged, add a line here in the same
pull request: under a new `## <date>: <short title>` heading at the top, or under the top one
if it hasn't been released yet.

## October 16, 2026: Themes and a friendlier Stage

- Mac: Settings › General › Theme chooses the app's look. Standard is the look you know;
  Imprivata gives the wall and the Stage Imprivata Blue, brand status colors, the Barlow font
  and the hex pattern, plus a "Live demo" caption bar along the Stage's bottom (with the
  Imprivata logo when it's been added to the app). Thanks to Cody for the Imprivata design.
- Mac: the Stage has a control bar that fades in when you move the mouse over it, with a chip
  for each phone (its menu has that phone's options), Add Slot, Layout, Bezels, Record All and
  more. Before any phone connects, it shows a "Ready for phones" screen with how to connect to
  each slot. Right-click the Stage to show or hide the caption bar.
- Mac: two new switches in Settings › Wall › Stage, both off unless you turn them on: open to
  the Stage when Mirror Wall starts, and put phones on the Stage as they connect.
- Mac: "Show Mirror Wall Window" is now "Show Wall", and View › Show Stage is ⌘1.

## October 16, 2026: OBS feed follows slot renames, and a list of test builds

- Renaming a slot now renames its OBS feed (Syphon on the Mac, Spout on Windows) and its own
  window to "MacMirror-<new name>". Before, once a phone had connected, both kept the phone's
  name. Slots still using their standard "Mirror Wall 1" name go by the phone's name as before.
  OBS sources pointed at the old name need the new one picked once.
- With Settings › General › Updates set to Beta, Check for Update now lists every test build on
  offer, most recently built first, with what each one is for, and the newest release. Pick any
  one to install it. Before, it offered only the one with the highest build number, which could be
  an older test build from another branch.
- Test builds can be withdrawn from that list, or offered again, with Actions › Beta builds on
  GitHub. Copies already installed keep working.

## October 15, 2026: Android phone frames

- Phone bezels now show the real phone for a Zebra HC50, a white Honeywell CT37, a Spectralink
  Versity 95/96 (9540, 9553, 9640, 9653) or a Versity 97 (9740, 9753): a photo of its front,
  on the wall, in pop-outs, on the Stage and in the OBS feed, on Mac and Windows. They also take
  their true screen size on the Stage and in pop-outs. Other Android phones keep the plain frame.
- Android app: turning the phone back to portrait by pressing Home (the home screen is always
  upright) no longer leaves Mirror Wall showing a sideways picture with the screen squeezed in
  the middle.
- Phone frames now turn the way an Android phone is held: upside down, or sideways either way
  (needs the Android app from this release; iPhones and older apps keep the frame's top on the
  left when sideways).

## October 15, 2026: Windows fixes

- Windows: opening Mirror Wall while it's already running (say, hidden behind its tray icon)
  now brings back the wall instead of starting a second copy whose tiles all said "Couldn't
  listen on UDP port".
- Windows: the Android app no longer lists a phantom "Slot Name(1)", and a slot drops off its
  list every time an Android phone takes it, including after reconnecting.

## October 14, 2026: Beta updates

- Settings › General › Updates chooses what Check for Update offers: releases only (Stable, the
  default), or releases and test builds (Beta), whichever is newest. Test builds are published
  as GitHub pre-releases numbered like "0.112 beta 7", shown in About, so two test builds are
  never mistaken for each other. To go back, choose Stable, then Check for Update › Go Back.
- Check for Update no longer offers to reinstall the version you already have.

## October 14, 2026: Stage window

- A new Stage window shows every phone that's mirroring in one clean window, at their true
  relative sizes (an iPhone SE beside a Pro Max looks smaller, as it does in your hand), for
  sharing a single window in Teams, Zoom or OBS. Open it from View › Show Stage or the menu bar
  / tray icon. Choose Side by Side, Stacked or Grid from View › Stage Layout or by right-clicking
  the stage. Phones with a bezel turned on show it on the stage too. OBS finds the window as
  "MacMirror-Stage".
- Choose which phones appear on the stage: untick Show on Stage in a slot's ⋯ menu, or use
  Phones on Stage in the View menu or the stage's right-click menu. Every slot is on stage
  unless you take it off.

## October 14, 2026: Check for Update

- Mirror Wall › Check for Update… (Help › Check for Update… on Windows, and in the menu bar or
  notification area icon's menu) looks for a newer release, shows what's new in it, and on
  request downloads it, installs it in place of the running copy and reopens Mirror Wall. It
  never checks by itself. A Mac doesn't ask for Open Anyway again for an update installed this
  way; Windows asks once to let the installer make changes.

## October 14, 2026: Android app on the releases page

- Each release now includes Mirror Wall Cast for Android (MirrorWallCast.apk) alongside the Mac
  and Windows downloads, and the README links to it, so it no longer needs a GitHub sign-in.

## October 14, 2026: Stays awake, menu bar / tray icon, phone bezels

- Mirror Wall keeps the computer and its screen awake while a phone is mirroring or a slot is
  recording, and lets it sleep again once none is. Settings › General turns this off.
- Mirror Wall has an icon in the menu bar (the notification area on Windows) listing every slot
  and how it's doing. With it there, closing the wall's window leaves Mirror Wall running, so
  phones keep mirroring to their own windows and OBS. Quit from the icon's menu. Settings turns
  the icon off, and closing the wall then quits as before.
- Phone bezels: a phone-shaped frame around a slot's picture, on the wall and in its own window,
  styled after the phone (home button, notch or Dynamic Island; a plain phone for Android).
  Settings › Wall turns them on for every slot; a slot's ⋯ menu › Phone Bezel turns its
  own on or off, and can also put the frame around the slot's OBS feed, with see-through corners
  (on a Mac, tick "Allow Transparency" in the Syphon Client source). The wall and the OBS feed
  are set separately. Recordings and screenshots stay unframed. Off by default.
- A slot's ⋯ menu is regrouped: its window, then screenshot and recording, then OBS, bezel and
  standby picture, then rename, Troubleshooting (log, restart) and remove. The recordings and
  screenshots folders and Stats for Nerds are in the File and View menus. While a slot waits for
  a phone, Start Recording reads Record When a Phone Connects, which is what it does.
- Settings is split into tabs: General (staying awake, the menu bar or tray icon, save folders,
  alerts), Wall (standby picture, bezels), OBS, and Phones (who can mirror).

## October 13, 2026: Settings for OBS and own windows

- Settings › Send every slot to OBS turns the OBS feed on for every slot, including slots added
  later. A slot's ⋯ menu can still turn its own feed off.
- Slots' own windows no longer reopen when Mirror Wall starts. Settings › Reopen slots' own
  windows brings that back.
- Right-click an empty part of the wall to add a slot.
- Busy slots drop off the Mirror Wall Cast app's list until they're free.
- Mirror Wall Cast keeps the phone's processor and Wi-Fi awake while sharing, keeps sharing when
  the app is swiped away, asks to run without battery limits, and keeps a log (Show Log and
  Share Log in the app).
- Every version of Mirror Wall Cast works with every version of Mirror Wall that supports
  Android phones, older or newer.
- Mirror Wall for Windows takes Android phones too, and has the same new settings, the
  right-click to add a slot, and busy slots hidden from the Mirror Wall Cast list.

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

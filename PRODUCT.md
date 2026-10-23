# Mirror Wall Product Context

Register: product

Mirror Wall is a Mac app that puts real iOS and Android demo devices into a video meeting.
Phones mirror wirelessly into one Stage window that the presenter shares in Teams or Zoom, so
the audience sees the actual device, in a frame that looks like it, while the presenter works
on the phone in their hand. Nothing leaves the presenter's Mac: no cables, no cloud vendor.

It replaces AirDroid-style tools for this job.

## Primary users

- Solutions engineers and sales engineers running remote demos from home offices.
- The same people at events and customer sites, where the Stage may be on a big screen and the
  network is shared, isolated or hostile.
- Trainers and product people who show mobile apps on the devices customers actually buy
  (Zebra, Honeywell, Spectralink handhelds, iPhone, iPad).

## Core jobs

- Show one or more phones in a meeting without screen-sharing the whole desktop.
- Mix iOS and Android devices on one Stage, at their true relative sizes.
- Make the device on screen recognizable: a photo frame for healthcare devices, a drawn frame
  for iPhones and iPads.
- Keep the presentation clean: no menus, toolbars or status chrome visible to the audience unless
  the presenter asks for them.
- Recover gracefully when a phone drops off Wi-Fi mid-demo instead of the layout jumping.
- Let the presenter hide something private (a notification, a password screen) without stopping
  the demo.
- Capture screenshots and recordings for follow-up material.
- Feed OBS for produced or recorded content.

## Critical workflows

1. **Home-office demo:** open Mirror Wall (the Stage opens), mirror the phones, share the Stage
   window in Teams/Zoom, demo, stop.
2. **Mid-demo privacy:** press **P** (Freeze Stage), handle the private screen on the phone, press
   **P** again.
3. **Device swap:** Stop Sharing on one Android device, start sharing from the next; or hide a
   device from the Stage with On Stage.
4. **Event demo:** turn on the PIN in Settings so only the presenter's iPhones can join, run on a
   dedicated demo network.
5. **Wrong or unknown frame:** right-click the device › Bezel Model › choose the right one.
6. **Something's wrong:** Show Wall › the slot's ⋯ › Troubleshooting › Show Log or Restart
   Receiver.
7. **Roll out the Android app:** deploy `com.justfortonks.mirrorwall.cast` from MDM; updates install
   over the top while the signing key stays the same.

## Product principles

- **The Stage is the product.** It's the first window, the one that gets shared, and the one the
  design effort goes into. The Wall is the operator's back room.
- **The audience sees phones, not app chrome.** Controls appear on request (C, Control/Option) and
  sit over the caption strip, never over a device.
- **Presenter intent sticks.** A hidden device stays hidden and a frozen Stage stays frozen
  through reconnects; nothing reappears on its own in front of a customer.
- **Hold, don't jump.** A dropped phone keeps its place and last picture while it may come back.
- **Works on any keyboard.** Plain keys (C, P, Esc) and Control as well as Option, because presenters
  plug into external keyboards without an Option key.
- **Defaults fit the home office.** No PIN by default; security options are there for events.
- **True to the device.** Real relative sizes, real frames, never stretched or cropped video.
- **Our updates are ours.** The app only updates from this fork.

## Data sensitivity

- Mirror Wall doesn't send anything off the Mac except to check this fork's GitHub releases when
  asked.
- Screenshots and recordings stay in local folders the presenter picks. They may contain customer
  or demo-tenant data; treat them that way.
- Android video travels unencrypted over the local network. Use a trusted network; don't demo real
  patient data.
- Logs (`~/Library/Logs/MirrorWall/`) contain device names and network addresses, not screen
  content.

## Current product surfaces

- **Stage** (main window): branded presentation surface, presenter controls, Devices and More
  menus, waiting screen with connection instructions and PIN.
- **Wall**: grid of slots with status, timers, Stats for Nerds, per-slot ⋯ menu, logs.
- **Own windows**: one device per window, `MacMirror-<name>`, for window capture.
- **Syphon feeds**: per-device OBS sources, framed or not.
- **Menu bar icon**: slot list and status, Show Stage, Show Wall, Quit.
- **Settings**: PIN, allow-list, bezels, standby picture, save folders, OBS, wake, updates.
- **Mirror Wall Cast** (Android): slot picker, Scan QR Code, connect by address, share, stop, log.
- **Windows app**: inherited from upstream; the Stage-first window and branding haven't reached it yet.

## Anti-goals

- Remote control of the phone from the Mac. The presenter uses the phone in their hand.
- Audio.
- Replacing MDM or remote-support tools.
- White-labeling: Mirror Wall has one look (DESIGN.md), not a per-customer one.
- Diverging from upstream for its own sake: shared improvements flow back in through
  `merge-upstream` style branches and pull requests.

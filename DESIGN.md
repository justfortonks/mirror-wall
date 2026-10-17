# Mirror Wall Design Context

Register: product

How Mirror Wall looks and behaves, for anyone changing the UI. Colors, type and pattern follow the
Imprivata 2026 Brand Style Guide. All of it lives in `Sources/MirrorWall/Brand.swift` (Mac) and
`android/.../cast/Brand.kt` (Android), so it can be changed in one place.

## Scene

A customer is watching a shared window in Teams or Zoom, often small, often compressed. The
presenter is holding a phone and talking. Anything on the Stage that isn't a phone or a short
caption competes with the demo.

## Visual posture

- **Stage:** Imprivata Blue `#2C3F57` to `#4698CB` diagonal gradient, the hex pattern as a
  top-right corner accent (white, sky, teal, upright, never rotated), Barlow throughout.
- **Wall:** the dark operator view. Shades of Imprivata Blue (`#24344A` deep, `#33495F` raised,
  `#7C8DA3` muted), white and Ice `#D2E4F9` text.
- **Accents:** Red `#CC0033` for recording and the main action, Teal `#2CD5C4` for live status.
- **Android app:** light page `#F4F5F7`, Imprivata Blue text, red pill buttons, the same hex
  accent.
- **Logo:** the official white logo, only in the Stage caption, at the right with clear space
  around it. It's never committed; without the file the caption shows no logo.

## Layout rules

- Phones are laid out by `stageFrames` (MirrorCore) at their true relative sizes: Side by Side,
  Stacked or Grid. Never stretch or crop a phone's picture; a frame adds space around it instead.
- The caption bar ("Live demo · device names") runs along the bottom, 40-64 pt tall depending on
  the window. It can be turned off.
- The control bar sits over the caption strip, never over a phone.
- With no phones mirroring, the Stage shows the waiting screen: "Demo starting shortly", how to
  connect each slot, and the PIN when one is set.
- The Stage window can be sized to the phones with **Fit Window to Devices**.

## Presenter controls

- Hidden by default. **C** pins or unpins them; holding **Control** or **Option** shows them while
  held; **Esc** hides pinned controls. **P** toggles Freeze Stage. Keys only act when the Stage is
  the focused window and no ⌘/⌥/⌃ is held.
- The bar has: Add Device Space, Devices (per-device actions), Freeze Stage, More (layout,
  bezels, recording, screenshots, caption, logo, Show Wall, Settings).
- Right-clicking a device gives its own menu: Freeze Stage, Stop Sharing, On Stage, Phone Bezel,
  Bezel Model, Demo Label…, screenshot, recording, own window, More in the Wall….
- In a narrow window or with many devices the bar compacts into Devices / Freeze Stage / More.

## Device states on the Stage

| State | What the audience sees |
|---|---|
| Live | The phone's picture, framed if bezels are on |
| Reconnecting (quiet > 4.5 s) | Last picture, dimmed, small "reconnecting" label; place held for 45 s |
| Stage frozen | The held picture, small "Stage frozen" label |
| Screen off | Last picture, small "Screen off" label |
| Hidden | Nothing; the others re-flow |

Labels are small (11 pt) and low-contrast on purpose: they inform the presenter without
interrupting the audience.

## Device frames

- **Photo frames** (`Resources/Bezels/*.png`): see-through outside the phone and in the screen;
  the picture fills the screen opening underneath. Measured in the PNG's pixels
  (`BezelArtwork`). Add new ones the same way: a portrait front photo, transparent screen, its
  canvas size, screen rect and diagonal.
- **Drawn frames** (`BezelStyle` + `BezelPreset`): vector silhouettes with the model's outline
  aspect (`portraitAspect`), Dynamic Island / notch / home button / camera as appropriate.
- Automatic choice order: photo frame for the reported model, then a drawn preset, then the
  iPhone family logic, then a plain frame.
- Frames turn with the phone. Recordings and screenshots are never framed.

## Accessibility

- Text on the Blue surfaces uses white or Ice for contrast; the Wall forces a dark SwiftUI
  environment so system colors stay readable.
- Controls have accessibility labels ("More presentation controls").
- Respects Reduce Motion for control-bar transitions.

## Copy rules

- Plain words a customer would understand if they glimpse them: "Live demo", "reconnecting",
  "Stage frozen", "Demo starting shortly".
- "Device" on the Stage (it may be an iPad or a handheld), "slot" only in the Wall and Settings.
- Say what a control really affects: Freeze Stage freezes the Stage, not recordings or OBS feeds.

## Component rules

- Use `Brand.font(size, weight)` rather than system fonts; it falls back if Barlow isn't loaded.
- Use `Brand` colors, not literal hex values in views.
- Keep Mac and Android brand files in step when a color changes.
- Frame geometry lives in MirrorCore so it can be unit-tested; drawing lives in MirrorWall.

# ADR 0003: Photo frames and drawn frames side by side

Status: accepted, October 2026

## Context

The fork added a catalog of drawn frames (`BezelPreset`) with a per-device Bezel Model picker,
covering iPhone families, iPad and some Zebra devices. Upstream independently added photo frames
(`BezelArtwork`) for the healthcare devices we demo most: Zebra HC50, Honeywell CT37, Spectralink
Versity 95/96 and 97. Photo frames look like the real device; drawn frames cover far more models
and scale cleanly.

## Decision

- Keep both. Photo frames are added to the picker as presets under Zebra, Honeywell and
  Spectralink.
- Automatic chooses, in order: a photo frame for the reported model, a drawn preset, the iPhone
  family logic, then a plain frame.
- The Zebra HC50 uses its photo frame. The TC53e keeps its drawn frame.
- Every preset declares its outline aspect so video keeps its shape in both orientations; a test
  checks this for every preset, photo or drawn.

## Consequences

- New devices can get either kind. A photo frame needs a transparent front PNG in
  `Resources/Bezels`, its canvas size, screen rectangle and screen diagonal.
- Photo frames are larger resources and are shared with the Windows app.

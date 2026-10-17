# ADR 0002: The Stage is the main window

Status: accepted, October 2026

## Context

Upstream opens to the Wall, a grid of every slot with status and controls, and offers the Stage
as a second window for sharing. For SE demos that meant a jump from one window to another at the
start of every call, and the Wall's operator chrome was easy to share by mistake.

## Decision

- The app opens to the Stage, and the Wall is hidden at launch.
- Phones join the Stage automatically when they start mirroring.
- Presenter controls are hidden until asked for (C to pin, Control or Option to peek, Esc to
  hide) and sit over the caption strip, never over a device.
- The Wall stays available from Show Wall for troubleshooting, logs and per-slot settings.

## Consequences

- Everything a presenter needs mid-demo must be reachable from the Stage (Devices, More and the
  right-click menu), not only from the Wall.
- Keyboard shortcuts use plain keys so they work on external keyboards without an Option key, and
  only act when the Stage is focused.

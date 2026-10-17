# Mirror Wall project index

The entry point for project context. It points to the documents that own each topic rather than
repeating them.

## Start here

- [README](../README.md) covers what the app does, how it works, building, configuration and the
  fork rules.
- [Current focus](CURRENT_FOCUS.md) records what's in progress, the next step and parked work.
- [Delivery log](DELIVERY_LOG.md) summarizes what has shipped, in the fork and upstream.
- [Product context](../PRODUCT.md) defines the users, demo workflows, principles and anti-goals.
- [Design context](../DESIGN.md) defines the branding, Stage layout, presenter controls and frame
  rules.
- [Agent guidance](../AGENTS.md) gives repository-specific instructions for coding agents.
- [Changelog](../CHANGELOG.md) is the user-facing list of changes; release notes come from it.

## Using the app

- [Mirror Wall in detail](details.md) covers how each Mac feature behaves (own windows, OBS,
  standby pictures, recording, frame rate, Smoother Motion, H.265, Stats for Nerds) and the
  Android app.
- [SE handoff and test checklist](se-handoff.md) covers the SE build, presenter controls,
  bezel catalog and the pre-demo rehearsal checklist.

## Building and releasing

- [Building the Mac app](building-mac.md) explains the receiver design, ports, UxPlay patches
  and build scripts.
- [Windows guide](../windows/README.md) is the upstream Windows app (no SE changes).
- Workflows: [release](../.github/workflows/release.yml),
  [beta builds](../.github/workflows/beta-builds.yml),
  [Android](../.github/workflows/android.yml), [Windows](../.github/workflows/windows.yml).

## Protocols and internals

- [Mirror Wall Cast protocol](mirror-wall-cast.md) is the Android wire format, message types
  (including stop `0x83` and orientation `0x08`) and compatibility rules.

## Decisions

- [ADR 0001: Fork tracks upstream on a separate branch](adr/0001-fork-tracks-upstream.md)
- [ADR 0002: The Stage is the main window](adr/0002-stage-first-window.md)
- [ADR 0003: Photo frames and drawn frames side by side](adr/0003-photo-and-drawn-frames.md)
- [ADR 0004: Android app identity and signing](adr/0004-android-app-identity.md)
- [ADR 0005: Security defaults for home offices and events](adr/0005-security-defaults.md)

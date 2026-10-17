# ADR 0005: Security defaults for home offices and events

Status: accepted, October 2026

## Context

Most demos run from home offices on private networks; some run at events on shared networks where
a stranger's iPhone could try to mirror onto the Stage.

## Decision

- An iPhone PIN is available in Settings and off by default. When on, a random 4-digit code is
  generated and shown on the Stage's waiting screen. New PIN rotates it.
- The allow-list (only phones that have mirrored before) stays available and off by default.
- Android traffic stays plain TCP for now; the guidance is a dedicated or trusted demo network.
- The Stage caption shows the Mac's host name in slot names; left as is.

## Consequences

- At events, presenters must turn on the PIN and use a trusted network.
- Encrypted, authenticated Android pairing is parked in [CURRENT_FOCUS.md](../CURRENT_FOCUS.md).

# 6. QR connect link now, relay later

Date: 2026-10-22

## Status

Accepted.

## Context

A customer-site demo on October 21 ran on guest Wi-Fi with Tailscale on every device. The
Android handheld never found a slot and the iPhone only worked over USB. Guest Wi-Fi keeps
devices apart (client isolation) and Bonjour never crosses a VPN, so discovery had nothing to
find; the Mac's Tailscale address, typed into the app, would have worked. AirDroid Cast worked
because both of its ends only dial out to AirDroid's relay (WebRTC + MQTT + TURN; see
`docs/relay-design.md`).

## Decision

1. Mirror Wall shows a QR code (Connect with QR Code…, ⌘K) carrying a `mirrorwall://connect`
   link with every address the Mac has, Wi-Fi first, then Tailscale, then other VPNs, plus the
   slot's cast port. The app scans it (or the phone's camera opens it) and shares to the first
   address that answers. No change to the Cast protocol; the link is a separate, versioned
   format held in `ConnectLink` on both sides with matching tests.
2. The relay is not built yet. The team runs its next demos on Tailscale with the QR code; if
   reachability is still a problem, the self-hosted byte-pump relay in `docs/relay-design.md`
   is the next step, chosen over WebRTC/TURN because it reuses the existing protocol unchanged.
3. The link format is a compatibility surface like the protocol: items are only added, never
   renamed; a missing port means slot 1; both parsers ignore what they don't know.

## Consequences

- Android works on hostile networks as long as the Mac and the phone share any route (same
  LAN, Tailscale, or a hotspot). It still doesn't work with no shared route at all; that's the
  relay's job.
- The Android app gains a camera scanner dependency (`zxing-android-embedded`) and a
  `mirrorwall://` intent filter; camera is optional at install time.
- The Mac app learns to enumerate its own addresses; a wrong guess (an address phones can't
  use) costs the phone a 2-second knock per address, no more.
- iPhone is unchanged: AirPlay can't take this path. USB or a shared hotspot remain its answers
  until there's an iOS companion app.

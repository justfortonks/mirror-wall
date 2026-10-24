# Relay design: sharing when the network keeps devices apart

_Status: the relay itself is built and running (`relay/`, on Fly.io, October 24, 2026); the Mac
and Android sides are next. The QR code shipped October 22. The design below is as proposed;
`relay/README.md` has the wire protocol as built (one waiting connection per slot, no tickets)._

## The problem

At a customer site on October 21 the Mac, an iPhone and an Android handheld were on the
customer's guest Wi-Fi with Tailscale on every device. The iPhone only mirrored over USB; the
Android app never listed a slot. Nothing was wrong with Mirror Wall: guest Wi-Fi almost always
has client isolation (devices reach the internet, never each other), and Bonjour multicast never
crosses a VPN. AirDroid Cast worked because it doesn't need the two ends to see each other at all.

## How AirDroid Cast does it (from the 1.2.2 Mac client)

Looked at the shipped app bundle (a Xamarin.Mac build: `AirDroidUtilty.dll`, `AirDroid Cast.exe`,
`Mqtt.dll`, `WebSocket4Net.dll`, `libWebRTC.dylib`, `libstreaming.dylib`, `libscrcpy.dylib`,
`libAirPlay.dylib`). What's in it:

- **Media over WebRTC.** `AirStreamClient` tracks `Local_CandidateType` / `Remote_CandidateType`
  / `Remote_Protocol`, i.e. standard ICE: host candidates on the LAN, server-reflexive through
  STUN, and relay through TURN. `AirSetting.UrlTurnServer` and `UrlLoadBalance` hand the client
  its TURN servers. `LibStreamDll` wraps `DoOfferReply`, `DoIceCandidates`, `DoSendDataChannel`.
- **Signaling over MQTT.** `MqttRTCClient` (`OpenMqttAsync`, `PublishWebRtcStartForClientAsync`,
  `OnHandleMessageForClientAsync` / `ForTargetAsync`) publishes the offer, answer and ICE
  candidates on a broker, keyed by the device's `MqttKey` and the cast code.
- **The 9-digit cast code** is a lookup key in their cloud, nothing more (`GetShareCode`,
  `RefreshShareCode`; `cast_link.html?airdroidCast-code=`; `UrlGetQRCode`, so they have QR too).
- **LAN first.** `AirDevice_Extensions.IsLAN` / `IsWAN` / `CheckArpNetwork` and
  `AirLocalHttpServer`: when the two ends can see each other it goes direct; otherwise
  everything, including the video, rides their TURN relay.
- **A second, plainer relay:** `forwardsvr/heartbeat`, `forwardsvr/webstatus/on|off`, a TCP
  forwarding server that also carries the "web cast" and remote control paths.
- The iPhone path is AirPlay (`libAirPlay.dylib`, `AVAirPlay`) on the LAN, or their iOS app's
  broadcast extension over the same WebRTC path when it isn't.

So: both ends only ever make outbound connections to AirDroid's servers, which is why guest Wi-Fi
and per-device VPNs don't bother it, and why the video crosses a non-US vendor's relay.

## What Mirror Wall needs

Mirror Wall Cast is already a clean framed TCP protocol (`docs/mirror-wall-cast.md`): one
connection per phone, hello/welcome, then H.264/H.265 access units. That makes a relay almost
trivial: pipe bytes between two outbound connections and change nothing in the protocol.

Three options, in the order to try them:

### 1. Tailscale, no relay (works today with the QR code)

Mac and handhelds on the same tailnet. The QR code carries the Mac's Tailscale address, the app
dials it, Tailscale does the NAT traversal (direct, or through its DERP relays when it must).

- Nothing to host. Video stays inside the tailnet; DERP relays only ever see encrypted WireGuard.
- Needs Tailscale installed and signed in on every demo device; MDM can push it.
- On October 21 this would have worked for Android had the Mac's Tailscale address been typed.
  The QR code removes the typing.
- Does nothing for iPhone AirPlay (see "iPhone" below).

### 2. Mirror Wall Relay (small, self-hosted)

For SEs who can't put Tailscale on a customer-facing device, or for a loaner handheld. A single
binary (Go is the natural fit; ~300 lines) on a $5 VM or Fly.io, behind TLS on port 443 so hotel
and guest networks let it through.

**Rendezvous.**

```
Mac   ──TLS──▶ relay   OPEN  {token, slot: "Mirror Wall 1", castPort: 7350}
relay ──────▶ Mac      CODE  {code: "482 913", expires: 1800}
phone ──TLS──▶ relay   JOIN  {code: "482913"}
relay ──────▶ Mac      (a new "connection" for that slot)
relay ◀═════▶ both     bytes piped verbatim from here on: the normal Cast protocol
```

- The code is a 6-digit bearer for a 30-minute window, shown in the QR code and under it, exactly
  as the PIN is today. The relay holds nothing else and never parses the video.
- The Mac keeps one control connection per slot open (OPEN, then heartbeats), and the relay
  opens a second "data" stream per joining phone over the same TLS connection (length-prefixed
  mux) or a fresh connection with a one-shot ticket. Fresh connection is simpler; do that.
- `token` is a per-team secret set in Settings, so the relay only serves your team's Macs.
- Everything is outbound on 443 from both ends: no port forwarding, no UPnP, no STUN.

**What changes in the apps.**

Mac:
- `CastConnection` takes any `NWConnection`, not only ones a listener accepted (the init is
  `fileprivate` today; one `internal` init and the rest already works).
- A `RelayClient` per slot: opens the control connection when Settings has a relay, hands each
  data stream to the slot through the same `onConnection` path `CastServer` uses, so hello,
  welcome, busy, pings and stop-sharing all behave as they do on the LAN.
- `ConnectLink` gains `relay=<host>&code=<code>`; the QR code carries both the direct addresses
  and the relay, and the phone tries direct first.
- Settings: Relay host, team token, on/off. Stats for Nerds already shows the round trip, which
  is the honest way to see what the relay costs.

Android:
- `CastService` dials the relay when direct addresses fail (or when the link only has a relay),
  sends `JOIN {code}` as its first bytes, then the usual hello. Everything after that is the
  existing code path; reconnects go through the relay again.
- TLS: `SSLSocketFactory` on the existing `Socket`; the relay has a real certificate (Let's
  Encrypt), so no pinning or custom trust.

Relay:
- Go, `crypto/tls`, autocert, two maps (codes → waiting Macs, tickets → data streams), a 30-minute
  sweep. Logs connection counts and bytes, never payloads. Deploy with one `fly launch`.

**Numbers to expect.**
- Bandwidth: Mirror Wall Cast at 1080p30 is roughly 4–8 Mb/s per phone, more with Sharper
  Picture. A two-phone, one-hour demo is 4–7 GB through the relay (in and out). Fly.io and most
  VPS plans include 100 GB+/month; a team doing a few remote demos a week fits.
- Latency: one extra hop each way. A relay in the same region as the demo adds 20–60 ms; a
  cross-country one adds ~80 ms. Smoother Motion already buffers a moment, so this is visible
  only in the Stats overlay, not on the Stage.
- CPU: none worth mentioning; it's a byte pump.

**Security notes.**
- TLS end to end to the relay; the relay sees the video in the clear while piping it. If that
  matters, the next step is E2E encryption of the Cast stream keyed from the QR code (the code
  becomes a shared secret; ChaCha20-Poly1305 over each message). That's the same "encrypted,
  authenticated Android pairing" already parked in `CURRENT_FOCUS.md`, and the relay is the
  reason to do it.
- The relay is the only piece that's reachable from the internet, so it's where to be careful:
  rate-limit JOIN by code guesses (6 digits, 30-minute life, 10 guesses then the code burns).

### 3. WebRTC with TURN (what AirDroid does)

Direct peer-to-peer when NAT allows, TURN when it doesn't, DTLS-SRTP encryption for free, and
the adaptive bitrate that WebRTC brings. It's the better long-term transport and would also fit
a future iPhone companion app. But it means libwebrtc on the Mac (a 20 MB framework and a
GStreamer or VideoToolbox bridge into the existing `H264Renderer`), a signaling server anyway,
and the Android app's encoder re-plumbed into a `VideoTrack`. Weeks, not days, and option 2
covers the same networks. Revisit when adaptive bitrate becomes the complaint rather than
reachability.

## iPhone

None of this helps AirPlay: Apple's protocol, discovered by Bonjour, and Mirror Wall only receives
it. On a hostile network the iPhone's options stay:

- USB (worked on October 21, and will keep working).
- Put the iPhone and the Mac on the same personal hotspot or travel router.
- Longer term, a Mirror Wall Cast app for iOS using a ReplayKit broadcast upload extension that
  speaks the Cast protocol. Then the iPhone takes the same direct, Tailscale and relay paths as
  Android, and the uxplay dependency becomes optional. That's a separate project; worth an ADR
  of its own before starting.

## Recommendation

Ship the QR code now (done alongside this document). Run the next few customer demos on
Tailscale and see whether reachability is still a problem. If it is, build option 2: the relay is
a few days of work including the Settings and Android changes, and it reuses every byte of the
existing protocol. Hold option 3 until there's a reason beyond reachability.

## Things to decide before building the relay

- Who hosts it: a personal or team Fly.io account. Decides the domain and the token
  handling.
- Whether the relay must never see video in the clear (then E2E is part of the first version,
  not a follow-up).
- Whether the code is per slot (simplest, matches the PIN today) or per Mac (one code, the phone
  picks a slot after joining; nicer for a wall of four handhelds).

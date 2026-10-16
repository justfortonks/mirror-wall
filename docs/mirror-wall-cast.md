# Mirror Wall Cast

How Android phones share their screens to Mirror Wall. iPhones use AirPlay through each slot's
uxplay; Android phones use this small protocol instead, with the app in `android/`, and land in
the same tile, pop-out window, recording and OBS feed.

## Finding a slot

While a slot runs, Mirror Wall advertises it with Bonjour/mDNS as `_mirrorwall._tcp`, under the
slot's name ("Mirror Wall 2 · MacBook Air"), on its cast port: 7350 for slot 1, 7450 for slot 2,
and so on (the slot's AirPlay base port + 50). Networks that block multicast can still connect
by address.

## Messages

One TCP connection per phone. Every message is:

| Bytes | Meaning |
|---|---|
| 1 | Type |
| 4 | Payload length, big-endian |
| n | Payload |

Unknown types are skipped, so either side can add messages later.

| Type | Direction | Payload |
|---|---|---|
| `0x01` hello | phone → Mirror Wall | JSON: `protocol` (1), `name`, `model`, `deviceID` |
| `0x81` welcome | Mirror Wall → phone | JSON: `protocol` (from 0.93; absent means 1), `slot` (its name), `maxFrameRate` (30 or 60, View › Frame Rate Limit), `sharpPicture` (View › Sharper Picture: send H.265 up to 2160 pixels tall if the phone can) |
| `0x82` busy | Mirror Wall → phone | JSON: `reason`, shown on the phone; Mirror Wall then hangs up |
| `0x02` video | phone → Mirror Wall | 8-byte big-endian capture time in microseconds (phone's steady clock), then one H.264 or H.265 access unit in Annex B. Keyframes carry the parameter sets (H.265: VPS, SPS, PPS) in front, which is how Mirror Wall tells the codec. |
| `0x03` paused | phone → Mirror Wall | none; the phone's screen turned off |
| `0x04` resumed | phone → Mirror Wall | none |
| `0x05` heartbeat | phone → Mirror Wall | none; every 2 seconds |
| `0x06` bye | phone → Mirror Wall | none; the phone stopped sharing |
| `0x84` ping | Mirror Wall → phone | 8 bytes, sent back unchanged in a pong; Mirror Wall sends one per heartbeat |
| `0x07` pong | phone → Mirror Wall | the ping's 8 bytes; gives Stats for Nerds its round trip |

The phone sends hello and waits for the answer before sending video. A slot that's showing a
phone (of either kind) answers busy. While an Android phone has a slot, the slot's uxplay is
stopped, so iPhones don't list it; when the phone leaves, the slot shows Disconnected and starts
a fresh uxplay, as after an iPhone. A slot showing a phone also withdraws its `_mirrorwall._tcp`
listing, so the app only lists free slots; the connected phone keeps its connection.

When the connection drops without a bye or busy (the slot restarted, for example to apply Sharper
Picture), the phone keeps its screen capture and reconnects to the same slot for up to a minute.

Capture times become the 90 kHz RTP timestamps the rest of Mirror Wall uses, so Smoother Motion
and recording pace Android pictures the same way as iPhone ones.

## Compatibility

Every Mirror Wall Cast app has to work with every Mirror Wall (Mac or Windows) that speaks the
protocol, older or newer, and the other way round, because phones and computers get updated at
different times. So:

- The message layout (type, length, payload) never changes, and a message type never changes
  meaning or payload layout. Retired types are never reused.
- Both sides skip message types they don't know, and ignore JSON fields they don't know.
- New JSON fields are optional, and a missing one means what older versions did.
- `protocol` in hello and welcome is the newest version each side speaks; each side uses the
  lower of the two. A behaviour that needs both sides to agree (a new kind of video, for
  example) waits until both have said a version that has it. Version 1 is everything above.
- Nobody turns the other side away for its version. A phone with a newer version than Mirror
  Wall knows is welcomed as the newest version Mirror Wall knows.
- Version 1 stays supported for good: an app from now on must still work with Mirror Wall 0.90,
  and a Mirror Wall from now on with the Mirror Wall Cast 0.87 app.

The Mac tests (`CastProtocolTests`) and the Windows tests hold the version 1 messages exactly
as 0.90 sent them, so a change that breaks an older peer fails the build.


## Intentional stop extension (Mac SE fork)

Protocol 1 retains its framing. The phone's hello may include `shareID`, a UUID created for each
user-started share and retained across automatic retries. Older receivers ignore the field.
The Mac sends `0x83` with an empty payload to intentionally end sharing. Updated companions stop
capture and do not retry; unknown message types remain skippable for older companions.
The Mac also refuses the stopped device/share pair for 70 seconds, covering the legacy 60-second
retry window if the stop message is lost. Older clients without `shareID` are refused by device
ID during that cooldown. A fresh Share from an updated companion uses a new share ID immediately.

Current Mac and Windows receivers send pings in response to heartbeats. The companion allows
15 seconds without a response after welcome before treating the connection as lost. Its outbound
queue is bounded and closing it wakes a waiting sender. No protocol version bump is needed for
these optional, backward-compatible additions.

This transport still uses plain TCP and self-reported IDs. Deploy on a dedicated/trusted SE demo
network; the AirPlay PIN does not protect Android connections. Authenticated encrypted pairing
is a separate future change, not implied by the stop-sharing extension.

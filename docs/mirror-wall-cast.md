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
| `0x81` welcome | Mirror Wall → phone | JSON: `slot` (its name), `maxFrameRate` (30 or 60, View › Frame Rate Limit), `sharpPicture` (View › Sharper Picture: send H.265 up to 2160 pixels tall if the phone can) |
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

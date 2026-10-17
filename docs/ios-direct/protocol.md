# iOS Direct protocol v1 (synthetic) and v2 (video)

G3a joins G1 capture/encode to the G2 direct TLS transport. The G1/G2 hardware
evidence remains in [results](results.md), runs 1–7. G3a is source implementation;
background **network send**, decode/display, rotation and reconnect need a new
phone/Mac run. This document specifies the current wire format and bounds.

## G2-only security and discovery

Receiver startup (and **New code**) obtains ten random bytes from
`SecRandomCopyBytes`. Encode these 80 bits, most significant bit first, as sixteen
Crockford-base32 symbols (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`), displayed in four
four-character groups. There is no checksum. Input is case-insensitive, ignores
hyphens/whitespace, accepts Crockford O→0 and I/L→1 aliases, and rejects other
characters or any length other than sixteen symbols. Decode to the original ten
bytes, not the UTF-8 spelling, before deriving the PSK:

```text
HKDF-SHA256(inputKeyMaterial = ten decoded code bytes,
            salt = UTF8("mwiospoc-g2-psk-v1"), info = empty, output = 32 bytes)
PSK identity = UTF8("mwiospoc-g2")
```

`NWParameters(tls:tcp:)` uses `sec_protocol_options_add_pre_shared_key`,
`sec_protocol_options_append_tls_ciphersuite` with
`TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8), and min/max protocol **TLS 1.2**
(0x0303). On ready, both endpoints additionally check the negotiated metadata
before receiving application frames. No plaintext or certificate-trust bypass
path exists. A wrong code must fail the handshake: no hello/welcome/data may be
processed; the phone displays “wrong code / handshake failed” plus the actual
failure. That label also covers other pre-ready connection failures; it is not a
cryptographic diagnosis of the cause. A 1.5-second client TLS/welcome deadline handles stalls; `.waiting(.tls)` fails immediately.
Codes/PSKs are never written to telemetry or preferences. Only the install UUID
persists on the phone. **New code** cancels the listener and all connections,
clears admission, and starts a new listener/credential.

**This is a G2 test credential, not final pairing.** Possession authenticates both
ends as holders of the same per-run secret. All phones in a run share it; their
install UUIDs and display labels are self-reported, not cryptographic identities.
TLS-PSK here has no forward secrecy. QR pairing, per-device identities, approval,
revocation, key storage/rotation and production threat review belong to G3b.
G3a uses this unchanged test security for explicitly consented screen content.
`RadioTLS.parameters(code:)` remains the replaceable security boundary.

The service is Bonjour `_mwiospoc._tcp`, with a dynamic listener port.
`includePeerToPeer = true` is set on browser, listener and every outgoing
connection's parameters. Accepted connections inherit listener TLS/TCP settings.
TCP `noDelay = true`. Sender connects directly to the selected browse result's
`NWEndpoint.service`, retaining its domain/interface, with no IP substitution.
Only the macOS integration tests use an explicit 127.0.0.1 listener/endpoint;
that tests framing/security/admission, not Bonjour or direct radio routing.

Installed MacOSX27.0 and iPhoneOS27.1 SDK public Security headers are the spelling
reference (`SecProtocolOptions.h`, `CipherSuite.h`, `SecProtocolTypes.h`,
`SecProtocolMetadata.h`). The PSK cipher is converted from `SSLCipherSuite` to
`tls_ciphersuite_t` by its UInt16 raw value. Apple's
[TicTacToe sample description](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol)
uses Bonjour/TLS; [TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
documents TLS-PSK's TLS 1.2/older-Network-API constraints. G2 runtime evidence is recorded separately in results; G3a compiler/runtime
confirmation requires the README commands and a new device run.

## Framing and binary messages

All multi-byte integers are unsigned, big endian. No alignment/padding. Stream
header is exactly ten bytes:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `MWPD` (`4d 57 50 44`) |
| 4 | 1 | framing version = 1 or 2 (fixed for a session) |
| 5 | 1 | message type below |
| 6 | 4 | body length, at most 65,536 bytes |
| 10 | length | body |

Length covers the whole message body. Thus the maximum synthetic byte array in
a `data` body is **65,516 bytes**, leaving twenty bytes for sequence, time and CRC;
the app currently sends 16,384-byte arrays. This respects the 64 KiB record limit
without allocating an extra oversized record. Empty synthetic arrays are invalid.
Control strings use `text = u16 byteLength | UTF-8 bytes`, at most 256 bytes each;
UUIDs use that same text representation of canonical hyphenated UUID strings.
A control body must end exactly after its fields; no ignored trailing bytes.

| Type | Value | Body |
| --- | --- | --- |
| hello | 1 | installUUID:text, displayLabel:text, protocolVersion:u8, requestedMbit:u32, window:u8; v2 adds mode:text |
| welcome | 2 | sessionUUID:text, receiverLabel:text |
| reject | 3 | reason:text (`capacity`, `version`, `busy`) |
| data | 4 | seq:u64, sendMonotonicNs:u64, syntheticBytes, CRC32:u32 |
| ack | 5 | seq:u64, echoedSendMonotonicNs:u64, totalReceivedBytes:u64 |
| ping | 6 | echo:u64 |
| pong | 7 | echo:u64 |
| stats | 8 | UTF-8 JSON `RadioSnapshot`, maximum 8,192 bytes |
| bye | 9 | reason:text |

Only `stats` uses JSON; no base64 and no JSON envelope for synthetic data or the
other control messages. CRC32 is standard reflected IEEE (polynomial 0xEDB88320,
initial/final XOR 0xFFFFFFFF), over **syntheticBytes only**. Test vector
`123456789` → 0xCBF43926. Deterministic byte `i` in sequence `s` is `(s+i) mod 256`.
Sequence starts at zero per session and increments per data message. Receiver
checks CRC and counts skipped sequences; repeated/regressing sequences, empty
data, or CRC failure close only that session. Payload bytes are counted/discarded,
never written to disk. Total received bytes counts validated synthetic bytes,
excluding headers, TLS overhead and control records.

Incremental parsing accepts partial headers/bodies, multiple coalesced frames and
arbitrary fragmentation. It retains at most one ten-byte header plus one bounded
body. Magic/version/type/length are checked at header completion **before appending
any body bytes**. Bad magic, unknown version/type, oversize length, malformed
control fields and EOF in a partial frame poison the parser and close with a
logged reason. EOF at a frame boundary closes normally. Network receives are
capped at 32,768 bytes; there is no unbounded frame array or resynchronization.

## Admission, independence and shutdown

Up to two active sessions and two pending TLS/hello handshakes. The five-second
hello deadline starts when the listener accepts a connection, covering TLS too.
A ready client must send exactly one hello and wait for welcome before screen/synthetic data or
other controls. Hello accepts v1 synthetic and v2 synthetic/video. Version/rate mismatch returns `reject version`; an already
active install UUID returns `reject busy`; two active sessions return **`reject
capacity` over TLS** to a third correctly authenticated client. The reject is
flushed before cancellation (one-second upper bound). Rejected connections remain
pending until closed so they cannot bypass the pending limit.

If both pending slots are already occupied, another socket is canceled before
starting TLS, with `listener.capacity` in the receiver log. An application-layer
reject cannot be authenticated before a handshake; starting that handshake would
exceed the explicit two-pending limit. This overload case is a transport refusal,
whereas an authenticated third active client gets the explicit protocol reject.

Admission and install UUID uniqueness are serialized on the listener queue.
Each session UUID owns a distinct serial queue, parser, counters, ping/RTT window
and bounded sends. Labels are never keys, so equal labels do not merge sessions.
Disconnect/CRC/protocol failure releases only that session's admission. Closing
one does not cancel the listener or another phone. Receiver restart/New code
intentionally closes all sessions. Bye carries a reason and is flushed with a
one-second bound; transport/protocol failures cancel immediately.

## Pacing, acknowledgements and diagnostics

Default 12 Mbit/s; options 2/6/12/24, decimal bits per second of synthetic bytes.
The sender uses monotonic, one-shot deadlines; missed deadlines do not create a
catch-up burst. It creates a record only when eligible, with one data send awaiting
`contentProcessed` at a time. The outstanding ACK map counts data body plus the
ten-byte header, bounded by `min(150000, targetBytesPerSecond * 0.1)` (25,000 /
75,000 / 150,000 / 150,000 bytes). At the cap it waits for ACK/send completion;
no synthetic backlog is queued. “Send blocked ms” is cumulative time blocked by
that cap or an unfinished network send **after the next pacing deadline**.
Every validated data message gets an ACK. The sender verifies the matching
sequence, echoed timestamp and cumulative total; only those ACKs advance delivered
Mbit/s. Successful `contentProcessed` advances sent Mbit/s separately. Outstanding
ACKs older than ten seconds close the session rather than growing a backlog.

Each active endpoint sends a separate ping each second, independently of data
pacing. At most one is pending per direction; a missing pong for ten seconds
closes the session. RTT uses only echoed timestamps from the same process's
monotonic clock. Median and nearest-rank p95 cover the last ten seconds (at most
100 samples); no sample means absent, not zero. This is round-trip control delay,
not one-way media latency. All pending network sends, including control traffic,
are additionally capped at 262,144 application bytes per channel; overload closes
that session. No claim is made about opaque TLS/kernel buffering.

Both apps persist per-second `radio.metrics` JSONL plus state/error/path/viability/
better-path events. Receiver listener and phone browser also log their state each
second, including when no session exists. Samples include session/installation
mapping, NWPath status, available interface names/types/indexes, used wifi/wired/
other flags, expensive/constrained flags, local/remote endpoints when exposed,
negotiated TLS version/cipher, sent/delivered rates and cumulative bytes,
application wire byte counts, RTT p50/p95, gaps, CRC errors, outstanding bytes,
pending network bytes, cumulative blocked ms, thermal state and resident memory.
Receiver “delivered” is CRC-validated bytes with ACK submitted; sender delivered
is the decisive ACK-confirmed value. Phone samples mirror gaps/CRC values from
received receiver stats; until stats arrive the UI says unavailable. Metadata
logs contain endpoints, install UUIDs and labels; review before sharing.

Phone: `Documents/IOSDirectPOC/logs/radio-*.jsonl`. Mac:
`~/Documents/IOSDirectPOC-Receiver/logs/radio-*.jsonl` (container Documents if
sandboxed in a later configuration). Directories are created. Writes/fsync run on
a dedicated disk queue with a 128-record bound; overflow/write failure remains
visible in the UI. Metrics remain cumulative per connection, with rate deltas over
actual elapsed sample time. Missing path/TLS/RTT/memory stays absent. Interface
names and `.wifi` do not prove an AP-free path. OS suspension can interrupt foreground-only Radio
mode. Stream mode uses the existing G1 screen-capture execution mode only.


## G3a v2 video records

The 10-byte framing header and 65,536-byte body cap are unchanged. The header
version equals the hello's protocol version; subsequent records keep that version.
Video records under a v1 header and version changes within a session close it.
Original v1 hello bodies lacking a window byte still imply Latency. Window byte
0 = Latency, 1 = Capacity probe. v1 mode is implicitly `synthetic`; v2 **requires**
the text `synthetic` or `video` after window. A video hello must use Latency.
The Stream sender advertises 6 Mbit/s, matching its encoder target. Synthetic
rates, including 36/48 Mbit/s capacity probes, keep their G2 behavior.

| Type | Value | Body (unsigned big-endian, no padding) |
| --- | --- | --- |
| videoConfig | 10 | generation:u32, width:u16, height:u16, orientation:u8, rectPresent:u8, optional contentRect:4×f64, avcC:remaining bytes |
| videoFragment | 11 | generation:u32, frameSeq:u64, ptsNs:u64, flags:u8, fragmentIndex:u16, fragmentCount:u16, totalLength:u32, fragmentBytes:remaining bytes |
| keyframeRequest | 12 | reason:text |
| videoAck | 13 | frameSeq:u64, echoedPtsNs:u64, decodeStatus:u8 |

`videoConfig` includes a one-byte presence flag and, when present, the SCK
content rect's x/y/width/height as four IEEE-754 binary64 bit patterns (big endian).
These are **source attachment coordinates**, not encoder-scaled crop coordinates;
they are diagnostic metadata and do not crop the image. All must be finite.
The remaining bytes are the complete AVCDecoderConfigurationRecord (`avcC`),
including SPS/PPS. NAL length size must be 4. SPS/PPS lengths/types are validated;
optional high-profile avcC extensions can follow the PPS list. Dimensions must
be 2…4096 and match the dimensions parsed by CoreMedia from the SPS. Orientation
is the raw 1…8 `CGImagePropertyOrientation` from `SCStreamFrameInfo.videoOrientation`
(default 1 if absent). The Mac layer applies that orientation, swapping its
viewport for quarter turns and preserving aspect with black letterboxing. Raw
buffer dimensions, orientation and source rect are logged on format changes.
Actual rotation correctness remains a device observation, including whether SCK
already orients any delivered buffers; compare asymmetric moving content.

Config is sent after welcome and before the first frame of each generation.
Encoder recreation, delivered size/orientation/rect changes and reconnect establish
a fresh wire generation. Every IDR repeats its config to repair missing-config
state. An identical config is idempotent; a changed config with the same generation
or a regressing generation closes the session. Generation is per authenticated
connection, and never identifies another phone.

Fragment flags: bit 0 = keyframe; all other bits must be zero. Frame bytes are
unchanged AVCC access units from VideoToolbox, with 4-byte big-endian NAL lengths;
no Annex B conversion, base64 or re-encoding. Fragment metadata is 29 bytes, so
`fragmentBytes` is at most **65,507 bytes**, which is also ≤ the existing
`RadioFrame.maxData` (65,516). Index is zero based, count is nonzero, bytes are
nonempty. Total access-unit length must be 1…1,048,576; larger totals close the
session before reassembly allocation. Encoder output above that cap is dropped
before copying. The renderer additionally validates the complete AVCC NAL chain.

Each session retains at most **one** partial frame, with a 1 MiB total cap.
Fragments must arrive in order with identical generation/seq/PTS/flags/count/total.
Missing first/middle/last fragments, duplicates within an unfinished frame,
inconsistent metadata, replacing an unfinished frame and a one-second partial-frame
timeout abandon that frame. Remaining fragments of an abandoned/completed sequence
cannot reopen it or produce duplicate ACKs. Abandonment emits a dropped ACK and
requests an IDR; the decoder flushes and drops inter frames until a keyframe.
Missing config and decode errors use the same recovery rule. Keyframe requests
are limited to four per second per session. No cross-session reassembly/decoder
state exists.

`videoAck` statuses: 0 = successful decode output (pixel buffer), 1 = dropped,
2 = decode error. Each assembled frame gets an ACK from the consumer's result;
an abandoned partial frame gets a dropped ACK. Mere VT submission is not decoded
success. ACKs echo the frame's PTS exactly and release that frame's outstanding
wire bytes even for drops/errors. Sequence/echo must match the sender's outstanding
map; unknown/duplicate ACKs close it. No cumulative synthetic-byte total is used
for video. RTT measures local time from first-fragment admission through ACK
receipt (including decode), with p50/p95 from the last ten seconds; it does **not**
subtract clocks on different machines. `ptsNs` is the sender's original monotonic
SCK presentation timestamp converted to ns. Ping/pong remains independent.

## Stream queue, reconnect and stage evidence

The network sink has its own serial worker. Encoder admission uses a lock around
`VideoSendQueue`; dispatch blocks never retain a backlog of incoming media.
Queued units are bounded by 1 MiB and 100 ms; expiry is checked on admission,
dequeue and a 10 ms worker tick. An overflow/expiry/generation discontinuity clears
the queued prediction chain (including queued inter frames and any obsolete IDR),
counts the reason, requests IDR and rejects inter frames until the next keyframe.
The already admitted in-flight frame finishes in order; nothing after the gap is
sent until a fresh IDR. Decoder errors and keyframe requests also clear the chain.

Before sending any fragment, the **entire frame's wire size** (data plus all
39-byte fragment headers/metadata) is charged against G2's Latency cap:
`min(150000, 6000000 / 8 * 0.1)` = **75,000 bytes** at 6 Mbit/s. Frames larger
than this cap are dropped with `latencyWindowOversize` and force IDR. This is an
explicit tradeoff: a frame cannot be partially sent into a smaller window while
waiting for its own per-frame ACK. The 1 MiB wire/reassembly cap still applies to
other conforming clients. If real screen IDRs repeatedly exceed 75 KB, G3a will
stall truthfully in the logs; revisit bitrate/window/protocol with measured
hardware evidence. There is no hidden cap increase. A single in-flight unit is
separate from the bounded waiting queue; it is ≤ the window. Fragment sends are
serialized through successful `contentProcessed`, and all channel sends retain
the existing 262,144-byte application backlog bound. ACK timeout is ten seconds.

Connection loss clears queued/outstanding media and stops send admission while
capture/encoding remain authorized and running. The worker retries the selected
Bonjour service endpoint with backoff **0.5, 1, 2, 4, 4… seconds**, using a fresh
TLS connection/session each time. Welcome resets backoff, clears stale frames,
resends config and forces IDR. Retry does not depend on main/UI execution and
never calls capture start or presents a picker. System/user capture stop remains
stopped even if authentication later recovers. A first-use/wrong-code failure also
retries until Disconnect so the code can be corrected by reconnecting explicitly.
There are no added background modes, audio, background tasks or capture extensions.

Sender's existing `metrics` JSONL now includes captured/paced/encoded/sent/ACKed
FPS, sent Mbit/s and a nested `video` snapshot: successful sent frames/bytes,
all ACKs and successful decode ACKs, queue bytes/age, outstanding bytes, drop
counts by reason, keyframe requests, reconnect attempts/successes and frame-ACK
RTT p50/p95. Existing cumulative capture/encoder/keyframe/drop counters, appState,
thermal and memory remain in the **same sample**. Every lifecycle/retry/connection
event includes cached appState. A separate radio JSONL records TLS/path details.
Sender counts full frames sent only after all fragment `contentProcessed` callbacks.

Each Mac session owns its renderer, private decode queue, at most two pending VT
callbacks, layer, window and `video.receiver.metrics` JSONL. Config/gap/error/close
invalidate old callback epochs. Metrics include received/decoded/displayed totals
and FPS, decode errors, presentation drops, requested IDRs, last frame bytes,
received Mbit/s, ten-second inter-arrival p95, longest gap, dimensions/orientation,
thermal and memory. **Displayed means successfully decoded and enqueued to the
AVSampleBufferDisplayLayer**, not physical scanout. Failed/unready layers do not
advance that counter. Output timeout resets decode and requests IDR. After one
second without display the state is stalled (static SCK content can also cause
this); disconnect removes the stale picture and marks the window disconnected.
Stats can be hidden per window. Synthetic sessions retain the existing row UI.

Transport-only TLS loopback tests inject a consumer that returns a chosen status
after checking identical config/frame bytes; those tests prove neither actual
H.264 decode nor background/radio routing. The human Stream run and optical clock
measurement in the prototype README remain required before accepting G3a.

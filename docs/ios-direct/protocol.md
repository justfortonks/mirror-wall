# iOS Direct protocol v3 — offline pairing and authenticated video

G3b replaces the typed G2 test credential in both Radio and Stream. The G1 capture,
G3a video wire bodies and receiver presentation policy remain independent of the
new authentication gate. Historical device observations stay in [results](results.md).

## Security model and discovery

Every connection uses Network.framework TLS **1.2** with
`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (**0xCCAC**). Real macOS loopback tests
force this suite alone and verify negotiated metadata at `.ready`; they also
exercise two distinct registered device keys concurrently. No AES fallback was
needed on the installed macOS 27.0.1 / MacOSX27.0 SDK. Both production endpoints
reject any other negotiated suite or TLS version before processing application
bytes. The suite supplies ephemeral ECDHE forward secrecy; there are no provisioned
certificates, trust bypasses, plaintext listeners, or online pairing services.
TLS tickets and resumption are disabled so a previous session cannot bypass a
changed key set. The iOS SDK source check passes; on-phone negotiation remains a
device acceptance step. Apple's [TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
describes the older `NWConnection` TLS-PSK API's TLS 1.2 constraint.

The Mac creates a random UUID `receiverID` and display name once, persisting them
in `receiver-identity.json` next to its logs. Bonjour `_mwiospoc._tcp` advertises
`rid=<canonical UUID>` and `v=3` in its TXT record. TXT, receiver names, phone labels,
models and install UUIDs are **routing/display hints**, never authentication.
The phone browses TXT records and connects to the matching service endpoint,
retaining its domain and interface. No IP substitution or server access is needed.
Browser, listener and outgoing connections set `includePeerToPeer = true`; TCP
sets `noDelay = true`. Only tests bind explicitly to 127.0.0.1. Loopback does not
prove Bonjour, AWDL routing or offline device behavior.

### QR invitation and approval

**Pair New Device** obtains 8 random token-ID bytes and 32 random secret bytes
from `SecRandomCopyBytes`. The invitation expires after 120 seconds, is single
use, and is held only in memory. The Mac renders this URI using CoreImage;
`tid` and `sec` are canonical base64url without padding:

```text
mwiospoc://pair?v=1&rid=<uuid>&tid=<tokenID>&sec=<secret>&exp=<unix seconds>&name=<urlencoded>
PSK identity = "pair:" + base64url(tokenID)
PSK = HKDF-SHA256(secret, salt=UTF8("mwiospoc-pair-v1"),
                  info=UTF8(canonical receiverID), output=32 bytes)
```

The parser checks the scheme/host, exactly six unique fields, version, UUID,
base64url alphabet/canonical encoding/exact decoded lengths, finite integer expiry,
and nonempty bounded name. Phone expiry validation allows 30 seconds of clock skew
in either direction around the 120-second lifetime. The Mac independently enforces
its own expiry with no grace period, including during approval. Cancel, regenerate,
denial, expiry or three failed pre-authentication connections burn the token and
replace the listener. Pairing never enables media admission.

**SDK limitation:** `sec_protocol_metadata_access_pre_shared_keys` exposes locally
configured keys, not a failed peer's selected identity. The public PSK selection
callback is client-side. Therefore every accepted connection that fails before
application authentication while an invitation is active conservatively consumes
one of its three attempts, including an unrelated device failure or timeout.
Refusal at the two-pending limit does not start a handshake and does not count.
This bounds guessing attempts but permits denial of service against an invitation;
regenerating the QR recovers. No failure is attributed to a specific phone without
a valid proof.

After TLS and the challenge exchange below, the phone sends
`pairRequest {installID, label, model}`. Only one session may reserve an invitation.
The Mac asks **Allow "<label>" (<model>) to mirror to this Mac?** with Allow/Deny;
expiry dismisses the request and auto-denies. On Allow it persists a fresh UUID
`deviceID` and 32-byte device key in Keychain, sends `pairGrant`, and awaits
`pairDone`. The phone stores the grant before sending `pairDone`. The Mac commits
non-secret metadata, burns the token, rebuilds the listener, and acknowledges with
`bye paired`. The pairing socket then closes; a fresh normal connection is required
for Radio or Stream. Denial sends `pairDenied`, burns the token and closes.
An interrupted grant is removed on the Mac; the phone removes an unacknowledged
provisional grant. If the final acknowledgement is lost after Mac commitment,
pair again and forget the orphan entry on the Mac. No distributed commit is claimed.

### Per-device authentication and revocation

Normal TLS identity is `dev:<canonical deviceID>` and PSK is that device's
32-byte key. The listener calls `sec_protocol_options_add_pre_shared_key` once
per paired identity plus once for an active invitation. Adding/removing credentials
replaces only the listener. Already admitted connections retain their own queues,
TLS state and renderer; no listener restart cancels them.

Immediately after TLS `.ready`, the Mac sends 32 fresh random nonce bytes:

```text
authChallenge {nonce}
authResponse {deviceID, proof}
proof = HMAC-SHA256(deviceKey,
        nonce || UTF8(receiverID) || UTF8(deviceID) || UTF8("mwiospoc-auth-v1"))
```

UUIDs here use uppercase, hyphenated `UUID.uuidString`, without length prefixes
inside the HMAC input. A pairing response uses its full `pair:<tokenID>` identity
in the `deviceID` text field and the token-derived key. The Mac looks up the
claimed identity's current key and compares all 32 proof bytes with a constant-time
accumulator. It never routes by a self-reported install UUID or label. Device A's
TLS key plus device B's claimed ID cannot pass B's HMAC check. A fresh nonce and
receiver ID bind the response to this connection and receiver.

The challenge response deadline is five seconds after ready; the existing
five-second TLS/auth/hello pending deadline also bounds normal admission from
acceptance. Authenticated pairing approval is exempt from that earlier deadline
and remains bounded by token expiry. No hello, synthetic/video data, decoder,
capture consent or session controls are admitted before authentication. A normal
v3 hello follows the proof; `welcome` follows verified admission. v1/v2 sessions
are rejected even if their legacy bodies can be decoded by the shared parser.

Mac **Forget** deletes that device's key, replaces the listener, and sends
`bye revoked` only to sessions routed to its verified deviceID. Admission rechecks
the current store, so a socket accepted by an older listener cannot resurrect a
revoked key. Other phones keep streaming. Phone **Forget this Mac** deletes its
Keychain item and stops its connections/capture to that receiver. It must scan and
pair again. An authenticated `bye revoked` removes the phone's stored pairing too.
A TLS failure alone cannot distinguish revocation from a wrong key or impostor;
the phone stops and reports **"This Mac didn't accept this phone. It may have been
forgotten on the Mac."** with **Pair again** and **Forget this Mac**. The credential
is retained, and the receiver is marked **Pairing rejected** instead of Paired.
Non-secret rejection state is shared by Radio/Stream and persists across relaunch.
An authenticated `bye revoked` deletes the matching device credential automatically
and reports **"This Mac forgot this phone. Pair again to reconnect."** A delayed
revocation from an older device identity cannot delete a newly paired credential.
It never infers trust from a matching TXT `rid`.

**Scan pairing code** is available for every receiver, including already paired or
rejected receivers. Validation precedes any connection or interruption of an
existing session, checks the receiver selected when the scanner opened, and shows
"This pairing code has expired — make a new one on the Mac", "This code is for a
different Mac", or "Not a pairing code". Expiry retains the 30-second phone clock
skew and the independent hard Mac expiry. Successful re-pairing replaces the phone's
stored credential for that `rid` and clears its rejection status. Validated re-pairing
stops the old session before requesting approval; invalid scans leave it alone.

Both apps use Generic Password Keychain items with service
`com.justfortonks.mirrorwall.iosdirectpoc`, no synchronization, and
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Mac account is `deviceID`, value
is the raw key; phone account is `rid`, value is the credential (deviceID/key/rid/name).
`paired-devices.json` contains only labels, model, install/device IDs and created/
last-seen times. Storage is behind `PairingKeyStore`; tests use an in-memory store.
Storage failures do not grant admission. Keychain behavior, camera permission and
persistence across signed app relaunch still require device/app acceptance.

QR payloads, secrets, derived PSKs, proofs and device keys never enter application
logs. Tests capture JSONL and assert the payload and secret/key base64, base64url
and hex encodings are absent. Endpoint, session/install/device IDs and display
labels remain metadata: review logs before sharing. Protect the QR from observation;
its possession plus explicit Mac approval is the offline bootstrap authority.
This POC does not attest hardware or protect a compromised paired endpoint.

## Framing and binary messages

All multi-byte integers are unsigned, big endian. No alignment/padding. Stream
header is exactly ten bytes:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `MWPD` (`4d 57 50 44`) |
| 4 | 1 | framing version = 3 (fixed for a session) |
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
| hello | 1 | installUUID:text, displayLabel:text, protocolVersion:u8, requestedMbit:u32, window:u8, mode:text |
| welcome | 2 | sessionUUID:text, receiverLabel:text |
| reject | 3 | reason:text (`capacity`, `version`, `busy`) |
| data | 4 | seq:u64, sendMonotonicNs:u64, syntheticBytes, CRC32:u32 |
| ack | 5 | seq:u64, echoedSendMonotonicNs:u64, totalReceivedBytes:u64 |
| ping | 6 | echo:u64 |
| pong | 7 | echo:u64 |
| stats | 8 | UTF-8 JSON `RadioSnapshot`, maximum 8,192 bytes |
| bye | 9 | reason:text |
| authChallenge | 14 | nonce:32 raw bytes |
| authResponse | 15 | deviceID (or pair identity):text, proof:32 raw bytes |
| pairRequest | 16 | installID:text, label:text, model:text |
| pairGrant | 17 | deviceID:text, deviceKey:32 raw bytes, rid:text, receiverName:text |
| pairDone | 18 | empty |
| pairDenied | 19 | empty |

Only `stats` uses JSON on the wire; no base64 or JSON envelope for media or
other control messages. The phone Keychain credential is encoded as JSON locally. CRC32 is standard reflected IEEE (polynomial 0xEDB88320,
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

Up to two active sessions and two pending TLS/auth/hello or pairing connections.
The five-second normal admission deadline starts on acceptance. A ready client
must answer the challenge, send exactly one v3 hello, and wait for welcome before
screen/synthetic data or controls. Hello requires `synthetic` or `video`; video
requires Latency. Version/rate mismatch returns `reject version`; an already active
verified deviceID returns `reject busy`; two active sessions return **`reject
capacity` over TLS** to a third authenticated client. Rejections flush before
cancellation (one-second bound). Rejected connections remain pending until closed.

If both pending slots are already occupied, another socket is canceled before
starting TLS, with `listener.capacity` in the receiver log. An application-layer
reject cannot be authenticated before a handshake; starting that handshake would
exceed the explicit two-pending limit. This overload case is a transport refusal,
whereas an authenticated third active client gets the explicit protocol reject.

Admission and verified deviceID uniqueness are serialized on the listener queue.
Each session UUID owns a distinct serial queue, parser, counters, ping/RTT window
and bounded sends. Labels are never keys, so equal labels do not merge sessions.
Disconnect/CRC/protocol failure releases only that session's admission. Closing
one does not cancel the listener or another phone. Receiver Stop intentionally closes all sessions. Pairing and listener/key-set
changes preserve admitted sessions except the specifically revoked device. Bye carries a reason and is flushed with a
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


## Video records (G3a payloads, v3 framing)

The 10-byte header and 65,536-byte body cap are unchanged. Every record in a
network session uses v3. Legacy v1/v2 hello decoding remains only for parser
regression/rejection coverage; the channel never accepts those versions. Window
0 = Latency, 1 = Capacity probe; mode is required text `synthetic` or `video`.
Video uses Latency, at the Stream encoder's 6 Mbit/s target. Synthetic rates,
including 36/48 Mbit/s capacity probes, preserve their pacing/window behavior.

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

Before sending any fragment, the **entire frame's wire size** is charged against
Latency's **75,000 bytes** at 6 Mbit/s. The earlier review fix is preserved: an
oversized unit (typically an IDR) is admitted **alone when no frame is outstanding**
and counts `oversizeAdmittedAlone`. It remains bounded by the 1 MiB access-unit
limit plus fragment overhead. This avoids an endless oversize/drop/IDR cycle.
A single in-flight unit is separate from the 1 MiB/100 ms waiting queue.
Fragment sends are serialized through successful `contentProcessed`; all channel
sends retain the 262,144-byte backlog bound. ACK timeout is ten seconds.

Capture and transport have independent lifetimes. User/system **Stop capture**
clears capture busy state without calling transport stop. While the authenticated
connection remains live, **Share full display** is immediately available for a new
explicit consent; encoder restart sends a new wire generation, config and IDR on
the same session. Frame sequence remains monotonic. **Disconnect** ends the session.
A reconnect never restarts stopped capture or presents consent.

On a genuine link loss from a session that reached `welcome`, the worker clears
queued/outstanding media and makes an automatic fresh TLS/authentication attempt
after 0.5 seconds. Each new attempt must itself reach `welcome` to become retryable:
a past session's success does not authorize retrying failed initial handshakes.
TLS errors, pre-welcome authenticated closes, a five-second deadline while TLS is
still `preparing` against a currently discovered receiver, and authenticated
`reject unpaired`/auth failures stop with pairing recovery UI. Capacity/busy,
protocol errors and normal peer bye also stop. `bye revoked` stops and deletes the
matching credential. Typed close causes control this policy; diagnostic strings
are not revocation authority. No authentication failure is retried indefinitely.

Discovery updates feed the worker's current receiver-presence flag. Returning to
the foreground refreshes Stream discovery. Stopping capture ends its background
execution grant: the OS can still suspend/abort the transport (run 1 logs show a
POSIX abort after system stop). Application code does not intentionally disconnect
on capture stop; uninterrupted OS socket retention needs another device run.
Loopback proves capture-generation reuse and transport recovery, not this OS
lifecycle behavior. No additional background modes, audio or background tasks.

Sender's existing `metrics` JSONL now includes captured/paced/encoded/sent/ACKed
FPS, sent Mbit/s and a nested `video` snapshot: successful sent frames/bytes,
all ACKs and successful decode ACKs, queue bytes/age, outstanding bytes, drop
counts by reason, keyframe requests, reconnect attempts/successes and frame-ACK
RTT p50/p95. Existing cumulative capture/encoder/keyframe/drop counters, appState,
thermal and memory remain in the **same sample**. Every lifecycle/retry/connection
event includes cached appState. A separate radio JSONL records TLS/path details.
Sender counts full frames sent only after all fragment `contentProcessed` callbacks.

Each Mac session owns its renderer, private decode queue, at most eight pending VT
callbacks with a 300 ms oldest-frame bound, layer and `video.receiver.metrics` JSONL. Config/gap/error/close
invalidate old callback epochs. Metrics include received/decoded/displayed totals
and FPS, decode errors, presentation drops, requested IDRs, last frame bytes,
received Mbit/s, ten-second inter-arrival p95, longest gap, dimensions/orientation,
thermal and memory. **Displayed means successfully decoded and enqueued to the
AVSampleBufferDisplayLayer**, not physical scanout. Failed/unready layers do not
advance that counter. Output timeout resets decode and requests IDR. After one
second without display the state is stalled (static SCK content can also cause
this); disconnect removes the stale picture and marks the window disconnected.
Immediate presentation coalesces decoded output; optional smoothing adds a bounded
100 ms PTS buffer. Recovery holds the last image using `flush()`; disconnect clears
it. Identical configs preserve the decoder. Stats can be hidden per window.
Synthetic sessions retain the existing row UI.

Mac windows are keyed by **HMAC-verified deviceID**, passed explicitly from admission
to the video consumer factory. The title is the stored device label; install UUID,
hello label and session UUID cannot merge or create a second window for that
device. A new session reuses its NSWindow/geometry and attaches a fresh session
renderer/layer. Disconnect clears the picture to **black** and shows **Disconnected**;
reuse shows **Waiting for video** until frames arrive. Samples from obsolete
sessions cannot update the rebound window. Manual window close removes its entry;
the device's next video session opens it again. Different paired identities retain
separate windows even when labels match.

Transport-only TLS loopback tests inject a consumer that returns a chosen status
after checking identical config/frame bytes; those tests prove neither actual
H.264 decode nor background/radio routing. The human Stream run and optical clock
measurement in the prototype README remain device acceptance work. G3b loopback
results and current build limitations are recorded in the prototype README and
handoff; this change does not alter the historical results ledger.

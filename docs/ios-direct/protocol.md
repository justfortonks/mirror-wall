# G2 synthetic radio protocol v1

2026-10-16. Source implementation only; the requested build/test commands are
sandbox-blocked. No signed installation, wrong-code runtime result, AP-free route,
throughput or two-phone gate pass is claimed. See the [test plan](test-plan.md).
The decisions in Brief G2 supersede the older G0 throwaway-certificate proposal
for this experiment. G1 still ends at its independent local stub sink.

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
cryptographic diagnosis of the cause. A ten-second client deadline handles stalls.
Codes/PSKs are never written to telemetry or preferences. Only the install UUID
persists on the phone. **New code** cancels the listener and all connections,
clears admission, and starts a new listener/credential.

**This is a G2 test credential, not final pairing.** Possession authenticates both
ends as holders of the same per-run secret. All phones in a run share it; their
install UUIDs and display labels are self-reported, not cryptographic identities.
TLS-PSK here has no forward secrecy. QR pairing, per-device identities, approval,
revocation, key storage/rotation and production threat review belong to G3.
Do not use this experiment for screen or sensitive data.

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
documents TLS-PSK's TLS 1.2/older-Network-API constraints. Compiler and runtime
confirmation remain pending the sandbox-free commands in the README.

## Framing and binary messages

All multi-byte integers are unsigned, big endian. No alignment/padding. Stream
header is exactly ten bytes:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `MWPD` (`4d 57 50 44`) |
| 4 | 1 | framing version = 1 |
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
| hello | 1 | installUUID:text, displayLabel:text, protocolVersion:u8 (=1), requestedMbit:u32 (2/6/12/24) |
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
A ready client must send exactly one hello and wait for welcome before data or
other controls. Hello version/rate mismatch returns `reject version`; an already
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
names and `.wifi` do not prove an AP-free path. OS suspension can interrupt Radio
mode: no background audio/task workaround or G1-to-radio payload link is added.

# iOS Direct POC — Capture, Radio, Stream and offline pairing

Independent iOS 27 sender and macOS 14+ receiver, using Xcode 27.1 / iPhoneOS27.1.
Capture uses ScreenCaptureKit → paced SDR H.264 VideoToolbox → bounded local stub.
Radio sends synthetic bytes. Stream sends the authorized display to an independent
Mac decoder/window. Both network modes now require **protocol v3**, offline QR
pairing, Mac approval and a per-device credential. The typed G2 code is removed.
No third-party libraries, production integration, audio workaround or extensions.

Historical hardware evidence is in [results](../../docs/ios-direct/results.md),
including the G3a presentation fixes. It is not G3b pairing acceptance. The
[protocol](../../docs/ios-direct/protocol.md) specifies the current security model,
wire format, admission, pacing, queue bounds and metadata semantics.

## Build and validation

Open `IOSDirectPOC.xcodeproj`; shared schemes are `IOSDirectSender` and
`IOSDirectReceiver`, both linking local `Shared`. Synchronized source groups pick
up the new files without project changes. Receiver `ARCHS=arm64` remains unchanged.
Automatic signing uses existing Personal Team `499JQDRQF9`, with isolated IDs
`com.justfortonks.mirrorwall.iosdirectpoc.sender` and `.receiver`. Receiver App
Sandbox remains OFF. No new entitlements or background modes are added. Camera
usage description is “Scans the pairing code shown on your Mac.” If provisioning
requests additional entitlements, report the actual requirement before changing it.

From the repository root:

```sh
set -o pipefail
(cd prototypes/ios-direct/Shared && swift test --disable-sandbox 2>&1 | tail -20)
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectSender \
  -destination 'generic/platform=iOS' -derivedDataPath prototypes/ios-direct/.build-xcode \
  -IDEPackageSupportDisableManifestSandbox=1 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectReceiver \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath prototypes/ios-direct/.build-xcode \
  -IDEPackageSupportDisableManifestSandbox=1 CODE_SIGNING_ALLOWED=NO build
git status --porcelain
```

**G3b local validation, 2026-10-16:** Shared **50 XCTest tests passed, zero failures**
with `--disable-sandbox`. Real Network.framework TLS loopback negotiated
**TLS 1.2 / 0xCCAC (`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`)**; AES fallback was
unnecessary. Tests cover pairing → Keychain-protocol memory storage → normal
connect, single-use and expired invitations, expiry auto-denial, explicit denial,
wrong secret/no application bytes, three failures burning the token, unknown
identities, concurrent distinct keys, verified-device separation, A claiming B,
isolated live video revocation, revoked reconnect, an impostor with the same
receiver/device IDs but a different key, legacy/unauthenticated media rejection,
capacity/busy/pending/deadline behavior, synthetic pacing telemetry, video framing/
reassembly/ACK/recovery, QR validation, metadata/key separation and secret-free
captured JSONL. The consumer in loopback injects decode results; it does not decode
H.264 or prove on-radio behavior. No Keychain calls are made by those tests.

Both requested unsigned `xcodebuild` commands, with the flag above and **without
`-packageCachePath`**, failed resolving the local package before app compilation:

```text
xcodebuild: error: Could not resolve package dependencies:
<unknown>:0: error: cannot open file '/Users/me/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia' for diagnostics emission (Operation not permitted)
```

CoreSimulator service warnings also appeared. As a separate source/API check,
Shared was emitted as an iOS module and **all Sender and Receiver Swift sources
passed `swiftc -typecheck`** against the installed SDKs (Swift 5 mode, arm64;
`-disable-sandbox` permits the compiler's SwiftUI macro process; temporary module
caches/artifacts were under `/tmp`). This is not a linked app build. Claude still
needs both Xcode builds, signed launches, Keychain persistence, camera permission/
scanning and physical phone/Mac acceptance. No installs, commits or pushes occurred.

## G3b-fix validation

**61 Shared tests pass**, including all previous security/decode policies and new
unit/real-TLS checks for terminal authentication failures, authenticated revocation
key deletion, post-welcome link recovery, exact invitation errors and receiver
mismatch, credential replacement, persistent rejection status, device/window
rebinding and obsolete-session filtering. Two capture generations send fresh
config/IDR over one authenticated TLS session in loopback. Both Sender and Receiver
also pass direct SDK source typechecks. No new signed build/install or physical
acceptance is claimed. Repeat the first-run pairing/system-stop/window scenarios
on devices; the historical results ledger is unchanged.

## G3c presentation and scanner fixes

Compared `a7ebbc0` → `afab209` and the local `g3a-run2` / `g3b-run2` logs.
The decode/presentation source was unchanged between those builds, and window
reuse happens at session admission, not per frame. In session `516FAE87`, early
received/decoded throughput is about 30 fps while newest-image presentation is
about 19 fps: burst completions supersede decoded images before enqueue. The
existing immediate scheduler added a forced 1 ms timer before presentation;
that extra coalescing interval is removed. Already queued burst completions still
show their newest image once, preserving the decode-all-reference policy. The
old inter-arrival p95 retained ten seconds of samples. It now uses only the last
one second, and becomes unavailable after that window has no arrivals.

The run does **not** establish a new G3b main-thread bottleneck: later active
samples recover to a 30 fps median, including the final two minutes. The source
of the earlier transport/decode bursts remains unproven without a device rerun.
Removing the extra timer does not promise 30 displayed fps from coalesced bursts.

All per-frame assembly, timing, decode, ACK and layer enqueue work stays on
session workers. UI snapshots are limited to two per second. Each once-per-second
`video.receiver.metrics` record includes `timing` summaries (count, p50/p95/max in
milliseconds) for `arrivalToSubmit`, `decode`, `completeToEnqueue`, `interArrival`.
Every summary is a bounded rolling last-one-second window. Arrival is the complete
assembled access unit, stamped before waiting for the decode queue; decode ends
at the VT callback before its queue hop; enqueue is a successful layer enqueue.
Completion-to-enqueue includes callback queue wait and optional smoothing; skipped
images have no enqueue sample. These timings distinguish worker/decode delays
from burst input, without per-frame log lines or physical scanout claims.
`longestGapMS` remains a session maximum, separately from the rolling quantiles.

The scanner is presented once from each screen's stable root with an independent
presentation object, instead of a sheet on a changing Form `Group`. A retained
native controller starts/stops the camera on appear/disappear; permission and
metrics updates do not recreate it. One scan is delivered after sheet dismissal.
Pairing uses typed attempt IDs/states, ignores a second in-flight scan with a
message, invalidates obsolete callbacks, and awaits cancelled-client cleanup
before starting another client. Missing Bonjour discovery fails visibly after
five seconds. Success refreshes the shared non-secret credential-presence cache
from storage and clears rejection in both tabs immediately; failure refreshes
it after provisional-key cleanup. An obsolete Stream rejection cannot update
a receiver after that stream was disconnected for re-pairing.

After Allow, the Mac burns an unconfirmed grant at four seconds and bounds final
message flushing to one second. The phone fails an unacknowledged saved grant at
four seconds, cleans its provisional credential, and shows a reason. Real-TLS
loopback checks both decision bounds; physical link loss can delay delivery of
any remote decision, so device/offline behavior still needs verification. Waiting
for the user's decision remains bounded by the invitation expiry. QR expiry and
the TLS/HMAC/Keychain security model are unchanged.

**G3c local validation: 71 Shared tests pass**, including a synthetic 300-frame
30 fps receive/decode/scheduled-presentation sequence (300 displayed, zero skips),
rolling timing expiry/queue delays, UI publication cadence, scan after rejection
and revoke, duplicate scan/cancel/stale callback handling, immediate stored-state
refresh, and two real-TLS decision/confirmation timeout cases. Sender and Receiver
pass direct arm64 SDK source typechecks. Both unsigned Xcode builds were attempted
with the documented manifest flag and no packageCachePath; both again stopped at
the `shared.dia` manifest-cache permission error above, before app compilation.
No linked/signed build or device acceptance is claimed.

Device rerun: keep the scanner open while metrics update; test its first tap and
camera permission, cancel/reopen, scan after rejection/revoke and denial, then
Allow and confirm both tabs show Paired without relaunch. Stream moving content
for several minutes with the new one-second stage timings, compare infrastructure
and offline phases, and retain the current newest-image policy. Confirm repeated
capture and per-device windows still behave as described below.

## Pair, connect and forget

1. Launch Receiver and allow local-network access. Wait for listener ready. The
   Devices section lists label, model, short deviceID, last seen, live/not live and
   **Forget**. Select **Pair New Device** to show a QR and countdown; Regenerate
   invalidates the previous QR, and Cancel invalidates the current invitation.
2. On the phone choose Radio or Stream and allow local-network access. Receiver
   rows show **Paired**, **Not paired** or **Pairing rejected**. **Scan pairing code**
   is always available, including for paired receivers. Select the intended Mac,
   allow camera access and scan its QR. A successful re-pair replaces its credential.
   Scanning can also start before discovery finishes; it waits for matching `rid`.
   The system scanner uses VisionKit, recognizing only QR barcodes.
3. On the Mac, inspect **Allow "<label>" (<model>) to mirror to this Mac?** and
   choose Allow or Deny. An unanswered request expires with the invitation.
   Wait for **Paired** on the phone. Pairing grants no capture consent and opens
   no renderer. The next connection uses the phone's own long-term key.
4. For Radio, select 2/6/12/24 Mbit/s (default 12), Latency or Capacity probe
   (also 36/48 Mbit/s), and **Connect**. Synthetic bytes start only after verified
   authentication and welcome. Stop ends only that session.
5. For Stream, tap **Connect**, wait for **authenticated; ready to share**, then
   **Share full display** and approve the system full-display picker. A window
   titled with the stored device label opens for this phone, keyed by its verified
   deviceID. A later session reuses that window; between sessions it is black with
   Disconnected / Waiting for video. Manual close reopens on the next session.
   Stop capture (including system stop) leaves the authenticated session available:
   **Share full display** enables again for fresh consent and a new config/IDR.
   Use Disconnect only to leave the session. Capture remains a separate regression
   mode; stop other capture runs before measuring Stream.
6. Mac **Forget** removes one device's key and ends only its live session with
   `bye revoked`. Other phones continue. An authenticated revocation removes the
   phone's stored pairing too. Phone **Forget this Mac** deletes its
   credential and stops its connections/capture to that receiver. Reconnecting
   requires another QR/approval. If a reconnect fails after an offline revocation,
   the phone stops retrying and shows "This Mac didn't accept this phone. It may
   have been forgotten on the Mac." Use **Pair again** or **Forget this Mac**.
   Ambiguous failure retains the key and marks Pairing rejected in both modes,
   including after relaunch. Authenticated revocation deletes the key and shows
   "This Mac forgot this phone. Pair again to reconnect."

Receiver UUID/name live in `receiver-identity.json`; non-secret phone metadata is
in `paired-devices.json`, both next to Mac logs. Secret keys are Generic Password
Keychain items, service `com.justfortonks.mirrorwall.iosdirectpoc`, account=deviceID
on Mac or rid on phone, `AfterFirstUnlockThisDeviceOnly`, not synchronized. The
phone's item contains the complete credential; Mac items contain only raw keys.
No credentials or QR payloads go into UserDefaults, JSON metadata or logs.

The invitation is 120 seconds, single-use, three failed pre-authentication attempts.
The phone validates 30 seconds of clock skew; the Mac has a hard expiry. The SDK
cannot expose a failed handshake's peer identity, so unrelated pre-authentication
failures during an invitation count toward that limit too. This conservative
behavior and interrupted-grant recovery are detailed in the protocol. Two active
sessions/two pending connections remain the limits; labels are display only.

## Physical acceptance still to run

Use benign changing content, with no debugger or USB during the measured run.
Record revision/dirty diff, phone alias/model/OS, Mac/SDK, signing/profile expiry,
radio associations and exact time. Repeat on both phones without adding an Apple
Account to phone B. Follow the decisive no-AP topology in the
[test plan](../../docs/ios-direct/test-plan.md). Interface names alone do not prove
AP-free routing.

- Scan/approve, deny, let an approval expire, cancel/regenerate, try an old QR, and
  scan on a phone whose clock differs slightly. Confirm camera denial is clear.
  Restart both apps and prove keys persist and reconnect requires no typing.
- Pair two phones, stream concurrently, Forget A on Mac and verify only A goes
  black/disconnects while B's decoded/displayed counters keep advancing. Verify
  A cannot reconnect until another QR/approval; repeat phone-side Forget.
- On Capture, cancel full-display consent first, then approve. On Stream, confirm
  the consent button stays disabled before authenticated welcome. Microphone and
  camera controls remain disabled in the capture picker; only `.screen` is added.
- Stream an asymmetric moving image; rotate both ways and compare actual pixels.
  SCK previously delivered portrait panel-oriented pixels with orientation 1;
  a successful source check does not establish a new rotation signal. Windows
  follow size/orientation metadata when it actually changes.
- Use the latency clock and photograph phone/Mac together for optical latency.
  Done dismisses only the clock. RTT and cross-machine timestamps are not optical
  glass-to-glass measurements.
- With the decisive no-AP setup, go Home for ten continuously changing unlocked
  background minutes. Check capture → paced → encode → send → ACK plus Mac
  received → decoded → displayed progress. Timer progress alone is insufficient.
- Interrupt/restore a link after welcome: expect a fresh authentication attempt
  after 0.5 seconds. An attempt that never reaches welcome is not retried; TLS/auth
  failure or a preparing deadline against a discovered Mac stops with pairing
  recovery controls. Test initial rejection and rejected reconnects separately.
- Stop capture from the app and system indicator. Share again on the retained
  connection; check new generation/config/IDR and one window for that device.
  Capture must stay stopped if a transport reconnect occurs. Run 1 showed that iOS
  may abort the socket shortly after capture's background execution ends; code
  does not close it on capture stop, and OS retention needs device verification.
  Test returning to foreground, background recovery and a longer soak separately.

## Preserved capture and stream behavior

G1 recovery invalidates only VT on failure, retries after 0.25/0.5/1/2 seconds,
creates a generation and forces IDR; valid output resets backoff. Source samples
use a two-frame mailbox, explicit 30 FPS PTS pacing, even/aspect fitting up to
1280×720 or 720×1280, SDR H.264 at 6 Mbit/s, real time, no frame reordering and
one-second keyframes. Unsupported SDK setters/readbacks stay unavailable. No
capture lifecycle, encoder or stub source was changed for G3b.

Stream queues remain bounded to 1 MiB/100 ms with prediction-chain/IDR recovery.
The 75,000-byte latency window charges a complete frame before fragments. The
review fix admits an oversized frame **alone when nothing is outstanding**,
counting `oversizeAdmittedAlone`; the 1 MiB access-unit cap remains. No endless
oversize-IDR drop loop is reintroduced. A network loss clears queued/outstanding
media without restarting the authorized capture pipeline.

Each Mac session preserves its private decoder, eight-frame/300 ms decode bound,
idempotent config, decode-all-reference policy and newest decoded presentation.
Immediate mode is default; optional smoothing adds a bounded 100 ms PTS buffer.
Recovery holds the last picture (`flush()`); disconnect clears it. Displayed means
successful decoded-image enqueue, not physical scanout. Source geometry changes
resize a window once; per-second stats and repeated configs do not resize it.

## Logs

Export via ShareLink or Finder File Sharing:

- Phone stage logs: `Documents/IOSDirectPOC/logs/<timestamp>-<run>.jsonl`.
- Phone transport logs: `Documents/IOSDirectPOC/logs/radio-*.jsonl`.
- Mac logs: `~/Documents/IOSDirectPOC-Receiver/logs/radio-*.jsonl`.

No screen pixels or compressed media are persisted. Metadata includes endpoint,
install/device/session UUID, label, TLS version/suite, path, rates, ACKs,
RTT/gaps/CRC/window/blocked time, video stage/queue/drop/reconnect counts, appState,
thermal and memory. Review before sharing. Secrets, QR payloads and proofs are
excluded. Logs persist across launches; there is no retention automation. Disk
errors stay visible. Capture metadata logging retains G1's lock-characterization
file-protection policy; capture while locked is not promised.

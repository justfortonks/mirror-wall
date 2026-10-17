# iOS Direct POC — Capture, Radio and Stream

Independent iOS 27 sender with three modes and a macOS 14+ receiver. Capture is
ScreenCaptureKit → paced SDR H.264 VideoToolbox → bounded local counting/hash
stub. Radio sends deterministic synthetic bytes over G2 TLS-PSK. Stream joins
capture/encode to that authenticated direct transport and a Mac video window.
No third-party dependencies, production integration, audio workaround or
broadcast extension. The G3a run and validation details are below.

G1b encoder recovery is preserved: failures invalidate only VT and retry on a
paced frame after 0.25/0.5/1/2 seconds (2-second cap), with a new generation and
forced IDR. Valid output resets backoff. JSON/UI report state, recreate attempts
and successes, failing OSStatus and no-session drops. Nil pools have no fabricated
OSStatus; unsupported hardware readback stays unknown.

G1/G2 hardware evidence is in [results](../../docs/ios-direct/results.md), runs
1–7. That evidence does not establish G3a background network sending. The three
G3a build/test commands were blocked before compilation/tests in this sandbox;
exact errors are recorded below. No new signed install or device pass is claimed.

## Open, build and install

1. Use Xcode 27.1 with the installed iPhoneOS 27.1 SDK. Open
   `IOSDirectPOC.xcodeproj` and select the shared `IOSDirectSender` scheme.
   The handwritten objectVersion 77 project uses a synchronized Sender group and
   links the local `Shared` package (`IOSDirectShared`). No project generator is used.
2. Under target Signing & Capabilities, select your existing Personal Team
   `499JQDRQF9` if Xcode needs account selection. Automatic signing and the isolated
   bundle ID `com.justfortonks.mirrorwall.iosdirectpoc.sender` are already set.
   Do not change production identifiers or add capabilities/entitlements to make
   provisioning succeed. If signing requests an entitlement, stop and report the
   exact error. Record the actual profile expiry and signed configuration.
3. Select a physical iPhone on iOS 27+, enable Developer Mode/trust development
   installation if prompted, and build/run. Record the phone alias A/B, model,
   exact OS build, revision/dirty diff, SDK, signing/profile and time. Repeat
   separately on B without signing B into an Apple Account.
4. Stop the debugger, disconnect wired and wireless debugging, then launch
   **iOS Direct POC** from Home for the actual experiment. A debugger run is only
   a smoke check, not background evidence. Do not modify device/account settings
   outside the recorded test procedure.

Run these from the repository root in a normal authorized shell:

```sh
cd prototypes/ios-direct/Shared && swift test 2>&1 | tail -20; cd -
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectSender \
  -destination 'generic/platform=iOS' -derivedDataPath prototypes/ios-direct/.build-xcode \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30
git status --porcelain
```

Inspect diagnostics and the `TEST`/`BUILD` result, since the pipeline status belongs
to `tail`. The six Shared XCTest methods cover even/aspect fitting in portrait,
landscape and odd sizes; 60→30 FPS pacing; byte/age rejection and drop counts;
retry deadlines/cap/reset; and metrics/event JSON lines. G1b tests/compilation
were blocked by sandbox_apply and SwiftPM diagnostic-cache permissions;
no workaround was attempted.

## Run and export

Use benign moving test content and obtain the human's screen-capture consent.
On **Capture experiment**, first tap **Share full display** and cancel; verify
`cancelled` and no payload progress. Retry and approve the system full-display
picker. Microphone and camera controls are disabled. The app calls `present()`,
checks the returned filter is `.display`, and attaches only `.screen` output.
`Stop` ends capture; system stop and errors are visible. Starting again requires
another explicit button tap/consent. Picker updates cannot auto-restart a stream.

Keep changing content in foreground for 60 seconds, then use other apps for ten
continuous unlocked background minutes, rotate twice and return. Confirm each
one-second JSON metrics sample advances capture PTS, encoder completions and
stub drains through the background interval. Check dimensions/generations,
queue bounds, drops, errors, thermal state and gaps. A timer advancing alone is
not evidence of the pipeline advancing. Test system stop while backgrounded,
user stop, cancellation, and the remaining G1 lifecycle steps on A and B.

**Export log** opens a ShareLink for the current metadata log. Logs also appear in
Files → On My iPhone → iOS Direct POC → IOSDirectPOC → logs, or through Finder
File Sharing. Each launch creates `Documents/IOSDirectPOC/logs/<run-start>.jsonl`.
No screen pixels or compressed payloads are written to disk. These metadata files
use no file protection so logging can continue across lock characterization;
store/export them locally and review them before publishing. Capture while locked
is not promised. Logs persist across relaunch; no retention/deletion automation.

**Reset counters** records an event and increments `resetEpoch`; it resets totals
and the rolling FNV-1a hash without restarting capture or changing its generation.
Reset while stopped before a measured run to avoid in-flight boundary ambiguity.
Snapshots retain current state/configuration; totals are cumulative per epoch,
so subtract successive samples for per-second stage progress. Absent hardware,
profile, PTS or memory data remains absent/unavailable, never an assumed success.

## Implementation and limits

- Main owns picker/UI/stream lifecycle. Capture callbacks use a dedicated queue,
  check complete/valid/ready samples, and apply explicit 30 FPS PTS pacing.
  Capture width/height use the existing even/aspect fitter and picker filter's
  contentRect × pointPixelScale. Matching buffers feed VT directly; size
  mismatches use VTPixelTransferSession to fit into 1280×720 or 720×1280,
  targeting video-range bi-planar YCbCr. No Core Image rendering or pixel rotation.
  The iPhoneOS 27.1 `SCStream.h` explicitly excludes `minimumFrameInterval`,
  `pixelFormat`, `scalesToFit`, `preservesAspectRatio`, `queueDepth` and
  `updateConfiguration` on iOS. Thus 30 FPS/pixel-format/aspect setters and live
  stream reconfiguration cannot be requested through this SDK. Default aspect
  preservation applies. Frame orientation, delivered buffer size/pixel format,
  screen/content rect and scales are recorded; buffer/orientation/screen-size
  changes rebuild the encoder without stopping capture. Rotation and whether SCK
  honors requested sizing need a device run.
- A locked mailbox permits two waiting source buffers. One serial encoder worker
  submits at most two VT frames in flight. Size/orientation changes invalidate
  the session and increment a generation; old completions are discarded. PTS is
  preserved. The encoder requests 6 Mbit/s, 30 FPS, one-second keyframes, no frame
  reordering, real time and High auto-level; low-latency rate control is supplied
  at creation. Every property result is logged. Rejected requested properties
  enter visible encoder unavailability and retry; hardware/profile readback
  failures remain unknown/unavailable; actual
  output avcC profile/level and format dimensions are recorded on keyframes.
- The stub has its own serial consumer. Admission is bounded by 1 MiB; admission,
  dequeue and metrics sampling expire entries aged 100 ms. Stale entries never
  drain. Overflow/expiry/oversize outputs count as sink drops and request the next
  IDR. Dispatch blocks do not retain payloads outside this queue. The consumer
  counts access-unit bytes and hashes them, then discards them. Stop clears source
  admission, invalidates VT generations, clears the sink and waits for its current
  drain before returning. Encoder recovery never restarts capture. No background
  task/audio workaround.
- A dedicated DispatchSource timer attempts one metrics line per second while
  capture grants execution. Events and metrics are serialized and synchronized
  to disk after every line. UIKit lifecycle/battery data is cached from main;
  process thermal/power/resident memory is sampled with each tick. Disk failures
  are shown separately and leave capture running. Only user Stop or app teardown
  calls stopCapture; picker/start failures and delegate stops clean up downstream
  state. The OS can still suspend/stop execution; a missing
  interval is evidence to investigate, not filled in afterward.
- G1b background capture/encode and G2 single-phone direct transport have hardware
  evidence in results runs 2–7. Visible rotation/image correctness, background
  network send and recovery are new G3a observations; earlier passes do not prove
  them. G2 two-phone qualification remains separate.

SDK reference: `xcrun --sdk iphoneos --show-sdk-path` resolved to Xcode's
`iPhoneOS27.1.sdk`. Implementation spelling/availability was checked against
`ScreenCaptureKit.framework/Headers/{SCContentSharingPicker,SCStream}.h`, its
`Modules/ScreenCaptureKit.swiftmodule/arm64e-apple-ios.swiftinterface`, and public
VideoToolbox/CoreMedia headers/interfaces. Compiler confirmation of imported
Objective-C signatures is pending the sandbox-free build; the Swift overlay
explicitly exposes `defaultConfiguration`, `showsMicrophoneControl` and
`showsCameraControl` on iOS 27.


## G2 Radio: Mac receiver and one or two phones

Open the same project and choose shared scheme **IOSDirectReceiver**. It is a
native macOS SwiftUI app, macOS 14.0 minimum, bundle ID
`com.justfortonks.mirrorwall.iosdirectpoc.receiver`, automatic signing with Personal
Team `499JQDRQF9`. **App Sandbox is OFF for this prototype**; no sandbox/network
entitlements are added. Sender and receiver declare local-network usage and
Bonjour `_mwiospoc._tcp`. Provision/install from Xcode with your existing team;
this assignment has not signed, installed or launched either app.

Launch Receiver, grant local-network access and wait for listener `ready`. The
large code is a per-run 80-bit test credential. **New code** disconnects all phones
and restarts with a fresh random credential. Stop any Capture run before measuring
G2. On the phone choose **Radio**, grant local-network access, pick the discovered
Mac, enter its code and select 2/6/12/24 Mbit/s (default 12). Tap Start; payload
starts only after TLS authentication and welcome. Stop sends bye and disconnects.
The receiver shows independent session IDs/rows even for two equal phone names.
A third authenticated client receives `reject capacity`; an incorrect code must
show `wrong code / handshake failed` without any data delivery. Validate both in
a normal shell and on devices before claiming that behavior passed.

[Protocol v1](../../docs/ios-direct/protocol.md) specifies TLS 1.2 PSK/HKDF,
framing, binary controls/data, limits, pending overload refusal and diagnostics.
These shared G2 test codes are **not final pairing**: QR, per-device keys,
approval/revocation and production security belong to G3. There is no plaintext
fallback. Opting in to peer-to-peer interfaces is not evidence of direct routing.
Run the full G2 controlled no-AP, one-phone and simultaneous two-phone procedures
in the [test plan](../../docs/ios-direct/test-plan.md); loopback does not close G2.

Sender **Export radio log** / Finder File Sharing exports
`Documents/IOSDirectPOC/logs/radio-*.jsonl`. Receiver **Export receiver log** exports
`~/Documents/IOSDirectPOC-Receiver/logs/radio-*.jsonl`. Directories are created;
a sandboxed build would use its container Documents directory. Logs contain
metadata only, including install/session UUIDs and endpoints; codes, PSKs and
synthetic payload bytes are never logged. Per-second snapshots and state/path
errors persist independently of a debugger; log failures remain visible.

Shared tests cover partial/coalesced/byte-fragmented parsing, invalid magic/version/
type/length, EOF, binary messages, CRC, code parsing and PSK derivation, pacing,
and the ten-second RTT window. macOS loopback integration tests use the **real
TLS-PSK options and production receiver registry** for hello/welcome/data/ack,
wrong-code failure/no data, third-client capacity rejection, duplicate labels,
one session continuing after another closes, pending-slot refusal, and the
five-second hello timeout with slot reuse. They require socket permission;
no plaintext substitute or conditional skip is provided.

Requested commands (repository root, no signing):

```sh
cd prototypes/ios-direct/Shared && swift test 2>&1 | tail -15; cd -
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectSender -destination 'generic/platform=iOS' -derivedDataPath prototypes/ios-direct/.build-xcode CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectReceiver -destination 'platform=macOS,arch=arm64' -derivedDataPath prototypes/ios-direct/.build-xcode CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
git status --porcelain
```

**2026-10-16 validation: all three commands attempted; compilation and tests did
not run.** SwiftPM failed manifest evaluation with the exact error
`sandbox-exec: sandbox_apply: Operation not permitted`. Both Xcode builds reported
`xcodebuild: error: Could not resolve package dependencies:` followed by
`<unknown>:0: error: cannot open file '/Users/thomas/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia' for diagnostics emission (Operation not permitted)`.
CoreSimulator service errors also appeared. Pipeline exit 0 belongs to tail/grep,
not a successful build. No cache override, sandbox bypass, installs, commits or
pushes were attempted. Plists/project plist and shared scheme XML validate;
G1 capture/encoder/stub/telemetry sources and original tests are unchanged.
Sandbox-free builds, Shared tests, signed launch/local-network permission, actual
wrong-code handshake behavior and controlled one/two-phone radio measurements
remain unresolved acceptance work.


## G3a Stream: one real phone screen to a Mac window

New **Stream** tab joins G1 screen capture/VideoToolbox to G2 TLS-PSK. Capture and
Radio remain independent regression modes. Security stays entirely behind
`RadioTLS.parameters(code:)`; pairing is G3b. No extra background mode is added.

1. Launch Receiver and wait for listener ready. On the phone select Stream, pick
   the discovered Mac and enter its displayed code. Tap **Connect** and wait for
   **authenticated; ready to share**. Only then is **Share full display** enabled.
   Approve the full-display system picker. A separate resizable, aspect-correct
   black-letterboxed window opens for that session, titled with phone label and
   short session ID. Stop any separate Capture/Radio experiment before this run.
2. Verify a moving, asymmetric test image in portrait, then rotate both ways.
   Compare the visible result with the phone. The raw delivered pixel size,
   CGImagePropertyOrientation, content/screen rect and encoder generation are
   logged; orientation is carried to config and applied by the Mac layer.
   This answers the G1 rotation question only after the image is observed.
3. For a foreground baseline, tap **Latency clock screen** for large, high-contrast
   monotonic milliseconds updated by CADisplayLink. Photograph phone and Mac in
   the same high-frame-rate camera view for later optical glass-to-glass timing.
   Transport/ACK RTT and phone-minus-Mac timestamps are not optical latency.
4. With no debugger/USB and the decisive no-AP setup from results run 7, go Home
   and use continuously changing, privacy-safe content in other apps for at least
   ten minutes. Record the background interval and any system capture indicators.
   Export **stream stage log**, **TLS/path log** and **receiver log** afterward.
   Check every second: `appState=background` with capture → paced → encode → sent
   → ACKed progress and matching Mac received → decoded → displayed progress.
   Static content can stop SCK updates; use a changing-content control. Timer
   progress alone, sent completion alone or a successful build is not a pass.
5. While capture remains authorized, interrupt/restore the link and record
   `video.reconnectScheduled` / `video.welcome` with appState. Expected: 0.5→4 s
   retry backoff, a new session/window, fresh config + IDR, and continued capture.
   Test this while backgrounded. Then stop capture from the system indicator;
   reconnect must **not** restart it or present consent. Test user Stop capture
   and Disconnect separately. Disconnected windows turn black and show state.
6. Repeat wrong-code/no-video and the existing G2 synthetic transfer. No commits,
   installs, provisioning or hardware acceptance were performed by this change.

Stream's queue is bounded to 1 MiB/100 ms with IDR recovery after any prediction
gap. The 6 Mbit/s G2 Latency window stays **75,000 wire bytes**, including fragment
metadata. An access unit bigger than that window is explicitly dropped with
`latencyWindowOversize` and another IDR is requested; persistent oversized IDRs
are an unresolved hardware risk, not a reason to silently increase the window.
See [protocol v2](../../docs/ios-direct/protocol.md) for byte layout, per-frame
ACK/decode status, one-frame reassembly, overflow behavior, decoder ownership and
precise counter meanings. Mac “displayed” counts successful decoded-image enqueue
to the layer; it does not prove physical scanout. Stats overlay is toggleable.

Shared `VideoTests` cover v1/v2 messages, fragmentation up to 1 MiB, oversize
rejection before allocation, missing/out-of-order/expired fragments, one partial
frame and queue recovery that sends an IDR first after overflow. TLS loopback
coverage sends config and fragmented bytes through the real receiver/admission
path, checks identical reassembly and chosen consumer status ACK, and checks
fragment-gap ACK + keyframe request. It deliberately does not claim H.264 decode.
The requested commands above must pass outside any environment blocker before
signed device/image/background/reconnect/optical acceptance.


G3a validation in this sandbox (2026-10-16): all three requested commands were
attempted once. **0 tests executed; neither app reached source compilation.**
SwiftPM failed before the test target with:

```text
error: 'shared': Invalid manifest
sandbox-exec: sandbox_apply: Operation not permitted
```

Both unsigned Xcode builds (receiver destination `platform=macOS,arch=arm64`)
failed resolving the local package with:

```text
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: cannot open file '/Users/thomas/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia' for diagnostics emission (Operation not permitted)
```

CoreSimulator service diagnostics also appeared. The pipeline statuses belong to
`tail`/`grep`, not successful tests/builds. No sandbox/cache/compiler workaround or
retry was used. Compile/API verification, TLS video loopback execution, real H.264
image correctness, rotation, background send and background reconnect remain
unverified. Run the same commands in an authorized normal shell, then the human
steps above. This change leaves the project, `ARCHS=arm64`, TLS security code,
`as __DispatchData`, single-argument message callback and `.waiting(.tls)` handling
in place. No commits, pushes or installs.

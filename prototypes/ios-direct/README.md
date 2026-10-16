# iOS Direct POC — G1 Capture and G2 Radio

Independent iOS 27 sender with Capture and Radio tabs, plus a macOS 14+ receiver.
Capture remains ScreenCaptureKit → paced SDR H.264 VideoToolbox → bounded local
counting/hash stub. Radio sends deterministic synthetic bytes through a separate
TLS-PSK transport; it never consumes capture output. No third-party dependencies,
production integration, audio workaround or broadcast extension.

G1b separates encoder state from capture: encoder failures invalidate only VT,
then retry on a paced frame after 0.25/0.5/1/2 seconds (2-second cap), with a new
generation and forced IDR. Valid output resets backoff. JSON/UI report encoder
state, recreate attempts/successes (create + properties + prepare), last failing
OSStatus and no-session frame drops; attempts include initial creation. Nil pools
have no OSStatus and are logged as such. Hardware readback -12900 is
`"unknown (not supported)"`. No new device/background pass is claimed.

**G1b build validation is blocked by this shell's sandbox; no new successful compile,
signed install or device/background pass is claimed.** See the G1-build entry in
[results](../../docs/ios-direct/results.md). The full
[G1 procedure](../../docs/ios-direct/test-plan.md) remains the acceptance procedure.

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
- G1 run 1 recorded two nil-pool failures after backgrounding followed by our
  stopCapture path. G1b recovery, image correctness, background cadence, rotation,
  stop latency and G1 gate success still need device validation. G2 Radio is
  implemented separately below; no G2 runtime pass is claimed.

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
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectReceiver -destination 'platform=macOS' -derivedDataPath prototypes/ios-direct/.build-xcode CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
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

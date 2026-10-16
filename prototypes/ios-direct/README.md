# iOS Direct POC — G1 capture experiment

Independent iPhone-only iOS 27 app. Full-display ScreenCaptureKit → paced SDR H.264
VideoToolbox → bounded counting/hash stub. No networking, audio output, broadcast
extension, entitlements file, third-party dependencies or production integration.

**Build validation is blocked by this shell's sandbox; no successful compile, signed
install or device/background pass is claimed.** See the G1-build entry in
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
to `tail`. The five Shared XCTest methods cover even/aspect fitting in portrait,
landscape and odd sizes; 60→30 FPS pacing; byte/age rejection and drop counts;
and metrics/event JSON lines. No tests executed in the sandbox attempt.

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
  iOS has no `minimumFrameInterval`, `pixelFormat` or `queueDepth` setters.
  Capture stays at native dimensions; Core Image applies the per-frame EXIF
  orientation and source color interpretation, converts to SDR Rec.709, and fits
  even dimensions inside 1280×720 or 720×1280. Rounding error is below two pixels.
- A locked mailbox permits two waiting source buffers. One serial encoder worker
  submits at most two VT frames in flight. Size/orientation changes invalidate
  the session and increment a generation; old completions are discarded. PTS is
  preserved. The encoder requests 6 Mbit/s, 30 FPS, one-second keyframes, no frame
  reordering, real time and High auto-level; low-latency rate control is supplied
  at creation. Every property result is logged. A rejected requested property
  fails visibly. Hardware/profile readback failures remain unavailable; actual
  output avcC profile/level and format dimensions are recorded on keyframes.
- The stub has its own serial consumer. Admission is bounded by 1 MiB; admission,
  dequeue and metrics sampling expire entries aged 100 ms. Stale entries never
  drain. Overflow/expiry/oversize outputs count as sink drops and request the next
  IDR. Dispatch blocks do not retain payloads outside this queue. The consumer
  counts access-unit bytes and hashes them, then discards them. Stop clears source
  admission, invalidates VT generations, clears the sink and waits for its current
  drain before returning. No automatic restart or background task/audio workaround.
- A dedicated DispatchSource timer attempts one metrics line per second while
  capture grants execution. Events and metrics are serialized and synchronized
  to disk after every line. UIKit lifecycle/battery data is cached from main;
  process thermal/power/resident memory is sampled with each tick. Disk failures
  stop the experiment visibly. The OS can still suspend/stop execution; a missing
  interval is evidence to investigate, not filled in afterward.
- No signed entitlements/profile, actual supported encoder properties, image
  correctness, background cadence, rotation, stop latency, hardware or G1 gate
  success has been measured. No G2 radio code exists.

SDK reference: `xcrun --sdk iphoneos --show-sdk-path` resolved to Xcode's
`iPhoneOS27.1.sdk`. Implementation spelling/availability was checked against
`ScreenCaptureKit.framework/Headers/{SCContentSharingPicker,SCStream}.h`, its
`Modules/ScreenCaptureKit.swiftmodule/arm64e-apple-ios.swiftinterface`, and public
VideoToolbox/CoreMedia headers/interfaces. Compiler confirmation of imported
Objective-C signatures is pending the sandbox-free build; the Swift overlay
explicitly exposes `defaultConfiguration`, `showsMicrophoneControl` and
`showsCameraControl` on iOS 27.

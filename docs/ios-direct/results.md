# Results ledger

**Verified (local command evidence), 2026-10-16:** G0 run 0 only. No capture, radio, pairing, performance or integrated acceptance runs exist. Future runs append rows with links to sanitized evidence; private device IDs, keys, tokens and screen content stay outside Git.

| Run / date | Revision / branch / config | Devices / OS / SDK / signing | Topology / radio / accounts | Media / steps / duration | Expected | Actual / metrics / status | Evidence / limitations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 / 2026-10-16 | `70e2f1a1d48ca65ea26fc2a0592760eb543795b3`; `feat/ios-direct-poc`; root SwiftPM default debug; initial clean tree | User-supplied MacBook Air M5; local macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Swift 6.4; Mac SDK 27.0, iPhoneOS SDK 27.1; no signing reached | Local shell only; radios/accounts not exercised | No media; requested status/build/test pipeline once; tool elapsed 3.69 s (per-command timing not captured) | Build completes, tests execute, baseline recorded | **Blocked** at manifest sandbox evaluation for build and test; 0 tests executed, pass/fail counts unavailable; no product build or tests passed | Verbatim fatal diagnostics below; pipeline exit 0 belongs to tail. No alternate cache/sandbox flags, fixes or retries. |

## Run 0 command and output

Working directory: `/Users/me/Documents/Claude Code/Mirror-wall POC`.

```sh
git status --porcelain && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30
```

Initial status output was empty. Both commands emitted the same three cache warnings:

```text
warning: /Users/me/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: /Users/me/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: /Users/me/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
```

Build diagnostic (verbatim):

```text
error: 'mirror-wall poc': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.CPODkx/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "5", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "5.9.0", "/Users/me/Documents/Claude Code/Mirror-wall POC/Package.swift", "-o", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.G0xQPP/mirror-wall poc-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

Test diagnostic (verbatim):

```text
error: 'mirror-wall poc': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.YO2hFM/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "5", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "5.9.0", "/Users/me/Documents/Claude Code/Mirror-wall POC/Package.swift", "-o", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.3I1qOr/mirror-wall poc-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

The requested pipeline returned **0** because it did not enable pipefail and both `tail` processes succeeded. Individual Swift command exit codes were not preserved by that command; their diagnostics establish failure before target build/test execution. Static source has 80 test method declarations, which is not an executed test result. This environment failure was not repaired or classified as a product defect.

Final scope check: `git status --porcelain --untracked-files=all` lists exactly the six new Markdown files under `docs/ios-direct/`; no tracked changes elsewhere. No prototype directory was created. SDK/device command outputs are recorded in feasibility.md; they are not fabricated hardware-result rows.

## Run 0b — baseline rerun outside the Codex sandbox (Claude, 2026-10-16)

Same revision `70e2f1a`, same worktree, run by Claude in a normal shell.

| Command | Result |
| --- | --- |
| `swift build` | **Pass** — `Build complete!` |
| `swift test` | **Pass** — XCTest: 80 tests executed, 0 failures. (Swift Testing: 0 tests, as expected.) |

Run 0's failure was the Codex sandbox, not the project. This is the accepted G0 baseline.

## G1-build — 2026-10-16

**Authored; build/test validation blocked.** Isolated G1 sender/project, local Shared
package (five XCTest methods), and instructions in `prototypes/ios-direct/README.md`.
Installed tools: Xcode 27.1 (27A9275), iPhoneOS SDK 27.1, Swift 6.4; Swift language
mode 5. iOS 27 target, automatic signing/team configured as requested, but the generic
device build used `CODE_SIGNING_ALLOWED=NO`. No signing/install/device experiment.

The exact requested commands were run from the worktree root:

```sh
cd prototypes/ios-direct/Shared && swift test 2>&1 | tail -20; cd -
xcodebuild -project prototypes/ios-direct/IOSDirectPOC.xcodeproj -scheme IOSDirectSender \
  -destination 'generic/platform=iOS' -derivedDataPath prototypes/ios-direct/.build-xcode \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30
git status --porcelain
```

SwiftPM emitted user-cache accessibility warnings, then `error: 'shared': Invalid
manifest` and this fatal diagnostic verbatim:

```text
sandbox-exec: sandbox_apply: Operation not permitted
```

Xcode failed during Resolve Package Graph, before source compilation. Fatal output
verbatim (including the actual denied cache/diagnostic paths):

```text
xcodebuild: error: Could not resolve package dependencies:
  <unknown>:0: error: error opening '/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/C/clang/ModuleCache/PackageDescription-3G5ELZSCPJCMB.swiftmodule' for output: /var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/C/clang/ModuleCache/PackageDescription-3G5ELZSCPJCMB.swiftmodule: Operation not permitted
/Users/me/Documents/Claude Code/Mirror-wall POC/prototypes/ios-direct/Shared/Package.swift:2:8: error: failed to build module 'PackageDescription' for importation due to the errors above; the textual interface may be broken by project issues or a compiler bug
 1 | // swift-tools-version: 5.9
 2 | import PackageDescription
   |        `- error: failed to build module 'PackageDescription' for importation due to the errors above; the textual interface may be broken by project issues or a compiler bug
 3 |
 4 | let package = Package(
<unknown>:0: error: cannot open file '/Users/me/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia' for diagnostics emission (Operation not permitted)
```

Xcode also reported CoreSimulatorService connection failures; the selected destination
was generic iOS. Both pipelines returned 0 from `tail`, which is **not** build/test
success. Tests executed: **0**; source compile, imported-signature verification,
signing/profile, hardware encoder, rotation/stop/background behavior: **not verified**.
No cache override, sandbox disable, alternate compiler path or other workaround/retry.

Static verification: `plutil -lint` accepts Info.plist and project.pbxproj; scheme XML
parses; Info.plist has only standard CFBundle keys plus the three requested keys,
with `UIBackgroundModes = [screen-capture]`; scope and `git diff --check` pass. Final
Git status is limited to the prototype, `.gitignore`, and G1-build appendices in
handoff/results. This is source/configuration evidence, not a Built or G1 pass.

## Run 1b — G1 build/sign/install (Claude, 2026-10-16)

| Step | Result |
| --- | --- |
| `Shared` `swift test` | **Pass** — 5 tests, 0 failures |
| Generic iOS build (unsigned) | Initially **failed**: 5 Swift API spelling errors in `EncoderPipeline.swift` (VTSessionCopyProperty `valueOut:`, `VTCompressionSessionEncodeFrame(…outputHandler:)`, optional CFDictionary). Fixed by Claude in review; also wrapped the property readback pointers in `withUnsafeMutablePointer`. Now **Built**, no warnings in sender code beyond one weak-capture note. |
| Signed device build, Personal Team 499JQDRQF9 | **Built** with `-allowProvisioningUpdates`; identity "Apple Development" |
| Signed entitlements | Only `application-identifier`, `team-identifier`, `get-task-allow`. No capture or Wi-Fi entitlements. `UIBackgroundModes=[screen-capture]` is an Info.plist key only. |
| Install on phone A (iPhone 17 Pro Max, iPhone18,2) | **Installed** via `devicectl` |
| Phone B (iPhone 17e) | Not yet visible to `devicectl`; not installed |

Hardware: phone A = iPhone 17 Pro Max (user's Apple Account); phone B = iPhone 17e (no Apple Account).
Developer Mode enabled on both (user report). G1 device run: **not run**.

## Run 2 — G1b device run, phone A (iPhone 17 Pro Max, iOS 27.0.1), 2026-10-16 22:55–23:01Z

Build `25d4ce2`, Personal Team, no cable during run (user report). Log: `2026-10-16T22-55-55Z-66295C3C.jsonl` (kept locally, not in Git).

| Observation | Result |
| --- | --- |
| Full-display picker, consent | Pass — filter style `.display`, delivered 588×1280 (pixel format `420f`) |
| Background entry | Encoder session invalidated ~100 ms after `didEnterBackground` (nil pixel-buffer pool); one recreate after 0.25 s backoff **succeeded in background** |
| Background duration | ~4 min 13 s continuous (8155→8407 s monotonic) |
| Progress in background | capture callbacks 1916→12073; encode completed 981→6363 (~21/s avg); sink drained = encoded; encode errors stayed at 1 (the invalidation) |
| Gaps | Short frame gaps up to ~11 s (e.g. 8393→8404) with no errors; likely static screen content (SCK only delivers changed frames). Needs changing-content control in the 10-min run. |
| Thermal / memory | nominal throughout; resident memory 80 MB → 49 MB in background |
| Indicator UI | Dynamic Island capture indicator stayed on while backgrounded. Control Center's indicator was not red. Indicator disappears while the capturing app itself is foreground. Capture state remained "capturing"; encoder "ok" (user report + log). |

Status: **Hardware pass (partial)** for background screen-only capture + H.264 encode on phone A. Still to do for G1 close: 10-min run with continuously changing content, rotation, system stop, lifecycle cycles; phone B (17e, blocked by MDM pairing restriction).

## Run 3 — G1 10-minute background run, phone A (iPhone 17 Pro Max), 2026-10-17 00:32–00:43Z

Build `25d4ce2`. No cable. Changing content (user), two rotations + Control Center (user report), stopped from Dynamic Island.

| Metric (background interval only) | Result |
| --- | --- |
| Continuous background time | **609 s (10 min 9 s)**, appState `background` throughout |
| Capture → paced → encoded → sink | 22,112 valid frames → 18,053 paced → 17,958 encoded → 17,955 drained |
| Encoded frame rate | **29.5 fps** mean; per-second median 30, p10 29; 1 second below 5 fps |
| Longest stretch with no encoded output | **1.0 s** |
| Encoder errors | 1 (expected invalidation at background entry; recreated after 0.25 s backoff, in background) |
| Drops | source 87, sink 3; sink queue stayed at 0 bytes / 0 ms |
| Encoded bitrate | 0.65 Mbit/s mean at 6 Mbit/s target (screen content compresses far below target) |
| Keyframes | 608 (~1/s as configured) |
| Thermal / memory / battery | nominal; 45–50 MB resident; battery 50% → 50% (unplugged) |
| Stop | `SCStreamErrorDomain -3817 "The user stopped the stream"` → `stopped by system`, encoder `unavailable: stopped` |
| Rotation | Delivered size stayed 588×1280 through both rotations; whether rotated content is correct is **unverified** (needs a visible image, G3) |

**G1 gate (Claude, phone A): Hardware pass.** Screen-only `screen-capture` background mode + full-display picker + VideoToolbox H.264 sustains ~30 fps for 10 minutes in the background on a free Personal Team build, provided the app recreates the compression session after the background-entry invalidation. Open: phone B (17e, MDM pairing block), rotation correctness, lock/Low Power/interruptions characterization, 20-cycle lifecycle.

## Run 4 — G2 single phone, LAN present (phone A + MacBook Air M5), 2026-10-17 00:44–00:55Z

Build `f31fe56`. Mac and phone both joined to the same home Wi-Fi (LAN-present comparison per §9.1 step 6; **not** a direct/offline run). Foreground Radio mode, 12 Mbit/s requested.

| Item | Result |
| --- | --- |
| Discovery | Browse result advertised on `[en0, awdl0]`; first result ~3 s after browser ready |
| Correct code | 5 connections, each TLS 1.2 (771) + `TLS_PSK_WITH_AES_128_GCM_SHA256` (168), connect ≤1 s after Start |
| Wrong code | Mac: `-9846 bad MAC` on **both** an `en0` and an `awdl0` attempt (connection racing) — no session admitted, no data. Phone: surfaced only as `TLS/welcome timeout` after 10 s (UX defect: should fail fast). User confirmed no connection. |
| Route for data | `en0` (infrastructure Wi-Fi) on every admitted session |
| Main session (5.5 min) | delivered median **11.27 Mbit/s** (p10 10.88, min 9.57) — **below the 12 Mbit/s per-phone target**; 0 seq gaps, 0 CRC failures; RTT median 13 ms, p95 ~70 ms (max 107 ms); phone send-blocked only 0.78 s total → shortfall is likely sender pacing, not the link |
| Thermal / memory | nominal; phone ~130 MB, Mac ~108 MB |

Findings: (1) AWDL path to the Mac is reachable while the Mac is on infrastructure Wi-Fi — evidence from the wrong-code race. (2) With a common LAN, the system routes over `en0`. (3) Pacer undershoots ~6%. (4) Phone needs fast handshake-failure reporting.

## Run 5 — G2 direct, Mac online / phone unassociated (phone A + MacBook Air M5), 2026-10-17 01:02–01:16Z

Build `f31fe56`. Mac joined to home Wi-Fi with internet. Phone A: Wi-Fi on, auto-join off, no network joined, cellular data off, hotspot off, Bluetooth on, no USB (user report; Safari could not load). Auto-Lock set to Never for 5b (restore afterwards). Foreground Radio mode, 12 Mbit/s requested.

| Item | 5a (01:02, ended by screen lock) | 5b (01:10, user stop) |
| --- | --- | --- |
| Discovery | browse result on `[awdl0]` only, 3 s after browser ready | `[awdl0]`, 1 s |
| Connect + TLS-PSK | <1 s, TLS 1.2 / 0x00A8 | <1 s, same |
| Route (both ends) | `awdl0` | `awdl0` |
| Duration | 290 s | 341 s |
| Delivered | median **7.47 Mbit/s** (p10 6.69) | median **7.47 Mbit/s** (p10 6.82) |
| RTT | median ~40 ms, p95 ~267 ms (max 465) | median ~40 ms, p95 ~263 ms (max 427) |
| Gaps / CRC | 0 / 0 | 0 / 0 |
| Phone send-blocked by 150 KB outstanding cap | 99 s (34%) | 116 s (34%) |
| End | screen lock → `ECONNRESET`; browser then `failed -65569 DefunctConnection` and never recovered; two reconnects timed out | `peer bye: user stop` |

Findings:
1. **Direct path works** with the phone on no network and the Mac online: discovery, TLS-PSK, sustained transfer over `awdl0` with zero loss. First positive Candidate A evidence.
2. Throughput was **limited by our app window** (150 KB outstanding cap vs AWDL RTT), not shown to be the link ceiling. Link capacity still unmeasured. Per-phone 12 Mbit/s target not met in this configuration.
3. AWDL RTT p95 ~265 ms with the Mac also on infrastructure Wi-Fi — risk for the p95 ≤350 ms glass-to-glass target. Compare against Mac-offline and Mac-on-Ethernet.
4. Screen lock kills the session (expected for foreground-only G2), but the browser goes defunct and the app doesn't recover — must restart the browser.

## Run 6 — G2 capacity probe, direct, Mac online / phone unassociated, 2026-10-17 01:28–01:36Z

Build `e95e1b9`. Same topology as run 5 (phone A on no network, cellular data off, Auto-Lock Never; Mac on home Wi-Fi). Window = Capacity probe (2 MiB).

| Run | Duration | Delivered median (p10–p90) | RTT median / p95 median / p95 max | Gaps / CRC | Route |
| --- | --- | --- | --- | --- | --- |
| 6a, 48 Mbit/s | 225 s | **48.6 Mbit/s** (40.5–50.4) | 100 ms / 321 ms / 945 ms | 0 / 0 | `awdl0` both ends |
| 6b, 24 Mbit/s | 195 s | **23.6 Mbit/s** (20.1–25.0) | 74 ms / 304 ms / 1208 ms | 0 / 0 | `awdl0` both ends |

Thermal nominal throughout. Each session ended with `ECONNRESET` on user Stop at high rate (bye queued behind the window) — cosmetic, to fix.

Findings:
1. **Single-phone direct capacity ≥ 48 Mbit/s** with the Mac also on infrastructure Wi-Fi — 2× the 24 Mbit/s two-phone aggregate headroom target and ~70× the measured G1 screen bitrate. Two-phone concurrency still untested (phone B blocked).
2. RTT p95 ~265–320 ms at every rate (7.5, 24, 48 Mbit/s) → not queue-driven; likely AWDL channel time-sharing with the Mac's infrastructure association. Next: same test with the Mac unassociated (and/or internet via Ethernet) to isolate.

## Run 7 — G2 decisive no-AP topology, single phone, 2026-10-17 01:40–01:47Z

Build `e95e1b9`. Mac: Wi-Fi on, unassociated (auto-join off, disconnected), no Ethernet, no internet (Safari failed). Phone A: Wi-Fi on, unassociated, cellular data off, hotspot off, Bluetooth on, Auto-Lock Never. No USB on either. (User report; settings restored afterwards — Mac auto-join back on and reconnected.)

| Run | Duration | Delivered median (p10) | RTT median / p95 median / p95 max | Gaps / CRC | Route | End |
| --- | --- | --- | --- | --- | --- | --- |
| 7a, Latency window, 12 Mbit/s | 202 s | **11.95–11.99 Mbit/s** (10.8–11.8) | 9.3–9.8 ms / 11.7–15.3 ms / 245 ms | 0 / 0 | `awdl0` | clean `bye` |
| 7b, Capacity probe, 48 Mbit/s | 195 s | **48.0 Mbit/s** (47.7–47.8) | 9.9–10.6 ms / 19–21 ms / 221 ms | 0 / 0 | `awdl0` | clean `bye` |

Comparison with run 5/6 (Mac associated to home Wi-Fi): RTT p95 dropped from ~265–320 ms to ~12–21 ms; latency-window throughput rose from 7.5 to 12.0 Mbit/s.

Findings:
1. **G2 single-phone criteria met in the decisive no-AP / no-internet / no-USB topology** (authenticated TLS-PSK, ≥12 Mbit/s for >3 min, 0 loss, bounded window). Two-phone concurrency and the 9/10 connection-attempt series still to run.
2. Mac infrastructure association is the dominant source of AWDL latency (single-radio time sharing). Product guidance candidate: Mac offline or on Ethernet for best latency; Mac-on-Ethernet + Wi-Fi unassociated still to measure.
3. G2b fixes confirmed on hardware: pacer within 0.5% of target; clean stop.

## Run 8 — G3a first live stream, phone A → Mac window, direct, 2026-10-17 02:07–02:13Z

Build `7750fce`. Topology as run 5 (phone unassociated, Mac on home Wi-Fi). Stream mode, G2 TLS-PSK code, full-display consent after `welcome`. ~5 min incl. background use, rotations, latency clock.

| Item | Result |
| --- | --- |
| Route | `awdl0`, TLS-PSK |
| Background | Transport `ready` and frames flowing while `appState=background` (57 background samples; frames acked) — **capture + encode + network send continue in background** |
| Phone | 9,229 encoded; 4 encoder recreates (background entries), all succeeded |
| Mac received | 9,001 frames (≈97.5% of encoded) |
| Mac dropped | 3,223 (36%) — all from `decode backlog` (≥2 frames pending) → 496 keyframe requests, decoder reset + `flushAndRemoveImage` each time |
| Displayed fps | median 17, p10 12 |
| Inter-arrival | p95 277 ms, longest gap 3.8 s (bursty AWDL with Mac on infrastructure Wi-Fi) |
| User observation | Very choppy, frequent blinking; latency clocks "pretty close"; rotated picture correct but Mac window did not rotate; latency clock had no exit |

Diagnosis (Claude): receiver backlog policy too strict and recovery blanks the layer; fix in G3a-fix (decode every frame, display newest, no blanking, optional 100 ms smoothing, rotating window, clock exit). Background-send question answered positively.

## Run 9 — G3a-fix stream, phone A → Mac window, direct, 2026-10-17 02:23–02:30Z

Build `a7ebbc0`. Same topology as run 8. ~4.5 min immediate presentation, ~0.5 min smoothing (100 ms).

| Item | Result |
| --- | --- |
| Totals (Mac) | received 4,344, decoded 4,344, displayed 4,333, display-skipped 11, **dropped 0, decode errors 0, keyframe requests 0, recoveries 0** |
| Immediate mode (active seconds) | displayed fps median **30**, mean 24.8, p10 10; inter-arrival p95 ~44 ms; decode queue depth max 4 |
| Smooth 100 ms (29 s) | displayed fps median 30, mean 29.6, p10 28; queue depth max 2 |
| User observation | Not choppy or blinking, much smoother. Smoothing marginally better but the extra delay is noticeable watching phone and Mac side by side; user prefers it off. Picture content correct when rotated, but window stays portrait. |
| Orientation signal | Every frame reported `orientation=1`, buffer always 588×1280 — iOS ScreenCaptureKit delivers panel-oriented pixels; landscape apps appear rotated inside the portrait frame. No rotation signal found in the fields read so far. |

Status: single-phone live stream over direct link **Hardware pass (functional)** with Mac on home Wi-Fi. Open: rotation signal/window rotation, optical latency measurement, Mac-offline stream, 30-min soak, pairing (G3b), two phones (blocked on 17e).

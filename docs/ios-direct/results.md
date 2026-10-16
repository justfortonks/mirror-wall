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

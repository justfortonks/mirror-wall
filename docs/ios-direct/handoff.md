# G0 handoff

Checkpoint: 2026-10-16. **Verified (local evidence):** six documentation files under `docs/ios-direct/`; branch `feat/ios-direct-poc`, worktree `/Users/me/Documents/Claude Code/Mirror-wall POC`, HEAD/base/local origin/main `70e2f1a1d48ca65ea26fc2a0592760eb543795b3`. Full external brief read. No product/prototype code, commits or pushes. [README](README.md) records isolation, terminology and future rollback.

## Evidence and gate position

- **Verified:** documentation checks passed: six expected files, local Markdown links, balanced code fences, whitespace, ten SDK quote blocks compared line-for-line with installed files, docs-only Git status and no `prototypes/ios-direct/` directory. These checks do not replace the blocked Swift baseline.
- **Verified:** requested root build/test pipeline executed once. Both SwiftPM commands stopped at manifest evaluation with `sandbox-exec: sandbox_apply: Operation not permitted`; tests executed 0, pass/fail counts unavailable. Pipeline exit 0 is tail's status, not success. No workaround or unrelated fix. [Run 0](results.md).
- **Verified:** Xcode 27.1 (27A9275), iPhoneOS SDK 27.1, MacOSX SDK 27.0, host macOS 27.0.1 (26A434). iOS 27 capture declarations exist; no compile/signing/runtime evidence for a sender.
- **Verified:** WiFiAware exists in both SDKs, but WACapabilities is explicitly unavailable on macOS. No actual empty-feature result. `devicectl` failed CoreDeviceService initialization; this does not prove there are no phones. [Exact probes](feasibility.md).
- **Verified:** no USB capture implementation in Sources. Android Annex B → H264Frame → per-slot H264Renderer is the smallest media adapter pattern; renderer accepts compressed input and owns VideoToolbox decode/timing, with decoded image outputs. Existing cast transport is plaintext TCP with self-reported-ID filtering. [Source map/seam](architecture.md).
- **Verified (task input):** MacBook Air M5; two iOS 27+ phones, exact models/builds TBD; A signed into user's Apple Account, B signed out; free Personal Team only, no Wi-Fi Aware entitlement or TestFlight. Brief §9 targets ratified unchanged.
- **Hypothesis:** use Bonjour + Network.framework includePeerToPeer with per-phone authenticated TLS sessions first. SDK availability alone says nothing about no-AP routing, background send, throughput, concurrency or runtime support.

G0 is prepared for Claude review, not marked Accepted. G1/G2 are plans only. G1 full-display background capture: **not proven**. Direct transport/two sessions: **not run**. Offline pairing/encryption: **not validated**. FPS/latency/bitrate/CPU/memory/thermal: **unmeasured**. Standalone and integrated apps: **not implemented**. Existing AirPlay/Android/window/record/OBS runtime regression: **not run**; USB regression **N/A (absent)**. Distribution remains development-only in scope; installation/signing still untested.

## Open questions / required human or Claude actions

1. **Human:** identify A/B exact model/iOS builds, Developer Mode, free signing device/app quota/profile expiry, physical access and ability to install/launch on B while signed out. Record radio/charging/thermal conditions for real runs; no account changes are required for G0.
2. **Claude:** review/record G0 gate decision and the bounded G1 assignment. The supplied §9 targets already stand. Hardware-specific CPU budget remains TBD until models/measurements allow a meaningful limit; decide before acceptance runs. Mac prototype macOS 14 for Candidate A is proposed; production OS floor stays unchanged.
3. **G1 implementer/human:** can screen-only `screen-capture` mode be provisioned on Personal Team and keep capture/VideoToolbox/stub drain alive while other apps run? Inspect built entitlements/profile and exact callbacks/errors; do not assume a restricted entitlement is needed or available.
4. **G2 implementer/Claude:** finalize supported per-run TLS identity generation/installation/pinning and mutual phone authorization before radio code; later full offline pairing/token/revocation design remains separate. Can Candidate A discover and sustain two connections under the controlled offline topology? Is Bluetooth required? No answer yet.
5. **Claude:** Mac Aware expectation conflicts with callable SDK surface: plan must record unavailable API rather than fabricate empty supportedFeatures. Reopen Candidate B only with public supported APIs and actual entitlement/hardware prerequisites.
6. **Human outside this sandbox:** a normal authorized build/test environment is needed for a runnable baseline. G0 deliberately did not change caches, disable sandboxing or retry with alternate tooling. No current remote CI/PR status was fetched.

## Next smallest task — Hypothesis / proposed assignment

After Claude's G0 review and explicit implementation scope, create only the independent G1 iOS app/shared metrics skeleton proposed in [test-plan](test-plan.md), with distinct identifiers, iOS 27 full-display picker, screen-only background declaration, H.264 counters and bounded stub sink. Compile/sign/install once with Personal Team, then have the human run the numbered G1 sequence on A and B. Deliver exact signed configuration, errors and background per-stage progress or a minimal blocker. Stop before networking, second capture architecture or Mirror Wall source integration. G2 can then be assigned independently with the documented Aware availability stop and synthetic TLS plan.

Integration remains gated by standalone G4 evidence and recorded G5 review; no current permission to modify production paths, release infrastructure, commit/push or merge is inferred. Preserve this dedicated worktree until evidence is reviewed. Rollback commands in README are future instructions, not executed operations.

## Claude G0 decision (2026-10-16)

**G0 accepted.** Baseline passes outside the Codex sandbox (results.md run 0b). Candidate B
(Wi-Fi Aware) closed for this Mac: `WACapabilities` is `@available(macOS, unavailable)` in the
macOS 27.0 SDK. Candidate A proceeds. G0 docs committed and pushed to `feat/ios-direct-poc`.
Next: G1 capture skeleton (Codex), then human device run on A and B. Pending from human:
exact iPhone models/iOS builds.

## G1-build — 2026-10-16

The authorized G1 prototype is now authored under `prototypes/ios-direct/`: handwritten
synchronized Xcode project/shared scheme, iPhone sender, local platform-neutral
Shared package with five XCTest methods, and run/export instructions. Only the three
requested `.gitignore` lines and G1-build appendices here/results accompany it. No
networking, entitlement, production change, signing attempt, commit or push.

**Blocked validation:** both requested commands were attempted without workaround.
`swift test` failed at manifest evaluation with `sandbox-exec: sandbox_apply: Operation
not permitted`; `xcodebuild` failed local-package resolution with module-cache and
manifest-diagnostic writes denied. No sources compiled and no tests executed; exact
errors are in results. Static plist/project parsing and scope/whitespace checks pass.
Claude must rerun both original commands outside the sandbox and resolve any compiler
errors before calling this Built, then provision/install and perform G1 on A/B.
No entitlement requirement has been demonstrated; stop/report if provisioning requires
one. Full-display background capture/encode/stub operation remains unproven.


## G2 implementation handoff — 2026-10-16

Brief G2 implemented under `prototypes/ios-direct/`: independent macOS 14
`IOSDirectReceiver` target/scheme (Personal Team 499JQDRQF9, automatic signing,
App Sandbox OFF), sender Radio tab, shared TLS 1.2 PSK/framing/admission/pacing/
metrics, unit tests and real TLS-PSK macOS loopback tests. Both apps declare
local-network/Bonjour usage. Capture pipeline, encoder, stub, telemetry and
original tests are unchanged; sender root only adds the tab. No production files,
commits, pushes, installs or entitlement workarounds.

[Protocol v1](protocol.md) records the G2-only 80-bit credential/HKDF model,
binary format, strict parser, two-active/two-pending limits, five-second hello
deadline, explicit authenticated capacity reject, and pre-TLS refusal when the
pending limit is full. QR/per-device identity/revocation remain G3. Synthetic bytes
are independent of capture. Full no-AP/two-phone throughput acceptance remains
[the G2 test plan](test-plan.md), not a loopback result.

All requested test/build commands were attempted. SwiftPM stopped before tests
at `sandbox-exec: sandbox_apply: Operation not permitted`; both Xcode schemes
stopped resolving Shared with `<unknown>:0: error: cannot open file
'/Users/me/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia'
for diagnostics emission (Operation not permitted)`. No bypass attempted. Plist
and scheme XML checks passed, but **no successful compilation/test, signed launch,
TLS runtime result, direct route or gate pass is claimed**. Claude must run the
README commands outside the sandbox, then device/local-network and controlled
G2 acceptance. Review pending-overload behavior and the 65,536-byte body limit
(65,516 synthetic bytes after metadata) in protocol.md before accepting G2.


## G3a implementation handoff — 2026-10-16

Stream mode now joins G1 capture/encode to a bounded G2 TLS-PSK video sink, with
v2 config/AVCC fragments/per-frame decode ACK/keyframe recovery, 0.5→4 s reconnect
without restarting capture, combined appState/stage JSONL and a CADisplayLink
latency clock. Mac sessions own separate decoder queues, immediate-display layers,
windows/stats and stale-callback epochs; synthetic v1 rows remain. Protocol bounds,
rotation metadata and run steps are in [protocol](protocol.md) and the prototype
README. At the unchanged 6 Mbit/s Latency rule, a full frame over 75,000 wire bytes
is explicitly dropped/IDR requested; repeated oversized IDRs need hardware review.
TLS security/project/background modes are unchanged. No production edits, commits,
pushes or installs.

All requested tests/builds attempted once: **0 tests executed; no source compiled**.
SwiftPM: `sandbox-exec: sandbox_apply: Operation not permitted`. Both Xcode schemes:
`xcodebuild: error: Could not resolve package dependencies:` followed by
`<unknown>:0: error: cannot open file '/Users/me/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/shared.dia' for diagnostics emission (Operation not permitted)`.
No workaround/retry. Re-run original commands outside the blocker, including new
fragment/queue and real TLS transport/reassembly tests (injected consumer, not H.264
decode acceptance), then perform the README single-phone image/rotation/background
send/reconnect/system-stop run. G3a background network-send gate remains **unproven**.

## G3b implementation handoff — 2026-10-16

Protocol v3 now uses offline 120-second QR invitations, Mac approval, per-device
Keychain credentials, nonce/HMAC identity binding and isolated revocation. Both
Radio and Stream use stored identities; the typed credential is removed. Receiver
identity/TXT hints, Devices/Forget UI, VisionKit scanner, memory-backed test storage
and secret-free log assertions are included. See the current prototype README and
[protocol security model](protocol.md). G1/G3a capture, oversized-IDR admission and
receiver decode/presentation fixes are preserved; project/ARCHS and results.md are
unchanged. No commits, pushes or installs.

Shared: **50 XCTest tests pass**, including real TLS **1.2 / 0xCCAC** negotiation,
multiple PSKs selected by identity, pairing/reuse/expiry/denial, three failed
attempts, forged deviceID, live two-video-session revocation isolation, impostor,
legacy/media rejection, pending/deadline limits and captured-log checks. The SDK
cannot identify a failed handshake's PSK identity: unrelated pre-authentication
failures during an invitation conservatively count toward its three-attempt burn.
Both requested unsigned Xcode builds (manifest-sandbox flag, no packageCachePath)
stop at package resolution: `shared.dia` in the user SwiftPM manifest cache is
not writable in this sandbox. Separate arm64 iOS/macOS source typechecks pass;
these do not establish linked builds. Claude still needs Xcode builds and signed
Keychain/camera/relaunch/Bonjour/offline/two-phone acceptance. Loopback injects the
video consumer and does not prove H.264 decoding or device behavior.

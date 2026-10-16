# G0 handoff

Checkpoint: 2026-10-16. **Verified (local evidence):** six documentation files under `docs/ios-direct/`; branch `feat/ios-direct-poc`, worktree `/Users/thomas/Documents/Claude Code/Mirror-wall POC`, HEAD/base/local origin/main `70e2f1a1d48ca65ea26fc2a0592760eb543795b3`. Full external brief read. No product/prototype code, commits or pushes. [README](README.md) records isolation, terminology and future rollback.

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

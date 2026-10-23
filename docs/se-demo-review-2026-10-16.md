# Mirror Wall: SE demo review

October 16, 2026 · Mac, Android companion, and fork handoff

## Assessment

Mirror Wall has a useful shape for an internal SE tool: a clean audience-facing Stage, a separate operator Wall, local device streaming, and a small Android companion. The Imprivata background and caption branding support the demo without overpowering the phones. Keep that direction.

I would continue controlled team testing, but fix the control semantics and connection lifecycle before relying on this build for an unattended event station or an important live demo. The largest risks are surprises during a presentation: Stop Sharing can reconnect an Android phone, Pause leaves other outputs live, and some previously fixed iOS recovery behavior is absent from this fork.

This review treats reliability, fast setup, predictable presentation controls, and easy coworker maintenance as the product requirements. It does not assume a customer-distributed product, cloud accounts, enterprise administration, or a need to build those things.

## Scope and evidence

- Repository: `/Users/codydirrigle/mirror-wall`, branch `cody-changes`, HEAD `43ae64e`.
- Running Mac app: version 0.128, embedded commit `52df36923cee6e26458713095028271ef0ad37fe`. Later commits through HEAD change Android branding/identity, so the running Mac UI is relevant to the Mac sources reviewed.
- Read the Mac receiver, slot/session lifecycle, Stage/Wall/settings, recording, Android capture/connection lifecycle, protocol, model/bezel mapping, packaging documentation, and core tests. Compared selected reliability and bezel work with the earlier DemoCast project on Sidehustle.
- Inspected the running Stage, Wall, and settings with an already connected iPhone. Did not deliberately stop its stream, change pairing/security settings, or conduct a new fleet rehearsal.
- Built the Swift package and ran its tests: **74 passed, zero failures**. The package has a core test target, but no Mac app test target covering the session and UI behavior below.
- Ran an isolated loopback test against this repository's actual `UDPReceiver.swift`: `stop()` returned after about 1.005 seconds while its callback was still executing.
- Ran the existing DemoCast C socket regression harness against a local checkout at the exact UxPlay commit pinned here, `ec203121355220dd90278a369eeabb0b8ba4f14a`. The one-second activity case passed; four aged-socket cases failed, including wake requests after 61 and 299 seconds. The fork's three patches do not change the affected HTTP loop. As a control, the same five cases all passed against the earlier patched DemoCast receiver source. This establishes a source-level regression, not a new device endurance test of the installed binary.
- Android tests/build, Windows execution, OBS output capture, fresh EMM installation, and multi-device endurance were **not** executed in this review. Android findings below are source-traced, not claimed as handset reproductions. The previously reported Samsung + Zebra + iPhone success is useful history, but is not a fresh validation of this fork.

Evidence labels: **Observed** means inspected in the running UI; **Reproduced** means an isolated executable check; **Source-traced** means the relevant path is identifiable in code but still needs a device/integration check. P1 means fix before an important live demo; P2 means address in the next reliability/usability pass.

## Prioritized findings

### R1 · P1 · Stop Sharing does not reliably end Android sharing

**Source-traced.** `Sources/MirrorWall/SlotStore.swift:524` implements Stop Sharing by restarting the receiver. That closes the connection, but `android/app/src/main/java/com/justfortonks/mirrorwall/cast/CastService.kt:278` treats the loss of a previously welcomed connection as recoverable and retries every two seconds for up to a minute. The receiver is available again, and `SlotStore.swift:175` automatically puts a newly connected phone on the Stage.

**Demo consequence:** a presenter stops a phone from the Mac, then the phone returns without another action on the handset. Ending a presentation and recovering from an accidental network drop currently use the same mechanism.

**Fix:** give intentional termination an explicit protocol meaning. The Android service should stop capture/retry on that message; transport loss should remain recoverable. Ensure the Mac's UI removes the device immediately and define a fallback for older companions that do not understand the new message.

**Acceptance:** Stop Sharing remains stopped for at least the full retry window; a brief network drop still reconnects; stopping one phone leaves the other two running.

### R2 · P1 · Pause freezes the Stage, while recordings and other outputs stay live

**Source-traced.** `Slot.swift:653` only saves a `frozenImage`. `StageWindow.swift:675` displays that image, while recording consumes live decoder frames through `Slot.swift:143` and `Slot.swift:382`. Screenshots use `renderer.currentImage` at line 332. The Wall and pop-out use the live renderer (`Views.swift:160`, `PopOutWindow.swift:233`), and the Syphon path is not gated by `isFrozen`.

The tooltip does describe a Stage-only freeze, but the visible control says **Pause**, and the code comment at `Slot.swift:59` explicitly gives entering a password as a use case. With OBS capturing a pop-out/Syphon feed or with recording enabled, content entered after Pause can still reach the output. Capturing the Stage itself has different behavior.

**Fix:** make the output contract explicit. The smallest honest change is **Freeze Stage**, with a clear indication that recordings and independent feeds remain live. If the intended purpose is privacy while preparing the next step, introduce a presentation freeze/cover that consistently applies to the outputs the presenter selected. Keep source capture and presentation policy separate.

**Related lifecycle issue:** `frozenImage` is not cleared by `Slot.stop()`. A frozen slot that disconnects and later receives a different phone can keep showing the earlier snapshot. Preserve a freeze across a reconnect only when the session/device identity warrants it; clear it on replacement.

**Acceptance:** use an innocuous changing test pattern after freezing, then inspect Stage capture, pop-out capture, Syphon, screenshots, and saved recording. Every route must match its advertised behavior. Replace the phone while frozen and confirm no stale device image is misattributed.

### R3 · P1 · Earlier iOS idle/wake recovery is missing

**Reproduced at the pinned receiver source; app policy also source-traced.** `scripts/build-uxplay.sh:11` pins the same UxPlay revision used by the earlier DemoCast fix, but `patches/uxplay-paused-control.patch` is absent. Its HTTP loop closes an aged socket when the next request arrives and then attempts a read from the removed socket. The existing C fixture produced zero handled wake requests and one invalid read for both 61- and 299-second RAOP inactivity cases.

Separately, `Slot.swift:668` applies the same ten-second silence limit to live, connecting, and screen-off states. `Sources/MirrorCore/SlotConfig.swift:139` does not supply the earlier `-reset 0` policy. A locked device that stops both video and check-ins can therefore be restarted by the app even if the user expects to wake and resume it. The 45-second Stage reconnect grace only preserves presentation space; it does not keep the original receiver session alive.

This is conditional, not a claim that every iPhone disconnects at ten or sixty seconds. During the UI inspection the current phone remained marked screen-off for several minutes, showing why a universal “about a minute” message is misleading.

**Fix:** port and revalidate the control-socket fix, explicitly choose which layer owns liveness, and distinguish screen-off grace from a dead connection. Reuse the earlier socket tests and add policy tests. Do not promise that the receiver can override iOS ending a session.

**Acceptance:** lock/wake at 15 seconds, 61 seconds, five minutes, and ten minutes, on power and battery, with both iPhone and iPad. Verify actual fresh frames after wake, not just a retained last picture. Test EOF and genuinely dead peers too.

### R4 · P1 · Receiver shutdown returns before work has drained

**Reproduced contract violation; downstream race risk source-traced.** `UDPReceiver.swift:66` says no callback runs after stop returns, but ignores a one-second semaphore timeout. The isolated test deliberately held a callback beyond that timeout and confirmed it was still running after stop returned. `Slot.swift:216` then resets the renderer, and the next start resets depacketizer state (`Slot.swift:160`). A queued main-thread frame notification only checks that some receiver exists (`Slot.swift:446`), not that it belongs to the current generation.

**Demo consequence:** a slow decoder/callback during stop/restart can overlap teardown or allow an old frame notification to affect the replacement session. A production crash was not reproduced; the prerequisite lifecycle violation was.

`ReceiverProcess.swift:71` also blocks while waiting for process exit, potentially 2.5 seconds per stubborn process, and `SlotStore.stopAll()` does this sequentially on the app's main actor. Multi-slot restarts can make controls unresponsive at the moment the presenter needs them.

**Fix:** stop asynchronously, await a real drain before releasing/resetting stream-owned state, and generation-tag queued frame/status delivery. Keep one owner for decoder/session resources. Avoid replacing the one-second wait with an unbounded wait on the UI thread.

**Acceptance:** delay a frame callback, restart twice, then deliver old callbacks; the new session must remain unchanged and the UI must remain responsive. Exercise shutdown with eight receivers and a deliberately slow child process.

### R5 · P2 · A second Mac instance can kill the first demo's receivers

**Source-traced.** `MirrorWallApp.swift:205` unconditionally calls `SlotStore.stopLeftoverReceivers()`. At `SlotStore.swift:304`, cleanup globally matches the UxPlay command line/device-ID pattern. There is no preceding Mac single-instance guard in this launch path. Starting a second installed copy or a development build can kill healthy receivers owned by the first copy.

**Fix:** establish app-instance ownership before cleanup; activate the existing instance or isolate receiver ownership. Only clean processes known to be orphaned. This matters during coworker testing and upgrades even if normal Finder launches usually activate the existing app.

**Acceptance:** while one copy is mirroring, launch a second built copy. Existing streams remain uninterrupted, and the user gets one clear active app.

### R6 · P2 · Android can forget the chosen receiver during its permission flow

**Source-traced.** `MainActivity.kt:55` holds the selected slot only in the `pending` field. `onCreate` does not restore it, and there is no saved-instance handler. The result handler at line 119 silently returns when `pending` is null. Activity recreation while Android's screen-capture or background-permission UI is open loses the destination.

**Fix:** save and restore the destination and the permission-flow step, reject unrelated result codes before consuming pending state, and show a useful retry state if restoration is impossible. Merely changing callback APIs will not preserve the destination automatically. Android's [activity lifecycle documentation](https://developer.android.com/guide/components/activities/activity-lifecycle) describes recreation and saved state.

**Acceptance:** rotate during each permission dialog; test activity recreation and background/return on Samsung and Zebra. Granting consent either starts the intended session once or produces an explicit retry prompt.

### R7 · P2 · Android reconnect can leave old sender threads waiting forever

**Source-traced.** After a welcomed connection fails, the reader catch block in `CastService.kt:234` closes the socket and posts `lost()`. It does not call `close(false)` or place `END` into that link's queue. The sender at line 244 can be blocked in `outbox.take()` when the queue is empty. `lost()` drops the current link reference and makes a replacement, leaving the old sender waiting.

**Fix:** centralize idempotent link termination so every exit closes the socket, releases the sender, and cancels pending link work. Bound the outbound queue and add a post-handshake liveness deadline; `soTimeout = 0` currently removes the reader deadline after welcome, so a network black hole need not surface promptly.

**Acceptance:** disconnect/reconnect a still screen repeatedly and observe a stable thread count. Test a silent network black hole as well as a clean TCP close. Verify retries and queued data remain bounded.

### R8 · P2 · Recording filenames collide, and finalization is not tracked across files

**Source-traced.** `SlotRecorder.swift:145` names a recording from the phone name, a timestamp with one-second precision, and a per-recorder part count. Two phones with the same name started together produce the same path. Rapid stop/start can also reuse a path. `Slot.swift:360` marks recording active independently of whether a file successfully starts, and the prominent recording indicators are driven by that state; the failure can be relegated to a tooltip/log.

At `SlotRecorder.swift:69`, each completed file starts asynchronous finalization and immediately drops its stored writer. The quit wait covers only the current writer; files already finalizing after rotation or Stop Recording are not tracked as a group. This creates a risk of unfinished files on immediate quit, not a reproduced corrupt recording.

**Fix:** include a unique session/file identifier, represent failed recording visibly, and track all outstanding writer completions through app shutdown without blocking the UI.

**Acceptance:** record two identically named phones simultaneously; stop/start within one second; rotate several times and immediately stop/quit; verify every resulting file opens and no failure is presented as a healthy REC state.

### R9 · P2 · Operator Wall contrast is broken in the observed light appearance

**Observed.** The Wall has the new saturated blue background, but several slot labels, icons, and supporting text render dark and are difficult to read. The toolbar also looks disconnected from the branded surface. See `Views.swift:21` and the inherited foreground styles throughout `SlotTile`. `DarkWindowAppearance` at line 579 expresses an intent to make the window dark, but did not produce a consistently legible SwiftUI surface in this run.

**Fix:** explicitly define foreground, secondary text, muted control, and surface tokens for the blue operator surface, or put operator cards on an appropriate neutral surface. Do not rely solely on setting the containing NSWindow appearance. Check light/dark macOS appearances and increased contrast with actual rendered controls.

**Acceptance:** names, connection state, recording state, and recovery actions are readable at a glance on a typical laptop/event monitor. Verify measured contrast when implementing; this review did not produce numeric contrast ratios.

### R10 · P2 · Stage controls do not have a narrow-window or many-device layout

**Source-traced layout constraint.** The Stage allows a 320×180 minimum window (`StageWindow.swift:34`). Its control bar is an HStack containing every device chip plus global actions, forced to intrinsic width with `.fixedSize()` at line 430; chips also use `.fixedSize()` at line 527. Long device names or several phones exceed the available width rather than moving into an overflow arrangement.

**Fix:** keep the essential actions available at every supported size; put the device list in a compact menu/scrollable region when necessary and place secondary settings in overflow. Constrain names with truncation and full-name help. Use `ViewThatFits` or equivalent deliberate layouts rather than simply shrinking all text.

**Acceptance:** 320-, 640-, and 1280-point windows with one, three, and eight devices, mixed orientations, and long names. Every action remains reachable by pointer and keyboard without covering important phone content.

### R11 · P2 · Hiding a phone does not survive reconnect

**Source-traced and explicitly coded policy.** `SlotStore.swift:175` sets `showsOnStage` back to true whenever a slot newly enters a connected state. A presenter can take a phone off Stage, work on it privately, then have a brief network outage put it back in front of the audience.

This may be an intentional Stage-first choice, but it conflicts with a reasonable demo expectation: **Hide** is presenter intent until **Show** is chosen again.

**Fix:** preserve visibility for the same device across transient reconnects. Distinguish first connection from recovery and slot reuse. If automatic presentation on first connection is retained, make that behavior clear.

**Acceptance:** hide a connected phone, reconnect it, and confirm it stays hidden; a newly admitted phone follows the chosen first-connection policy. This is a behavior decision that needs explicit agreement before implementation.

## Event-network decision

The Android path uses plain TCP (`CastServer.swift:38`) and sends a self-reported device ID. The allow-list at `Slot.swift:534` compares that value; it is not cryptographic device identity. The event PIN applies to AirPlay, and the settings correctly disclose that Android does not ask for it. A reachable Android client is accepted into a free slot by default, then automatically staged.

For a home-office or dedicated SE travel-router network, this can be an explicit pilot tradeoff. For a shared event LAN, the user can choose the wrong receiver or an unintended device can join, and traffic has no application-layer encryption. Before shared-network use, add lightweight session admission and authenticated encryption, or make an isolated demo network an explicit operational requirement. Avoid an enterprise account system; a pairing code/QR and pinned receiver trust can serve the narrow need.

Also cap pre-handshake connections and impose a hello deadline (`CastServer.swift:66`). Currently every accepted socket is retained until it ends, without a handshake budget. A buggy/stalled client should not be able to consume resources indefinitely.

## DemoCast feature carryover

These are parity decisions, not a demand to transplant the whole older architecture.

| Earlier requirement/work | Current fork | Decision needed |
| --- | --- | --- |
| Multiple Android/iOS devices | Multiple slots, Stage layouts, shared decoder outputs | Keep; rehearse current fork with the actual mixed fleet |
| Portrait and landscape | Bezel geometry rotates with source dimensions | Keep; verify layout while several devices rotate independently |
| Model-specific iPhone, Zebra HC50/TC53e, iPad 11th-generation bezels | Four automatic categories: home button, notch, Dynamic Island, plain | Restore required model presets and a manual override if those outlines remain in scope |
| iPad/Zebra physical sizing | `PhoneModels.swift` only maps iPhone model codes; unknown models use a reference size | Do not label unknown-device sizing as physically accurate; add known sizes or use an honest fallback |
| Longer iOS idle/wake recovery | Earlier receiver patch and separate paused policy absent | Restore with regression tests (R3) |
| Android pairing/trust and managed configuration | Discovery/manual host, plain TCP, no managed-configuration resources found | Decide the supported home/event network setup and EMM provisioning scope |
| Android permission-flow recovery | Pending slot is activity-local | Restore saved-state handling (R6) |
| Reliable shutdown/recording ownership | Simpler paths reintroduce gaps above | Port the behavior and tests, not necessarily the old implementation |

The iPhone table does include the 12–17 families, SE entries, and 16e; the concern is not that every iPhone falls back to a plain frame. The missing capability is model-specific geometry/selection, especially Zebra and iPad. All non-iPhone model codes currently become `.plain` in `Sources/MirrorCore/PhoneBezel.swift:19`.

## UX design plan

These are proposed refinements grounded in the existing Stage/Wall workflow. They are not an approved product specification. Functional behavior changes are identified separately from visual changes.

### Phase 1: dependable operation

1. **Resolve control semantics first.** Label Stage-only freezing accurately, make Stop Sharing final, and preserve deliberate hiding. Show connection state, presentation state, and recording state separately. “Screen off,” “Frozen on Stage,” and “Reconnecting” should not all look like an unspecified pause. Functional work: R1, R2, R11.
2. **Keep recovery and recording status visible to the presenter.** A phone can retain a last frame during recovery, but it must not be mistaken for current video. The caption currently says “Live demo” even when there are frozen or screen-off devices. Make operator status accurate without filling the audience view with diagnostics.
3. **Fix Wall contrast and Stage overflow.** These are targeted visual/layout changes, not a redesign. R9 and R10.
4. **Reduce operator terminology.** Prefer “Add device space” or another tested plain label over “Slot.” Explain once that the receiver name is what the phone selects. Keep technical ports and codecs in diagnostics.

### Phase 2: clarity and consistency

- Give the presenter a local display alias such as “Zebra — nurse workflow,” separate from network/device identity. The current raw device name dominates the caption. This requires a small data-model/UI feature, not just styling.
- Organize each Wall card around device name, live/reconnecting/screen-off status, Stage visibility, and recording. Keep configuration and troubleshooting in a secondary menu. Let a one-to-three-device Wall use the available area more effectively; the observed one-phone Wall left most of the window empty.
- Keep the Stage's current visual restraint. Avoid adding navigation, administrative controls, or more decorative chrome to the audience surface.
- Consolidate typography and spacing into `Brand`/shared view tokens. Proposed semantic tokens: `operatorSurface`, `onOperatorSurface`, `secondaryOnOperatorSurface`, `statusLive`, `statusWaiting`, and `statusError`. Choose actual values by checking the rendered blue/neutral surfaces, not by inventing a second palette in each component.
- Treat recording as its own status: “Recording,” “Saving,” “Saved,” or “Failed,” with a useful location/action. A red indicator should mean the recording is healthy, not merely requested. Requires recording state work from R8.

### Phase 3: polish after reliability

- Refine empty-state instructions into separate iPhone/iPad and Android steps; make the receiver name obvious and copyable. Keep event-network troubleshooting one step away.
- Check keyboard focus, control names, and VoiceOver announcements for every icon-only control and changing connection status. The AX tree exposes useful labels today, but this was not a complete assistive-technology audit.
- Add restrained recovery transitions that preserve device order and geometry. Never let a status animation imply fresh video when only a held image exists.
- Validate the same hierarchy on a laptop, an external event monitor, and a screen-share-sized Stage. Test reduced motion and increased contrast during this phase.

## Engineering and handoff recommendations

The current local architecture is appropriate. Keep the pure `MirrorCore` module and the decoder shared by multiple views. Avoid a broad rewrite. The improvement with the highest return is a small, testable session boundary that owns connection generation, cancellation, and resource draining, plus a separate presentation policy for visibility/freeze and recording state.

Use these invariants to drive tests:

- A stopped session cannot update a replacement session.
- Intentional Stop cannot trigger automatic retry.
- Presenter visibility/freeze decisions have an explicit lifetime and device identity.
- Every output obeys its declared presentation policy.
- Recording success means a writer actually started, and all pending files finish before normal quit completes.

Add a Mac application-logic test target or extract the small lifecycle/policy components into a testable module. More parser tests alone will not catch these integration failures.

The fork's handoff documentation also needs a short update. `README.md:11` and its Android installation links still lead to `justfortonks/mirror-wall`, while `Sources/MirrorCore/LatestRelease.swift:47` points updates to `yurtbeer/mirror-wall`. The changelog's top entries describe upstream work rather than the new fork controls and branding. A coworker following the README can therefore install a different app than the one being handed over.

Document one supported install/update source, the tested Mac/Android versions, signing ownership, the Android application-ID migration, and the exact build commands. Android now uses `com.imprivata.mirrorwallcast`; treat that as an installation/EMM assignment change, not merely a display-name change. Keep private signing material outside the repository. The committed public test key is explicitly documented as a test key; it is not a leaked production credential, but should not silently become the team's long-term signing identity.

## Rehearsal gate before coworker takeover

| Scenario | Required result |
| --- | --- |
| Samsung + Zebra + iPhone together, 30–60 minutes | Stable identity/order; no accumulating threads or unexpected restarts |
| iPad 11th generation + iPhone SE/e + Zebra HC50/TC53e | Readable portrait/landscape layout; correct chosen bezel or clearly generic fallback |
| iOS lock/wake at 15s, 61s, 5m, 10m; on charger and battery | Fresh frames return or clear recovery guidance; no misleading live state |
| Pause/freeze while recording and using OBS | Stage, pop-out, Syphon, screenshots, and saved movie match the declared policy |
| Stop one Android phone from Mac | It stays stopped; other devices continue |
| Hide a phone, interrupt network, reconnect | It remains hidden unless presenter chooses Show |
| Rotate during Android permission prompts | Correct destination survives; no silent failure or duplicate capture |
| Repeat Android disconnect/reconnect 20 times | Threads, queue sizes, and memory remain bounded |
| Two devices with the same name; recording rotation then immediate quit | Unique, playable files; accurate recording status |
| Launch a second build while first is live | No receiver interference |
| 1/3/8 devices, small Stage and long names | Essential controls always accessible |
| Home Wi-Fi and dedicated event router; discovery blocked | Documented manual fallback works; admission behavior is clear |
| Intune, Workspace ONE, SOTI pilot installation/update | Correct app ID/signature, assignment, capture consent, background behavior, and update path verified on managed fleet |
| Mac sleep/wake, power change, external monitor removal | Clear recovery; Stage remains usable and ordered |

Recommended implementation order: R1–R4 together as the demo-control/lifecycle reliability pass; R5–R8 as the companion/recording hardening pass; R9–R11 plus chosen bezel parity as the operator-experience pass. Correct fork installation documentation immediately before distributing a test build. For shared event networks, settle admission/trust before deployment.

No application source or installed binary was changed during this review.

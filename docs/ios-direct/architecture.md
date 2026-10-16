# Repository architecture at G0

2026-10-16; source revision `70e2f1a1d48ca65ea26fc2a0592760eb543795b3`. All current-state sections below are **Verified (local source evidence)**, not live behavior. Paths and line numbers are relative to the repository root at that revision.

## Repository map

| Area | Ownership / evidence |
| --- | --- |
| Product docs | `README.md` describes eight slots, AirPlay, Android companion, screenshots/recording and optional OBS. `docs/details.md` covers operational behavior; `docs/building-mac.md` covers receiver patches/bundling; `docs/mirror-wall-cast.md` specifies Android wire compatibility. |
| Change history | `CHANGELOG.md:8` records OBS/window rename behavior and beta build selection; `:21` Android frames; `:50` stage. These are source history claims, not regression results from this run. |
| Swift package | `Package.swift:1` tools 5.9; `:10–21` MirrorCore and MirrorWall executable, one MirrorCoreTests target; `:29` macOS 14 minimum. Optional binary Syphon dependency only when `Vendor/Syphon.xcframework` exists; absent in this worktree. |
| Tests | `Tests/MirrorCoreTests/MirrorCoreTests.swift` contains 80 `func test` declarations: RTP, H.264/HEVC depacketization/description, slot config/window names, UxPlay events, packaged environment, stream/record/playout clocks, phone models/bezels, cast protocol, stage layout, changelog/update logic. This is a static declaration count; none executed in run 0. No new iOS capture/radio tests exist. |
| macOS app | `Sources/MirrorWall/MirrorWallApp.swift`, `Views.swift`, `Slot.swift`, `SlotStore.swift`: SwiftUI/AppKit lifecycle and views. `Updater.swift` handles explicit update selection/install; not part of the POC. |
| Android | `android/app/build.gradle.kts:15` Kotlin Android app; minSdk 29 (Android 10), compile/target 35, JVM 17. `CastService.kt:124` MediaProjection, `ScreenEncoder.kt:24` MediaCodec, foreground mediaProjection service in AndroidManifest.xml. `MainActivity.kt` NSD discovery plus manual host/port; `CastProtocol.kt:35` same Bonjour type. |
| Windows | Separate .NET 10 WPF app (`windows/MirrorWall/MirrorWall.csproj:5`); C# MirrorCore/tests; UxPlay/GStreamer build/patch/smoke test under `windows/receiver/`; Inno Setup installer; SpoutDX bridge under `windows/MirrorSpout/`. `SlotRenderer.cs:98` owns a VideoDecoder; `VideoDecoder.cs:67` FFmpeg low-delay decode. Windows runtime requirement in README/guide: Windows 10 1809+ or Windows 11, x64. No Windows or Android commands ran here. |

## AirPlay/UxPlay path

`Slot.start` creates a localhost UDP receiver, then one `ReceiverProcess` per slot (`Sources/MirrorWall/Slot.swift:133–181`). `ReceiverProcess.swift:47–65` launches UxPlay with a pseudo-terminal for prompt line-by-line events; packaged GStreamer environment is selected at `:34–44`. `UxPlayEvent` maps logs into slot state. UxPlay performs external AirPlay handling/decryption; Swift receives its decrypted media on loopback. The external receiver's complete auth/crypto implementation was not present/audited here; no claim of new POC pairing security follows from AirPlay support.

`Sources/MirrorCore/SlotConfig.swift:103–117,137–162` defines:

| Slot n (1…8) | Ports / configuration |
| --- | --- |
| AirPlay | base `7200 + 100n`, base+1, base+2 TCP/UDP (slot 1: 7300–7302) |
| Local media | UDP `5598 + 2n` (slot 1: 5600); `UDPReceiver.swift:42–49` binds **127.0.0.1** |
| Android cast | TCP base+50 (slot 1: 7350; slot 8: 8050) |
| UxPlay options | Independent name/device ID, `-vsync no`, `-as 0` (audio off), requested 30/60 FPS, `-nc no`, `-vrtp config-interval=1 ! udpsink sync=false host=127.0.0.1 …`; optional H.265 and device-ID allow-list |

RTP parsing (`RTPPacket.swift`) → per-slot `H264Depacketizer` (H.264 single NAL/STAP-A/FU-A; HEVC single/aggregation/fragments, marker/timestamp boundaries, packet-loss tracking) → `H264Frame` → `Slot.deliver` (`Slot.swift:379–449`). `Sources/MirrorCore/H264Depacketizer.swift:7–25` defines an access unit as NAL byte arrays without start codes, UInt32 90 kHz timestamp, codec, and computed keyframe status.

## Android cast path — likely media adapter pattern

`Sources/MirrorWall/CastServer.swift:39–53` creates a **plain `NWParameters.tcp`** listener (reuse/noDelay) and Bonjour `_mirrorwall._tcp` per slot. There is no TLS, cryptographic peer authentication, or explicit `includePeerToPeer` opt-in in this path. Android `CastService.kt:193–205` uses ordinary `java.net.Socket`; Windows `CastServer.cs:25–39` uses TcpListener. Current discovery/transport is a LAN path; direct/offline operation is unverified.

`Sources/MirrorCore/CastProtocol.swift:5–30,79–129,136–201`:

- One byte type + four-byte big-endian payload length + payload; incremental TCP reader; maximum payload 16 MiB; unknown types skipped, malformed known payloads rejected. Version 1 with optional fields/lower-version negotiation per `docs/mirror-wall-cast.md:52`.
- `0x01` hello JSON: protocol/name/model/deviceID; `0x81` welcome JSON: protocol/slot/maxFrameRate/sharpPicture; `0x82` busy JSON reason.
- `0x02` video: eight-byte big-endian signed capture microseconds followed by one Annex B H.264/HEVC access unit. Parameter sets accompany keyframes; codec sniffing in `CastProtocol.swift:236–249` and capture-time conversion to 90 kHz.
- `0x03/04` paused/resumed, `0x05` heartbeat (Android every 2 seconds), `0x06` bye, `0x84/07` ping/pong eight-byte echo, `0x08` orientation quarter-turn byte. No audio message.

Hello is admitted on the main queue only if the slot is free and any allow-list matches the **self-reported** deviceID (`Slot.swift:512–542`). This is a convenience filter, not proof of identity. The slot stops UxPlay on cast admission, withdraws its advert while occupied (`:26–32`), and restarts a fresh receiver after the phone leaves (`:545` onward). One phone owns a slot. CastServer keeps accepted/incomplete connections in an array (`CastServer.swift:16,66–73`); this implementation has no explicit handshake deadline or independent unauthenticated-connection cap.

Video callbacks stay on the cast queue and are ignored before admission (`Slot.swift:468–477`). `handleCastVideo` splits Annex B, creates a compressed `H264Frame`, and calls `deliver` under `streamLock` (`:391–398`), bypassing RTP. UI state/control callbacks go to main. Its arrival-minus-phone-time statistic explicitly has an unknown clock offset (`:399–404`); it is not optical end-to-end latency.

## Renderer input, decoder and timing ownership

**Answer: `H264Renderer` accepts compressed access units through `render(_ frame: H264Frame, arrival: Double)`. It has no public decoded-pixel-buffer input.** It exposes decoded images as outputs/accessors; its pixel-buffer `present` function is private.

| Evidence | Meaning |
| --- | --- |
| `Sources/MirrorWall/H264Renderer.swift:15–35,110–153` | Per-instance codec/parameter sets, format description, VTDecompressionSession, keyframe wait, layers, last picture and playout clock; consumes compressed NALs and builds length-prefixed AVCC samples. |
| `H264Renderer.swift:155–160,188–208` | Renderer creates/invalidates VideoToolbox decoder, submits compressed frame, receives image buffer, invokes `present` and `onPicture`. There is no extra decoder in Slot or CastServer. Hardware decode is not forced (`decoderSpecification: nil`); acceleration unmeasured. |
| `H264Renderer.swift:54–66,212–255` | `onPicture` is decoded output for recording; `onShow` is output at display time; `currentImage` returns last displayed image. Private `present` shows immediately, or schedules via its own playout queue/clock. `onShow` executes with renderer lock held and must return quickly. |
| `Sources/MirrorCore/PlayoutClock.swift:10–15,34` | Optional smoothing uses 90 kHz timestamps, default 100 ms delay and arrival-based offset estimation. Renderer wraps decoded pixel buffers into immediate-display CMSampleBuffers and distributes to all layers. It owns output timing. |
| `H264Renderer.swift:13–14,169–185` | Render/reset must be serialized on the input thread or after input stops; layer add/remove on main. Reset invalidates decoder/parameter sets and clears displayed picture. |

`render` returning true means handed to decoder, not proof that a frame was displayed (`:107–108,166`). Future displayed-FPS instrumentation must count presentation output, not this return value.

## Slots, outputs and persistence

| Area | Ownership / references |
| --- | --- |
| Slot | `Slot.swift:23–128`: configuration/state, own renderer, process/UDP/cast ownership, recorder with recorderLock; streamLock serializes inputs. Generation counter protects process lifecycle callbacks. `stop:184–205` stops sources and resets renderer/state. |
| SlotStore | `SlotStore.swift:7–79,81–109`: MainActor; owns slots (default two, max eight), own-window dictionary, stage window, UserDefaults/settings/allow-list. Start/stop/add/remove at `:261–317`, source settings `:318–347`, persistence `:613`. |
| Tile/pop-out/stage | All use `VideoLayerView` with the same slot renderer (`Views.swift:144,456–506`, `PopOutWindow.swift:232`, `StageWindow.swift:159`). Each view gets a new display layer, not a new decode. Store owns windows (`SlotStore.swift:421–468`); StageWindow watches slots and uses StageLayout/physical phone sizing, selectable membership and layouts (`StageWindow.swift:6–79`; `Sources/MirrorCore/StageLayout.swift`). |
| Recording | Slot wires `onPicture` → recorder (`Slot.swift:125–127,339–374`). `SlotRecorder.swift:44–59,89–136` re-encodes decoded pixel buffers as video-only H.264 MOV via AVAssetWriter/adaptor; RecordingClock uses media timestamps/arrival. Rotation/connection boundaries split files; finish logic at `:65–86`. New-source recording is not validated. |
| Screenshots | Slot uses renderer.currentImage (`Slot.swift:321`); `Screenshots.swift:14–27` saves unframed PNG with collision suffixes through CoreImage. SaveFolders supplies configurable defaults under Documents/MirrorWall. |
| Syphon / OBS | `Slot.swift:224–240` installs renderer.onShow → SyphonFeed; store sends standby on disconnect. `SyphonFeed.swift:19–75,113–175` owns Metal server/texture transfer and bounded latest waiting image, optional bezel composite. `:203–212` is the no-Syphon stub. Framework absent here; live OBS not run. Windows uses Spout, separate code. |
| Bezels | `Sources/MirrorCore/PhoneBezel.swift` and PhoneModels select geometry/model, plain fallback and Android photo artwork. `PhoneBezelView.swift:8–24` wraps UI; PhoneBezelDrawing supplies UI/OBS artwork. Screenshot/record pixels remain unframed. Exact POC iPhone models are TBD. |

## Packaging, minimum OS and CI

**Verified (local source evidence):** `scripts/build-uxplay.sh:11` pins `ec203121355220dd90278a369eeabb0b8ba4f14a`, applies repository patches (latency, frame timestamps, quiet crash), and can archive source. `scripts/bundle-receiver.py` copies/relinks receiver dependencies/plugins and ad-hoc signs nested binaries into `Contents/Resources/receiver`. `scripts/build-syphon.sh` builds the optional XCFramework. These scripts were read, not executed.

`scripts/build-app.sh:6–7,41–64,86–106` release-builds, generates `com.justfortonks.mirrorwall` Info.plist with macOS 14 metadata and local-network/Bonjour declarations, bundles resources/receiver/Syphon/licenses/changelog, ad-hoc signs and verifies. No Developer ID/notarization step exists there. `scripts/make-dmg.sh` requires bundled UxPlay and creates DMG. Source minimum macOS 14 differs from README packaged Apple Silicon/macOS 26+ requirement because bundled native libraries depend on build host (`docs/building-mac.md:79–84`); this audit does not establish a runnable release minimum by testing. Keep production minimum unchanged. Prototype Mac target minimum remains a separate decision (proposed macOS 14 for Candidate A).

`.github/workflows/release.yml:46–80` configures macos-26, dependencies/UxPlay/Syphon, swift test, DMG checks; release/publish coordinates Windows and Android. `windows.yml:26–81` configures receiver smoke test and dotnet tests/build/installer. `android.yml:23–60` configures Java 17, unit tests/APK and optional AAB with private signing; fallback public test key in android/app/build.gradle.kts. `beta-builds.yml` changes offered prereleases. These are configured workflows, not current passing CI evidence. No release/signing workflow is changed.

## Absent features and proposed seam — Hypothesis where proposed

**Verified (local source evidence):** no USB capture implementation exists in `Sources/`: `rg -n 'USB|AVCapture|CoreMediaIO|CMIO|ScreenCaptureKit|ReplayKit' Sources` returned no matches. README limitations and `docs/details.md:144` also call USB absent/planned. No iOS companion, direct iOS transport, authenticated offline pairing, or POC capture/encode pipeline is implemented. USB regression is N/A; existing AirPlay/Android/record/OBS hardware regression is not run.

**Hypothesis (recommended integration after G4 and G5 review):** keep independent receiver/session registry first. One authenticated phone identity + session generation owns its parser, bounded queues, decoder/render state, metrics and cancellation. Translate negotiated H.264 configuration/access units into `H264Frame` (NAL arrays, 90 kHz timestamps, SPS/PPS plus fresh IDR) and reuse one renderer per eventual slot, following `Slot.handleCastVideo` → `deliver`. Avoid synthetic RTP, UxPlay, duplicate decode, or re-encoding to fit the display path. Standalone receiver first owns its own decoder/view; any renderer extraction/reuse is a later reviewed change.

This is a **pattern**, not a ready public adapter: handleCastVideo/deliver are private, admission is Android-specific, `deliver` UI/stat updates guard `receiver != nil`, and slot startup currently depends on UxPlay (`Slot.swift:133–181,420,436`). G5 must propose a narrow source/lifecycle adapter and explicit development source selection that handles start/stop/reset/identity/format changes without fake UDP ownership. Keep production Cast v1/service/ports compatible; new TLS listener/service and pairing protocol remain separate. Audit stale callbacks, queue limits and A/B isolation before reuse. Recording/screenshots/bezels/stage/OBS remain potential downstream reuse, with separate integrated regression evidence required.

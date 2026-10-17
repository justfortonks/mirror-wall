# G3a receiver presentation

Every compressed frame goes through the session's decoder while no more than eight
units are outstanding and the oldest unfinished unit is under 300 ms old. Passing
those limits abandons that prediction chain, requests an IDR once, and drops inter
frames until the IDR. Decode errors remain separate from queue recoveries. Normal
bursts do not reset the decoder. Identical config records preserve config/decoder
state; if VT was invalidated, they only recreate VT without a config-change event.

Immediate mode is the default. A 1 ms dispatch turn coalesces simultaneously ready
decoded pictures: every unit is decoded/ACKed, but only the newest ready image is
enqueued to the layer. Superseded images count as `displaySkipped`, not errors.
The optional **Smooth (100 ms buffer)** toggle maps sender PTS deltas onto a local
playout clock using the quickest recent arrival offset, with a 100 ms delay. It
keeps at most eight decoded images, coalesces overdue ones, and never skips decoder
references. Mode changes are logged as `video.presentationMode`; snapshots include
`presentationMode` (`immediate` / `smooth100ms`). Each session owns its own clock.

Recovery/config changes use `flush()` and keep the last picture visible. Session
close/disconnect uses `flushAndRemoveImage()`, leaving black under the disconnected
state. `displayed` counts successful decoded-image enqueues, not physical scanout.
`displayedFPS` divides enqueue deltas by actual elapsed time, including the final
partial second. `decodeQueueDepth` is the maximum outstanding depth since the last
metrics line; `decodeQueueDepthCurrent` is depth at sampling. `recoveries` contains
cumulative counts by reason; `displaySkipped` counts decoded images coalesced,
superseded, or discarded by a mode/config/recovery/close transition. Layer readiness
failures remain `displayDrops`. An identical config does not reset these counters.

The window follows source dimensions plus CGImagePropertyOrientation. Quarter-turn
orientations swap its content aspect; geometry changes resize it once while keeping
the frame center and longest content edge. Repeated configs and per-second stats do
not resize it. The display layer keeps its existing orientation transform.

Shared policy tests cover a six-frame decode burst with one newest presentation,
eight-frame/300 ms limits and IDR gating, idempotent config, playout/default mode,
bounded decoded buffers, orientation aspect and final-interval FPS. Device testing
must verify smoothness, held picture during recovery, rotation/center behavior and
the visible latency-clock Done button. Done dismisses only the clock cover; capture
and transport keep running. No new device result is claimed by these source fixes.


G3b-fix window ownership: one NSWindow per HMAC-verified deviceID, titled with the
stored device label. Each authenticated session still gets a private renderer and
layer. Reconnect reuses the window/position/geometry, installs that fresh layer,
and ignores all later samples from its predecessor session. Disconnect clears to
black with Disconnected; the next session shows Waiting for video. Manual close
removes the window entry and the next video session opens it again. Same-label
phones remain separate. Capture generation restart within one session continues
using that renderer/window. Device verification remains required.


## G3d rotation controls and diagnostics

Rotate in the video-window toolbar or press **⌘R** to cycle clockwise through
0/90/180/270; **⌘0** resets. Both switch to manual. The manual angle is remembered
per verified deviceID in this receiver's UserDefaults domain. **Auto-rotate** is
initially off; enabling it follows the latest capture hint, otherwise device hint,
and the stats overlay reports the source. Hint state resets on session rebind.
Layer transform/aspect changes preserve decode and playout; quarter turns resize
once around the window center. A 180° change keeps the frame size.

Sender probes sample/image attachments in `capture.rotationAttachments` (first
screen callback, then changes only, at most 1/s; metadata only). Device notifications
and background-during-capture counts appear in `capture.deviceOrientation` /
`capture.orientationNotificationSummary`. Only device hints are currently emitted:
no usable new capture signal is verified. Physical orientation is a hint, so a
locked app or missing background notifications can require manual rotation. See
[Rotation signal](../../../docs/ios-direct/feasibility.md#rotation-signal) for findings
and the remaining device checks. Protocol stays v3 with a bounded 11-byte hint.

Validation: **76 Shared tests pass (71 existing + 5 new)**, including strict hint
encoding/bounds, manual/auto state, capture preference, composed aspect and real
TLS hints interleaved with video fragments without config/reassembly recovery.
The injected loopback consumer does not exercise VideoToolbox or visible rotation.
All Sender/Receiver sources pass direct arm64 SDK typechecks (iPhoneOS 27.1 /
macOS 27.0, Swift 5 mode); this is not a linked/signed build or device acceptance.
No installs, commits or pushes; historical `results.md` is unchanged.

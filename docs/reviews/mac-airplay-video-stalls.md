# Mac AirPlay video stalls: review findings

Reported on Mirror Wall 0.162 with iPhones using AirPlay and Sharper Picture enabled (H.265). Video disappears or freezes, then returns approximately a minute later without restarting the app, slot, or phone mirroring. The user believes the slot still said Live.

Reviewed main at 2091505d66ccfbb7bfa9d9de032f456aa4c2aebc. These are code findings and hypotheses, not a confirmed diagnosis of the incident. No runtime behavior is changed by this PR.

## 1. Stop-flag recovery counts codec messages rather than incoming video

In patches/uxplay-stuck-stop-flag.patch, recovery requires 20 stop-marked codec messages within two seconds. Each new window resets the counter. A stop message followed by ongoing video with sparse codec messages can therefore leave the forwarding pipeline paused until a normal codec message or sufficiently rapid burst arrives.

The pinned UxPlay video_renderer_pause implementation sets the entire forwarding pipeline to GST_STATE_PAUSED:
https://github.com/FDH2/UxPlay/blob/ec203121355220dd90278a369eeabb0b8ba4f14a/renderers/video_renderer.c#L512-L529

Validation: extracted the counter branch into a temporary C harness. At 1, 5, and 9 stop-codec messages per second it remained paused for the full 120-second simulation. At 10/s it resumed after 1.9 seconds. This validates the threshold gap, not the phone's actual incident traffic.

Suggested direction: use sustained actual video arriving despite the stop flag as recovery evidence, with an elapsed-time bound. Preserve real screen-lock pause behavior.

## 2. Successful submission is counted as a picture

Sources/MirrorWall/H264Renderer.swift:155-166 returns the immediate decode call status. Its output callback silently returns on an error or missing image.

Sources/MirrorWall/Slot.swift:424-458 treats that return value as a shown frame and updates lastFrameAt, hasPicture, stream frame counts, and Live state. Those indicators can look healthy without a decoded picture.

Suggested direction: track packet arrival, successful decoded output, and display submission separately. Update picture timestamps from successful output and log decode failures with useful error codes.

## 3. Heartbeats mask a stalled video path

Sources/MirrorWall/Slot.swift:618-620 refreshes lastSignOfLifeAt on phone check-ins. The watchdog at 637-649 only tests that combined timestamp, so check-ins can keep a stalled video path alive indefinitely.

The 75-second paused-to-Live branch only changes the label; it does not resume the receiver pipeline or repair decoding. No fixed one-minute video recovery mechanism was identified.

Suggested direction: diagnose video stalls separately from connection loss, while allowing legitimately static or paused screens. Avoid restarting a healthy connection solely because a static screen sends no frames.

## Review and validation requested

- Verify the stop-flag gap against real H.265 traffic and consider a bounded recovery rule.
- Review decoder callback error handling and picture accounting.
- Add diagnostics that distinguish receiving, decoding, and displaying failures.
- Validate genuine screen-lock/wake, static-screen, rotation, and normal disconnect behavior.
- Capture affected-Mac logs during a recurrence before claiming a root cause.

No live-phone reproduction was performed. Logs available on the inspected host were from an older 0.157 installation and were not used as evidence for the reported 0.162 incident.

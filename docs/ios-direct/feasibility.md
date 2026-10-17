# Feasibility and SDK probes — G0

Date: 2026-10-16. **Verified (local evidence)** means only the command output or source declaration quoted here. No iOS target was compiled, signed, installed or run. Framework presence and SDK annotations are not runtime capability tests.

## Toolchain and device inventory — Verified (local evidence unless supplied)

| Probe | Result |
| --- | --- |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` (unchanged) |
| `xcodebuild -version` | Xcode 27.1; Build version 27A9275 |
| `xcrun --sdk iphoneos --show-sdk-version` | **27.1** |
| `xcrun --sdk macosx --show-sdk-version` | **27.0** |
| `sw_vers` | macOS 27.0.1; build 26A434 |
| `swift --version` | swift-driver 1.168.6; Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1); target arm64-apple-macosx27.0.0 |
| Mac hardware (supplied by user) | MacBook Air M5; radio state/runtime capabilities not measured |
| Phones (supplied by user) | Two actual iPhones, iOS 27+; A user's Apple Account, B no Apple Account; exact models/builds **TBD** |
| Signing (supplied by user) | Free Xcode Personal Team only; no paid program, Wi-Fi Aware entitlement or TestFlight |

SDK roots from `xcrun --sdk <name> --show-sdk-path`:

- iPhoneOS: `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk`
- MacOSX: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk`

Some Xcode invocations also emitted `DVTFilePathFSEvents: Failed to start fs event stream.` SDK versions/paths were still returned. No Xcode selection, settings, profiles or radios were changed.

`xcrun devicectl list devices` returned exit **1**, with no device inventory:

```text
Install Failed: Failed to create install request.
ERROR: Timed out waiting for CoreDeviceService to fully initialize. This is likely a bug in CoreDevice. Please file a bug report against CoreDevice | X. (com.apple.coredevice.devicectl error 1 (0x01))
```

This is an initialization failure, not evidence of zero connected/available devices. No service repair or retry workaround was attempted.

## Capture declarations — Verified (local SDK headers)

Read iPhoneOS public headers (not just a macOS declaration). Exact class availability:

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCContentSharingPicker.h`

```text
72: API_AVAILABLE(macos(14.0), macCatalyst(18.2), ios(27.0), visionos(27.0), tvos(27.0))
73: @interface SCContentSharingPicker : NSObject
74: - (instancetype)init NS_UNAVAILABLE;
129: - (void)present API_AVAILABLE(macos(14.0), macCatalyst(18.2), ios(27.0), visionos(27.0)) API_UNAVAILABLE(tvos);
157: - (void)presentPickerForCurrentApplication API_AVAILABLE(ios(27.0), visionos(27.0), tvos(27.0)) API_UNAVAILABLE(macos, macCatalyst);
```

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h`

```text
206: API_AVAILABLE(macos(12.3), macCatalyst(18.2), ios(27.0), visionos(27.0), tvos(27.0))
207: @interface SCStreamConfiguration : NSObject
474: API_AVAILABLE(macos(12.3), macCatalyst(18.2), ios(27.0), visionos(27.0), tvos(27.0))
475: @interface SCStream : NSObject
```

All three requested capture symbols are found and declare iOS **27.0** availability. Picker `present` is available on iOS 27; current-application-only entry point is separate. Class availability does not make every member usable: picker-for-existing-stream and maximumStreamCount are explicitly unavailable on iOS (`SCContentSharingPicker.h:90,143,151`). Full-display background capture, encoder execution, stop behavior and free-team provisioning are still untested.

## Wi-Fi Aware — Verified (local SDK interfaces)

Both SDKs contain `System/Library/Frameworks/WiFiAware.framework`, a link stub and Swift interfaces. The relevant native interfaces are quoted below; neither enclosing declaration grants macOS availability. supportedFeatures has no separate availability annotation; it inherits WACapabilities' restrictions.

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/WiFiAware.framework/Modules/WiFiAware.swiftmodule/arm64e-apple-ios.swiftinterface`

```text
97: @available(iOS 26.0, *)
98: @available(macCatalyst, unavailable)
99: @available(watchOS, unavailable)
100: @available(macOS, unavailable)
101: @available(tvOS, unavailable)
102: @available(visionOS, unavailable)
103: public struct WACapabilities : Swift::Sendable {
104:   public enum Feature : Swift::Sendable, Swift::Hashable, Swift::Equatable, Swift::CaseIterable, Swift::Codable {
105:     case wifiAware
124:   public static var supportedFeatures: Swift::Set<WiFiAware::WACapabilities.WiFiAware::Feature> {
125:     get
126:   }
127:   public static var maximumConnectableDevices: Swift::Int {
128:     get
129:   }
130:   public static var maximumPublishableServices: Swift::Int {
131:     get
132:   }
```

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/WiFiAware.framework/Versions/A/Modules/WiFiAware.swiftmodule/arm64e-apple-macos.swiftinterface`

```text
97: @available(iOS 26.0, *)
98: @available(macCatalyst, unavailable)
99: @available(watchOS, unavailable)
100: @available(macOS, unavailable)
101: @available(tvOS, unavailable)
102: @available(visionOS, unavailable)
103: public struct WACapabilities : Swift::Sendable {
104:   public enum Feature : Swift::Sendable, Swift::Hashable, Swift::Equatable, Swift::CaseIterable, Swift::Codable {
105:     case wifiAware
124:   public static var supportedFeatures: Swift::Set<WiFiAware::WACapabilities.WiFiAware::Feature> {
125:     get
126:   }
127:   public static var maximumConnectableDevices: Swift::Int {
128:     get
129:   }
130:   public static var maximumPublishableServices: Swift::Int {
131:     get
132:   }
```

Conclusion: WACapabilities/supportedFeatures are declared for **iOS 26.0+** and explicitly **unavailable on macOS**, Mac Catalyst, watchOS, tvOS and visionOS in these files. The Mac framework's existence is not a callable native-Mac capability API. No Mac runtime feature query ran, and **no empty supportedFeatures set was observed**. The G2 probe must preserve this distinction; see test-plan. Candidate B has both this SDK prerequisite failure and the supplied missing entitlement. Candidate A is independently investigable.

## Network.framework — Verified (local SDK interfaces)

Exact native iOS and Mac declarations below. includePeerToPeer has no member-specific availability annotation; it inherits NWParameters availability (macOS 10.14 / iOS 12.0). NWBrowser is macOS 10.15 / iOS 13.0; NWListener macOS 10.14 / iOS 12.0. All are present; no symbol in this requested set was not found.

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/Network.framework/Modules/Network.swiftmodule/arm64e-apple-ios.swiftinterface`

```text
184: @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
185: final public class NWBrowser : Swift::CustomDebugStringConvertible {
615: @_hasMissingDesignatedInitializers @available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
616: @_objcRuntimeName(_TtC7Network11_NWListener) final public class NWListener : Swift::CustomDebugStringConvertible {
2472: @_hasMissingDesignatedInitializers @available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
2473: @_objcRuntimeName(_TtC7Network13_NWParameters) final public class NWParameters : Swift::CustomDebugStringConvertible {
2548:   final public var includePeerToPeer: Swift::Bool {
2549:     get
2550:     set
2551:   }
```

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Network.framework/Versions/A/Modules/Network.swiftmodule/arm64e-apple-macos.swiftinterface`

```text
184: @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
185: final public class NWBrowser : Swift::CustomDebugStringConvertible {
615: @_hasMissingDesignatedInitializers @available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
616: @_objcRuntimeName(_TtC7Network11_NWListener) final public class NWListener : Swift::CustomDebugStringConvertible {
2474: @_hasMissingDesignatedInitializers @available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
2475: @_objcRuntimeName(_TtC7Network13_NWParameters) final public class NWParameters : Swift::CustomDebugStringConvertible {
2555:   final public var includePeerToPeer: Swift::Bool {
2556:     get
2557:     set
2558:   }
```

Opt-in/API availability does not establish an AP-free route or two-stream throughput. Existing production CastServer does not set includePeerToPeer (architecture.md).

## VideoToolbox — Verified (local SDK headers)

The low-latency rate-control constant is found in **VTCompressionProperties.h**, despite being an encoder **creation specification** key. Set it in VTCompressionSessionCreate's encoderSpecification dictionary; do not assume it is a later session property. Header discussion at :1196–1211 describes optional low-latency H.264 rate control. Availability is macOS 11.3 / iOS 14.5, with other platforms exactly as quoted. Device property support, hardware choice, successful settings and sustained behavior remain unmeasured.

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTCompressionProperties.h`

```text
1212: VT_EXPORT const CFStringRef kVTVideoEncoderSpecification_EnableLowLatencyRateControl API_AVAILABLE(macos(11.3), ios(14.5), tvos(14.5), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/write, CFBoolean, Optional
```

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/VideoToolbox.framework/Versions/A/Headers/VTCompressionProperties.h`

```text
1212: VT_EXPORT const CFStringRef kVTVideoEncoderSpecification_EnableLowLatencyRateControl API_AVAILABLE(macos(11.3), ios(14.5), tvos(14.5), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/write, CFBoolean, Optional
```

For encoder creation and supporting settings, additional iPhoneOS declarations:

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTCompressionSession.h`

```text
142: VTCompressionSessionCreate(
147: 	CM_NULLABLE CFDictionaryRef							encoderSpecification,
152: 	CM_RETURNS_RETAINED_PARAMETER CM_NULLABLE VTCompressionSessionRef * CM_NONNULL compressionSessionOut) API_AVAILABLE(macos(10.8), ios(8.0), tvos(10.2), visionos(1.0)) API_UNAVAILABLE(watchos);
```

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTCompressionProperties.h`

```text
184: VT_EXPORT const CFStringRef kVTCompressionPropertyKey_AllowFrameReordering API_AVAILABLE(macos(10.8), ios(8.0), tvos(10.2), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/Write, CFBoolean, Optional, defaults to true
214: VT_EXPORT const CFStringRef kVTCompressionPropertyKey_AverageBitRate API_AVAILABLE(macos(10.8), ios(8.0), tvos(10.2), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/write, CFNumber<SInt32>, Optional
613: VT_EXPORT const CFStringRef kVTCompressionPropertyKey_RealTime API_AVAILABLE(macos(10.9), ios(8.0), tvos(10.2), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/write, CFBoolean or NULL, Optional, default NULL
659: VT_EXPORT const CFStringRef kVTCompressionPropertyKey_ExpectedFrameRate API_AVAILABLE(macos(10.8), ios(8.0), tvos(10.2), visionos(1.0)) API_UNAVAILABLE(watchos); // Read/write, CFNumber, Optional
811: VT_EXPORT const CFStringRef kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder API_AVAILABLE(macos(10.9), ios(17.4), tvos(17.4), visionos(1.1)) API_UNAVAILABLE(watchos); // CFBoolean, Optional
822: VT_EXPORT const CFStringRef kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder API_AVAILABLE(macos(10.9), ios(17.4), tvos(17.4), visionos(1.1)) API_UNAVAILABLE(watchos); // CFBoolean, Read; assumed false by default
```

## Documented behavior — Apple sources, read 2026-10-16; hardware unverified

These statements were refreshed from Apple's documentation (Markdown fetched read-only after the web reader rejected its content type); no downloadable sample project or signed sample binary was inspected.

| Source URL | Documented statement / remaining test |
| --- | --- |
| [iOS capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) | Requires iOS 27; shared picker present() selects full display, presentForCurrentApplication() limits capture to app content. Screen output uses SCStream. Prove exact screen-only path on A/B. |
| [Background modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes) | screen-capture supports background screen capture/streaming. Sample separately adds audio for microphone. Sufficiency for this no-audio capture/encode/send pipeline is unproven. |
| [includePeerToPeer](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer) | Enables peer-to-peer link technologies for connections/listeners; does not document route exclusivity or throughput guarantees. Prove controlled topology. |
| [supportedFeatures](https://developer.apple.com/documentation/wifiaware/wacapabilities/supportedfeatures) | Unsupported host returns an empty set where API is callable. This does not override local macOS unavailability or supply a Mac runtime result. |

**Documented (brief-carried sources; not independently refreshed at G0):** [TN3179 local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Wi-Fi Aware adoption](https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware), [DTS route selection](https://developer.apple.com/forums/thread/817831), and [persistent capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture). Brief records foreground local-network consent/Bonjour declarations, Aware Publish/Subscribe entitlement array and matching WiFiAwareServices, route-selection limits, and restricted persistent-capture scope. Treat these as documentation leads until refreshed for implementation; none proves provisioning or runtime behavior here. Do not assume persistent-content-capture is required for manually consented iOS capture.

## Free Personal Team consequences

**Verified (task input):** only Personal Team is available; no Wi-Fi Aware entitlement and no TestFlight. No signing profile, keychain identity or capability permission was inspected or created in G0.

**Documented (Apple, read 2026-10-16):** [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) allows Xcode testing on personal devices but requires periodic reprovisioning. It lists up to ten App IDs, three registered devices, three installed apps per device, and seven-day expirations for IDs/devices/profiles. Record actual Xcode quota/profile expiry and reinstall before expiry. Paid program membership enables advanced capabilities/distribution; development install is not TestFlight/App Store approval.

**Hypothesis / consequences for experiments:** two phones fit the stated registration ceiling only if quota is available. Provision both beforehand; keep one sender target with experiment modes to conserve app slots. Xcode/account setup may need internet even though decisive runtime tests must be offline. B remaining signed out is a runtime requirement to test, not a provisioning result already achieved. Do not promise screen-only background capability acceptance until the signed app installs and runs on both phones. Missing Wi-Fi Aware entitlement prevents assuming a usable Aware sender even if iOS features are present; do not add it blindly. Network.framework/Bonjour Candidate A merits an ordinary local-network-permission experiment, without claiming its signing configuration has passed.

## Hypotheses and current limits

- Full-display screen-only SCStream → hardware H.264 → background send may work with Personal Team. Only declarations/documentation support trying it; G1/G3 must prove stages separately.
- Bonjour + peer-to-peer-enabled Network.framework may sustain two authenticated offline sessions. G2 tests this; no LAN or single-phone result substitutes for the required topology/concurrency.
- Future native Mac Aware callability must be rechecked against a changed public SDK. An interface named nan0 or the presence of a framework cannot establish support.
- Mac prototype minimum OS, phone models/builds, supported encoder properties, effective radio path, Bluetooth dependency, hardware CPU budget, identity provisioning and distribution remain decisions or measurements, not G0 successes.

Root build/test baseline is sandbox-blocked; exact result is in [results](results.md). No workaround was attempted and no product defect was inferred from that failure.


## Rotation signal

**Verified (existing device evidence):** [Run 3](results.md) kept 588×1280 buffers
through two rotations. [Run 9](results.md) logged `orientation=1` for every frame
and landscape apps appeared sideways within the portrait panel frame. Those
fields do not identify the app's display rotation. This change adds no device run.

**Verified (local SDK inspection):** installed iPhoneOS 27.1 `SCStream.h` declares
`SCStreamFrameInfo.videoOrientation` as CGImagePropertyOrientation (1…8). No separate
rotation/content-transform key is declared among its frame-info keys. CoreMedia's
`CMAttachment.h` permits `CMGetAttachment` on an image buffer; CoreVideo's
`CVBufferCopyAttachments` enumerates both propagation modes. Header availability
and names do not establish what a real iOS capture emits.

**Verified (implementation):** the new `capture.rotationAttachments` event probes
the first screen callback of each capture, then compares current metadata at most
once per second and emits only changes. It includes the entire sample attachments
array, every present SCStreamFrameInfo key (including unknown keys), sample and
image-buffer CM attachment keys/values obtained via `CMGetAttachment`, both
CVBuffer attachment dictionaries and delivered dimensions. Ordering is stable for
comparison. Binary attachment metadata is represented by byte count and base64;
opaque media references by type, never a buffer description or pixel contents.
No image buffer bytes are read or logged.
A changing display timestamp can itself cause one event per second.

**Verified (implementation):** sender begins UIDevice orientation notifications,
logs each notification's raw/planar value, app background/capture state, and a
per-capture background-notification count at capture end. Portrait=0,
landscapeLeft=90, upside-down=180, landscapeRight=270 clockwise; unknown/face-up/
face-down retain the latest usable physical orientation. A `device` hint is sent
at capture start if available and updated on notifications. No CoreMotion
permission or background mode was added. Receiver Auto-rotate defaults off and
manual rotation always remains available.

**Hypothesis / unresolved:** another runtime attachment may expose app/display
rotation despite constant panel dimensions/videoOrientation. No new attachment
trace is available here, so no newly usable capture key or `capture` hint producer
is claimed. Do not reinterpret the observed constant `videoOrientation=1` as a
working rotation signal. If a runtime key is found, verify its semantics against
asymmetric content in all four rotations and carry its additional presentation
rotation with `orientationSource=capture`; the bounded v3 message and receiver
preference already support it.

**Hypothesis / unresolved:** UIDevice notifications may stop or lag while the
sender is backgrounded, and physical orientation can differ from an orientation-
locked app. Repeat portrait/landscape/upside-down while another app is foreground,
then inspect `capture.deviceOrientation` and `capture.orientationNotificationSummary`.
A zero count alone does not prove OS suppression. Device testing must also check
clockwise mapping, layer letterboxing, one centered window resize, keyboard and
toolbar actions, per-device persistence/reconnect, and uninterrupted decode during
manual/auto changes. Shared policy/TLS tests and SDK typechecks do not establish
these physical-device behaviors.

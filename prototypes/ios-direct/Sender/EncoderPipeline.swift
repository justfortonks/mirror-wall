import Foundation
import ScreenCaptureKit
import VideoToolbox
import IOSDirectShared

/// Capture queue calls offer(). A two-entry mailbox feeds one encode worker.
/// Encoder state and completion handling belong exclusively to encodeQueue.
final class EncoderPipeline {
    private struct Frame {
        let image: CVPixelBuffer
        let pts: CMTime
        let orientation: UInt32
        let screenSize: CGSize?
    }
    private struct Format: Equatable {
        let sourceWidth: Int
        let sourceHeight: Int
        let pixelFormat: OSType
        let orientation: UInt32
        let screenSize: CGSize?
        let output: Dimensions
    }
    private let mailboxLock = NSLock()
    private var frames: [Frame] = []
    private var workerScheduled = false
    private var accepting = false
    private var pacer = FramePacer()
    private let encodeQueue = DispatchQueue(label: "iosdirect.encode", qos: .userInitiated)
    private var transfer: VTPixelTransferSession?
    private var backoff = EncoderBackoff()
    private var session: VTCompressionSession?
    private var format: Format?
    private var generation = 0
    private var inFlight = 0 // Also bounds asynchronous VT callbacks waiting on encodeQueue.
    private var forceIDR = true
    private let metrics: Telemetry
    private let log: RunLog
    private let sink: StubSink
    init(metrics: Telemetry, log: RunLog) {
        self.metrics = metrics; self.log = log; sink = StubSink(metrics: metrics)
        sink.requestIDR = { [weak self] in self?.encodeQueue.async { [weak self] in self?.forceIDR = true } }
    }
    func start() {
        stop()
        encodeQueue.sync { setEncoderState("unavailable: awaiting frame") }
        mailboxLock.lock(); accepting = true; pacer = FramePacer(); mailboxLock.unlock()
    }
    func stop() {
        mailboxLock.lock(); accepting = false; frames.removeAll(); mailboxLock.unlock()
        encodeQueue.sync {
            invalidate(); format = nil; backoff.reset()
            setEncoderState("unavailable: stopped")
            metrics.update { $0.encoderRetryAfter = 0 }
        }
    }
    func resetCounters() {
        // Keep totals/hash aligned with a reset event without restarting capture.
        encodeQueue.sync { sink.resetHash(); metrics.reset() }
    }
    func sampleSink() { sink.sampleQueue() }
    func offer(_ sample: CMSampleBuffer) {
        metrics.update { $0.captureCallbacks += 1 }
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? NSNumber, status.intValue == SCFrameStatus.complete.rawValue,
              let image = sample.imageBuffer else { return }
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, pts.seconds.isFinite else { return }
        metrics.update { $0.validFrames += 1; $0.latestPTS = pts.seconds }
        let orientation = (info[.videoOrientation] as? NSNumber)?.uint32Value ?? 1
        let screenRect = Self.rect(info[.screenRect])
        let contentRect = Self.rect(info[.contentRect])
        metrics.update {
            $0.sourceDimensions = Dimensions(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            $0.sourcePixelFormat = CVPixelBufferGetPixelFormatType(image); $0.frameOrientation = orientation
            $0.frameScreenRect = screenRect.map { String(describing: $0) }
            $0.frameContentRect = contentRect.map { String(describing: $0) }
            $0.frameScaleFactor = (info[.scaleFactor] as? NSNumber)?.doubleValue
            $0.frameContentScale = (info[.contentScale] as? NSNumber)?.doubleValue
        }
        mailboxLock.lock(); defer { mailboxLock.unlock() }
        guard accepting else { return }
        guard pacer.accept(pts: pts.seconds) else { metrics.update { $0.pacingDrops += 1 }; return }
        metrics.update { $0.pacedFrames += 1 }
        guard frames.count < 2 else { metrics.update { $0.sourceDrops += 1 }; return }
        frames.append(Frame(image: image, pts: pts, orientation: orientation, screenSize: screenRect?.size))
        scheduleWorker()
    }
    private static func rect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        if let dictionary = value as? [String: Any] { return CGRect(dictionaryRepresentation: dictionary as CFDictionary) }
        return nil
    }
    private func scheduleWorker() { // mailboxLock held
        guard !workerScheduled else { return }
        workerScheduled = true
        encodeQueue.async { self.workOne() }
    }
    private func workOne() {
        mailboxLock.lock()
        guard accepting, !frames.isEmpty else { workerScheduled = false; mailboxLock.unlock(); return }
        let frame = frames.removeFirst()
        mailboxLock.unlock()
        autoreleasepool { encode(frame) }
        mailboxLock.lock()
        workerScheduled = false
        if accepting && !frames.isEmpty { scheduleWorker() }
        mailboxLock.unlock()
    }
    private func invalidate() { // encodeQueue only; obsolete callbacks cannot affect the new session.
        generation += 1
        if let session { VTCompressionSessionInvalidate(session) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        session = nil; transfer = nil; inFlight = 0; forceIDR = true
        metrics.update { $0.generation = generation }
        sink.begin(generation: generation)
    }
    private func setEncoderState(_ value: String) {
        metrics.update { $0.encoderState = value }
        log.event("encoder.state", "\(value) generation=\(generation) appState=\(metrics.snapshot().appState)")
    }
    private func fail(_ message: String, status: OSStatus? = nil, unavailable: Bool = false) {
        metrics.update {
            $0.encodeErrors += 1
            if let status, status != noErr { $0.encoderLastFailingOSStatus = status }
        }
        log.event("encoder.error", "\(message) OSStatus=\(status.map { String($0) } ?? "none") generation=\(generation) appState=\(metrics.snapshot().appState)")
        invalidate()
        let delay = backoff.failed(now: uptime())
        metrics.update { $0.encoderRetryAfter = backoff.retryAfter }
        let reason = status.flatMap { $0 == noErr ? nil : String($0) } ?? message
        setEncoderState(unavailable ? "unavailable: \(reason)" : "invalidated")
        log.event("encoder.backoff", "delay=\(delay) retryAfter=\(backoff.retryAfter) appState=\(metrics.snapshot().appState)")
    }
    private func dropWithoutSession() { metrics.update { $0.encoderNoSessionDrops += 1 } }
    private func configure(_ next: Format) -> Bool {
        invalidate()
        setEncoderState("recreating")
        metrics.update { $0.encoderRecreateAttempts += 1 }
        log.event("encoder.recreateAttempt", "attempt=\(metrics.snapshot().encoderRecreateAttempts) generation=\(generation) appState=\(metrics.snapshot().appState)")
        var created: VTCompressionSession?
        let direct = next.sourceWidth == next.output.width && next.sourceHeight == next.output.height
        let bufferFormat = direct ? next.pixelFormat : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: bufferFormat,
            kCVPixelBufferWidthKey: next.output.width, kCVPixelBufferHeightKey: next.output.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(next.output.width),
            height: Int32(next.output.height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        log.event("encoder.create", "generation=\(generation) dims=\(next.output) source=\(next.sourceWidth)x\(next.sourceHeight) orientation=\(next.orientation) lowLatency=true appState=\(metrics.snapshot().appState) OSStatus=\(status)")
        // Retain even a partial result so failure always invalidates/releases it.
        session = created
        guard status == noErr, let created else { fail("create", status: status, unavailable: true); return false }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, 6_000_000 as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(created, key: key, value: value)
            log.event("encoder.property", "\(key)=\(value) OSStatus=\(result)")
            if result != noErr { fail("property \(key)", status: result, unavailable: true); return false }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
        log.event("encoder.prepare", "OSStatus=\(prepared)")
        guard prepared == noErr else { fail("prepare", status: prepared, unavailable: true); return false }
        var hardware: CFTypeRef?
        let hwStatus = withUnsafeMutablePointer(to: &hardware) {
            VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0)
        }
        var profile: CFTypeRef?
        let profileStatus = withUnsafeMutablePointer(to: &profile) {
            VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, allocator: nil, valueOut: $0)
        }
        log.event("encoder.readback", "hardware OSStatus=\(hwStatus) value=\(String(describing: hardware)); profile OSStatus=\(profileStatus) value=\(String(describing: profile))")
        metrics.update {
            $0.generation = generation; $0.dimensions = next.output
            if hwStatus == kVTPropertyNotSupportedErr { $0.hardwareEncoder = "unknown (not supported)" }
            else if hwStatus == noErr, let value = hardware as? Bool { $0.hardwareEncoder = value ? "yes" : "no" }
            else { $0.hardwareEncoder = "unknown (OSStatus=\(hwStatus))" }
            $0.negotiatedProfile = profileStatus == noErr ? profile.map { String(describing: $0) } : nil
        }
        metrics.update { $0.encoderRecreateSuccesses += 1 }
        setEncoderState("ok")
        log.event("encoder.recreateSuccess", "generation=\(generation) appState=\(metrics.snapshot().appState)")
        // Reset backoff only when output arrives: create can succeed while encode is forbidden.
        return true
    }
    private func encode(_ frame: Frame) {
        let width = CVPixelBufferGetWidth(frame.image), height = CVPixelBufferGetHeight(frame.image)
        guard let dimensions = Dimensions.fit(width: width, height: height) else {
            if backoff.canAttempt(now: uptime()) { fail("invalid source dimensions") }
            dropWithoutSession(); return
        }
        let next = Format(sourceWidth: width, sourceHeight: height,
                          pixelFormat: CVPixelBufferGetPixelFormatType(frame.image),
                          orientation: frame.orientation, screenSize: frame.screenSize, output: dimensions)
        if format != next {
            log.event("capture.frameFormat", "source=\(width)x\(height) pixelFormat=\(next.pixelFormat) orientation=\(frame.orientation) screenSize=\(String(describing: frame.screenSize)) output=\(dimensions) appState=\(metrics.snapshot().appState)")
            // iOS 27.1 explicitly marks SCStream.updateConfiguration unavailable. Keep capture
            // running and fit the delivered buffers; never rotate pixels or restart the stream.
            log.event("stream.reconfigurationUnavailable", "iOS 27.1: updateConfiguration unavailable; encoder generation follows delivered size/orientation")
            invalidate(); format = next
        }
        if session == nil {
            guard backoff.canAttempt(now: uptime()) else { dropWithoutSession(); return }
            guard configure(next) else { dropWithoutSession(); return }
        }
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            // A nil pool has no returned OSStatus; do not fabricate -12903 in telemetry.
            fail("missing pixel buffer pool"); dropWithoutSession(); return
        }
        guard inFlight < 2 else { metrics.update { $0.sourceDrops += 1 }; return }
        let buffer: CVPixelBuffer
        if width == dimensions.width && height == dimensions.height {
            buffer = frame.image // SCK IOSurface goes straight to VT, with its color attachments.
        } else {
            var converted: CVPixelBuffer?
            let allocated = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &converted)
            guard allocated == kCVReturnSuccess, let converted else {
                metrics.update { $0.sourceDrops += 1 }; log.event("encoder.pool", "CVReturn=\(allocated)"); return
            }
            if transfer == nil {
                let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
                log.event("encoder.transferCreate", "OSStatus=\(status) appState=\(metrics.snapshot().appState)")
                guard status == noErr, let transfer else {
                    fail("pixel transfer create", status: status); dropWithoutSession(); return
                }
                let properties: [(CFString, CFTypeRef)] = [
                    (kVTPixelTransferPropertyKey_RealTime, kCFBooleanTrue),
                    (kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox)
                ]
                for (key, value) in properties {
                    let result = VTSessionSetProperty(transfer, key: key, value: value)
                    log.event("encoder.transferProperty", "\(key)=\(value) OSStatus=\(result)")
                    guard result == noErr else {
                        fail("pixel transfer property \(key)", status: result); dropWithoutSession(); return
                    }
                }
            }
            guard let transfer else { return }
            let status = VTPixelTransferSessionTransferImage(transfer, from: frame.image, to: converted)
            guard status == noErr else { fail("pixel transfer", status: status); dropWithoutSession(); return }
            buffer = converted
        }
        let token = generation
        let properties = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceIDR = false; inFlight += 1
        metrics.update { $0.encodeSubmitted += 1 }
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: frame.pts, duration: CMTime(value: 1, timescale: 30),
            frameProperties: properties, infoFlagsOut: nil, outputHandler: { [weak self] status, flags, sample in
                guard let self else { return }
                self.encodeQueue.async { self.completed(token: token, status: status, flags: flags, sample: sample) }
            })
        if status != noErr { fail("submit", status: status) }
    }
    private func completed(token: Int, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard token == generation else { return }
        inFlight -= 1
        guard status == noErr else {
            log.event("encoder.completion", "OSStatus=\(status) flags=\(flags.rawValue)")
            fail("completion", status: status); return
        }
        guard !flags.contains(.frameDropped), let sample, sample.isValid,
              CMSampleBufferDataIsReady(sample), let block = sample.dataBuffer else {
            log.event("encoder.completion", "OSStatus=\(status) flags=\(flags.rawValue) missing/invalid=\(sample == nil)")
            fail("completion missing/invalid/dropped output"); return
        }
        backoff.reset()
        metrics.update { $0.encoderRetryAfter = 0 }
        let size = CMBlockBufferGetDataLength(block)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        metrics.update { $0.encodeCompleted += 1; $0.encodeBytes += size; if keyframe { $0.keyframes += 1 } }
        if keyframe, let description = sample.formatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let extensions = CMFormatDescriptionGetExtensions(description)
            let atoms = (extensions as NSDictionary?)?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any]
            let avc = atoms?["avcC"] as? Data
            let profile = avc.flatMap { $0.count > 3 ? "avcC profile=\($0[1]) level=\($0[3])" : nil } ?? "avcC unavailable"
            metrics.update { $0.negotiatedProfile = profile }
            log.event("encoder.outputFormat", "generation=\(token) dims=\(dimensions.width)x\(dimensions.height) \(profile)")
        }
        // Reject overlarge output before copying. The sink accounts for the drop and requests IDR.
        guard size > 0, size <= 1_048_576 else {
            metrics.update { $0.sinkDrops += 1 }; forceIDR = true; log.event("sink.oversize", "bytes=\(size)"); return
        }
        var data = Data(count: size)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
        guard copied == kCMBlockBufferNoErr else { fail("copy", status: copied); return }
        sink.enqueue(data, pts: sample.presentationTimeStamp.seconds, generation: token)
    }
}

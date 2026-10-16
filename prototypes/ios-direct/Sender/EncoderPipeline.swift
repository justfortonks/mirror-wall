import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreImage
import ImageIO
import IOSDirectShared

/// Capture queue calls offer(). A two-entry mailbox feeds one encode worker.
/// Encoder state and completion handling belong exclusively to encodeQueue.
final class EncoderPipeline {
    private struct Frame {
        let image: CVPixelBuffer
        let pts: CMTime
        let orientation: UInt32
    }
    private struct Format: Equatable { let sourceWidth: Int; let sourceHeight: Int; let orientation: UInt32; let output: Dimensions }
    private let mailboxLock = NSLock()
    private var frames: [Frame] = []
    private var workerScheduled = false
    private var accepting = false
    private var pacer = FramePacer()
    private let encodeQueue = DispatchQueue(label: "iosdirect.encode", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var session: VTCompressionSession?
    private var format: Format?
    private var generation = 0
    private var inFlight = 0 // Also bounds asynchronous VT callbacks waiting on encodeQueue.
    private var forceIDR = true
    private let metrics: Telemetry
    private let log: RunLog
    private let sink: StubSink
    var onFailure: ((String) -> Void)?
    init(metrics: Telemetry, log: RunLog) {
        self.metrics = metrics; self.log = log; sink = StubSink(metrics: metrics)
        sink.requestIDR = { [weak self] in self?.encodeQueue.async { [weak self] in self?.forceIDR = true } }
    }
    func start() {
        stop()
        mailboxLock.lock(); accepting = true; pacer = FramePacer(); mailboxLock.unlock()
    }
    func stop() {
        mailboxLock.lock(); accepting = false; frames.removeAll(); mailboxLock.unlock()
        encodeQueue.sync { invalidate() }
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
        mailboxLock.lock(); defer { mailboxLock.unlock() }
        guard accepting else { return }
        guard pacer.accept(pts: pts.seconds) else { metrics.update { $0.pacingDrops += 1 }; return }
        metrics.update { $0.pacedFrames += 1 }
        guard frames.count < 2 else { metrics.update { $0.sourceDrops += 1 }; return }
        frames.append(Frame(image: image, pts: pts, orientation: orientation))
        scheduleWorker()
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
    private func invalidate() {
        generation += 1
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; format = nil; inFlight = 0; forceIDR = true
        sink.begin(generation: generation)
    }
    private func fail(_ message: String) {
        metrics.update { $0.encodeErrors += 1 }
        log.event("encoder.error", message)
        mailboxLock.lock(); accepting = false; frames.removeAll(); mailboxLock.unlock()
        invalidate()
        onFailure?(message)
    }
    private func configure(_ next: Format) -> Bool {
        invalidate()
        var created: VTCompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: next.output.width, kCVPixelBufferHeightKey: next.output.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(next.output.width),
            height: Int32(next.output.height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        log.event("encoder.create", "generation=\(generation) dims=\(next.output) source=\(next.sourceWidth)x\(next.sourceHeight) orientation=\(next.orientation) lowLatency=true OSStatus=\(status)")
        guard status == noErr, let created else { fail("create OSStatus=\(status)"); return false }
        session = created; format = next
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
            if result != noErr { fail("property \(key) OSStatus=\(result)"); return false }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
        log.event("encoder.prepare", "OSStatus=\(prepared)")
        guard prepared == noErr else { fail("prepare OSStatus=\(prepared)"); return false }
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
            $0.hardwareEncoder = hwStatus == noErr ? (hardware as? Bool) : nil
            $0.negotiatedProfile = profileStatus == noErr ? profile.map { String(describing: $0) } : nil
        }
        return true
    }
    private func encode(_ frame: Frame) {
        let image = CIImage(cvPixelBuffer: frame.image).oriented(forExifOrientation: Int32(frame.orientation))
        let extent = image.extent
        guard let dimensions = Dimensions.fit(width: Int(extent.width), height: Int(extent.height)) else {
            fail("invalid source dimensions"); return
        }
        let next = Format(sourceWidth: CVPixelBufferGetWidth(frame.image), sourceHeight: CVPixelBufferGetHeight(frame.image),
                          orientation: frame.orientation, output: dimensions)
        if format != next, !configure(next) { return }
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { fail("missing pixel buffer pool"); return }
        guard inFlight < 2 else { metrics.update { $0.sourceDrops += 1 }; return }
        var buffer: CVPixelBuffer?
        let allocated = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &buffer)
        guard allocated == kCVReturnSuccess, let buffer else {
            metrics.update { $0.sourceDrops += 1 }; log.event("encoder.pool", "CVReturn=\(allocated)"); return
        }
        // Orientation baked into pixels; preserve source PTS. SDR 709 output is explicit.
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: Double(dimensions.width) / extent.width,
                                                                 y: Double(dimensions.height) / extent.height))
        context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height), colorSpace: colorSpace)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
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
        if status != noErr { fail("submit OSStatus=\(status)") }
    }
    private func completed(token: Int, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard token == generation else { return }
        inFlight -= 1
        guard status == noErr, !flags.contains(.frameDropped), let sample, sample.isValid,
              CMSampleBufferDataIsReady(sample), let block = sample.dataBuffer else {
            metrics.update { $0.encodeErrors += 1 }
            log.event("encoder.completion", "OSStatus=\(status) flags=\(flags.rawValue) missing/invalid=\(sample == nil)")
            forceIDR = true; return
        }
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
        guard copied == kCMBlockBufferNoErr else { fail("copy OSStatus=\(copied)"); return }
        sink.enqueue(data, pts: sample.presentationTimeStamp.seconds, generation: token)
    }
}

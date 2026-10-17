import Foundation
import AVFoundation
import VideoToolbox
import IOSDirectShared

struct VideoReceiveSnapshot: Codable {
    var kind = "video.receiver.metrics"
    var session: UUID
    var monotonicNs: UInt64 = 0
    var state = "waiting for config"
    var generation: UInt32?
    var width = 0, height = 0, orientation: UInt8 = 1
    var captureOrientationHint: OrientationHint?, deviceOrientationHint: OrientationHint?
    var contentRect: VideoRect?
    var received = 0, decoded = 0, displayed = 0, decodeErrors = 0, displayDrops = 0, dropped = 0
    var displaySkipped = 0
    var recoveries: [String: Int] = [:]
    var decodeQueueDepth = 0 // Maximum since the preceding metrics line.
    var decodeQueueDepthCurrent = 0
    var presentationMode = "immediate"
    var keyframeRequests = 0, frameBytes = 0, receivedBytes = 0
    var receivedFPS: Double = 0, decodedFPS: Double = 0, displayedFPS: Double = 0, receivedMbit: Double = 0
    var interArrivalP50MS: Double?, interArrivalP95MS: Double?, longestGapMS: Double = 0
    var timing: VideoStageSnapshot?
    var thermal = "unknown", residentMemoryMB: Double?
}

/// One session owns decode, playout and counters. All compressed units are decoded
/// within the eight-frame / 300 ms bound. Only decoded presentation may coalesce.
/// Recovery preserves the last image; disconnect deliberately clears it to black.
final class VideoSessionRenderer: RadioVideoConsumer {
    let layer = AVSampleBufferDisplayLayer()
    private let queue: DispatchQueue
    private let log: RadioLog?
    private let request: (String) -> Void
    var onSample: ((VideoReceiveSnapshot) -> Void)?
    private var stats: VideoReceiveSnapshot
    private var configuration = VideoConfigurationState()
    private var config: VideoConfig? { configuration.current }
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var epoch = 0
    private var closed = false
    private struct Pending {
        let completion: (VideoDecodeStatus) -> Void
        let arrival: Double
        let submitted: Double
        let ptsNs: UInt64
    }
    private var pending: [UInt64: Pending] = [:]
    private var decodeQueue = VideoDecodeQueuePolicy()
    private struct Picture { let image: CVImageBuffer; let completed: Double }
    private var pictures = VideoPresentationQueue<Picture>()
    private var diagnostics = VideoStageDiagnostics()
    private var publication = VideoPublicationGate()
    private var publishWork: DispatchWorkItem?
    private var wake: DispatchWorkItem?
    private var wakeAt: Double?
    private var wakeToken = 0
    private var lastRequest: UInt64 = 0
    private var lastArrival: UInt64?
    private var lastDisplay: UInt64?
    private var sampledAt: UInt64
    private var displayedRate: VideoFrameRate
    private var previous = (received: 0, decoded: 0, bytes: 0)
    init(session: UUID, log: RadioLog?, request: @escaping (String) -> Void) {
        queue = DispatchQueue(label: "iosdirect.video.decode.\(session)", qos: .userInteractive)
        stats = VideoReceiveSnapshot(session: session); self.log = log; self.request = request
        let now = radioNow(); sampledAt = now; displayedRate = VideoFrameRate(now: Double(now) / 1e9)
        layer.videoGravity = .resizeAspect; layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        log?.event("video.presentationMode", "session=\(session) mode=immediate")
    }
    func orientationHint(_ hint: OrientationHint) {
        queue.sync {
            guard !closed else { return }
            // Metadata publication only; never reset VT, flush the layer or touch pictures.
            let old = hint.source == .capture ? stats.captureOrientationHint : stats.deviceOrientationHint
            guard old == nil || hint.monotonicNs > old!.monotonicNs else { return }
            if hint.source == .capture { stats.captureOrientationHint = hint }
            else { stats.deviceOrientationHint = hint }
            log?.event("video.orientationHint", "session=\(stats.session) degrees=\(hint.degrees) orientationSource=\(hint.source) senderMonotonicNs=\(hint.monotonicNs)")
            publishSnapshot()
        }
    }
    func configure(_ config: VideoConfig) throws {
        try queue.sync {
            guard !closed else { return }
            if try configuration.update(config) == .identical {
                // Decoder lifetime is independent of config lifetime. Recovery may
                // recreate VT here without another reset, image flush or config event.
                if decoder == nil { _ = createDecoder() }
                return
            }
            resetDecoder(); format = nil
            stats.generation = config.generation; stats.width = Int(config.width); stats.height = Int(config.height)
            stats.orientation = config.orientation; stats.contentRect = config.contentRect
            stats.state = "waiting for keyframe"
            let sets = try config.parameterSets(), joined = sets.reduce(into: Data()) { $0.append($1) }
            var description: CMFormatDescription?
            let result = joined.withUnsafeBytes { raw -> OSStatus in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                var offset = 0, pointers = [UnsafePointer<UInt8>]()
                for set in sets { pointers.append(base + offset); offset += set.count }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
            guard result == noErr, let description else { decodeFailure("format OSStatus=\(result)"); return }
            let size = CMVideoFormatDescriptionGetDimensions(description)
            guard size.width == Int32(config.width), size.height == Int32(config.height) else {
                throw RadioError.protocolViolation("config dimensions differ from SPS")
            }
            format = description; _ = createDecoder()
            publishSnapshot()
            log?.event("video.config", "session=\(stats.session) generation=\(config.generation) pixels=\(size.width)x\(size.height) orientation=\(config.orientation) contentRect=\(String(describing: config.contentRect)); raw pixels retained; layer applies CGImagePropertyOrientation")
        }
    }
    @discardableResult private func createDecoder() -> Bool {
        guard let format else { return false }
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &decoder)
        guard status == noErr, let decoder else { decodeFailure("decoder create OSStatus=\(status)"); return false }
        let realTime = VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        log?.event("video.decoder", "session=\(stats.session) create=\(status) realTime=\(realTime)")
        return true
    }
    func receive(_ frame: VideoAccessUnit, completion: @escaping (VideoDecodeStatus) -> Void) {
        receive(frame, arrivalNs: radioNow(), completion: completion)
    }
    func receive(_ frame: VideoAccessUnit, arrivalNs: UInt64, completion: @escaping (VideoDecodeStatus) -> Void) {
        queue.sync {
            guard !closed else { completion(.dropped); return }
            let ns = arrivalNs, now = Double(radioNow()) / 1e9, arrival = Double(arrivalNs) / 1e9
            diagnostics.arrived(at: arrival)
            stats.received += 1; stats.receivedBytes += frame.data.count; stats.frameBytes = frame.data.count
            if let lastArrival {
                let gap = Double(ns - lastArrival) / 1e6
                stats.longestGapMS = max(stats.longestGapMS, gap)
            }
            lastArrival = ns
            if let reason = decodeQueue.expire(now: now) { recover(reason) }
            guard config?.generation == frame.generation, let format else {
                stats.dropped += 1; completion(.dropped); recover("missing config / generation mismatch"); return
            }
            switch decodeQueue.admit(seq: frame.seq, keyframe: frame.keyframe, now: now) {
            case .waitForKeyframe:
                stats.dropped += 1; completion(.dropped); return
            case .recover(let reason):
                stats.dropped += 1; completion(.dropped); recover(reason); return
            case .decode: break
            }
            if decoder == nil, !createDecoder() {
                stats.dropped += 1; completion(.decodeError); return
            }
            guard let decoder, let sample = Self.compressedSample(frame.data, format: format) else {
                completion(.decodeError); decodeFailure("missing decoder / sample creation"); return
            }
            let token = epoch, seq = frame.seq
            let submitted = Double(radioNow()) / 1e9
            diagnostics.submitted(arrival: arrival, at: submitted)
            pending[seq] = Pending(completion: completion, arrival: arrival, submitted: submitted, ptsNs: frame.ptsNs)
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                    let completedAt = Double(radioNow()) / 1e9
                    self?.queue.async { [weak self] in self?.completed(seq: seq, epoch: token, status: status, image: image, completedAt: completedAt) }
                }
            // VT guarantees no output handler when submission fails.
            if status != noErr {
                pending.removeValue(forKey: seq)?.completion(.decodeError)
                decodeFailure("decode submit OSStatus=\(status)")
            }
            scheduleService()
        }
    }
    private func completed(seq: UInt64, epoch: Int, status: OSStatus, image: CVImageBuffer?, completedAt: Double) {
        guard !closed, epoch == self.epoch, let item = pending.removeValue(forKey: seq) else { return }
        diagnostics.completed(submitted: item.submitted, at: completedAt)
        decodeQueue.complete(seq: seq)
        guard status == noErr, let image else {
            item.completion(.decodeError); decodeFailure("decode output OSStatus=\(status) image=\(image != nil)"); return
        }
        stats.decoded += 1
        let now = Double(radioNow()) / 1e9
        stats.displaySkipped += pictures.offer(Picture(image: image, completed: completedAt), seq: seq, ptsNs: item.ptsNs, arrival: item.arrival, now: now)
        // Every successful decode gets an ACK, including images superseded for display.
        item.completion(.decoded); scheduleService()
    }
    private func cancelService() {
        wakeToken += 1; wake?.cancel(); wake = nil; wakeAt = nil
    }
    private func scheduleService() {
        guard !closed else { return }
        let now = Double(radioNow()) / 1e9
        guard let next = VideoServiceSchedule.next(now: now, decodeDeadline: decodeQueue.deadline, pictureDue: pictures.nextDue) else { cancelService(); return }
        if let wakeAt, wakeAt <= next { return }
        cancelService(); wakeAt = next; let token = wakeToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed, self.wakeToken == token else { return }
            self.wake = nil; self.wakeAt = nil; self.service()
        }
        wake = work
        if next <= now { queue.async(execute: work) }
        else { queue.asyncAfter(deadline: .now() + (next - now), execute: work) }
    }
    private func service() {
        let now = Double(radioNow()) / 1e9
        if let reason = decodeQueue.expire(now: now) { recover(reason) }
        displayReady(now: now); scheduleService()
    }
    private func displayReady(now: Double) {
        let ready = pictures.takeReady(now: now); stats.displaySkipped += ready.skipped
        guard let picture = ready.value else { return }
        if present(picture.image) {
            diagnostics.enqueued(completed: picture.completed, at: Double(radioNow()) / 1e9)
            stats.displayed += 1; lastDisplay = radioNow(); stats.state = "streaming" }
        else { stats.displayDrops += 1 }
    }
    func setSmoothing(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.pictures.smooth != enabled else { return }
            self.stats.displaySkipped += self.pictures.setSmoothing(enabled)
            self.stats.presentationMode = enabled ? "smooth100ms" : "immediate"
            self.log?.event("video.presentationMode", "session=\(self.stats.session) mode=\(self.stats.presentationMode)")
            self.publishSnapshot(); self.scheduleService()
        }
    }
    private func present(_ image: CVImageBuffer) -> Bool {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                          formatDescriptionOut: &format) == noErr, let format else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return false }
        layer.enqueue(sample) // This is the displayed-frame counter boundary; no scanout claim.
        return true
    }
    private func askForIDR(_ reason: String) {
        let now = radioNow()
        guard now - lastRequest >= 250_000_000 else { return }
        lastRequest = now; stats.keyframeRequests += 1; request(reason)
    }
    private func resetDecoder(removeImage: Bool = false) {
        epoch += 1; cancelService()
        if let decoder { VTDecompressionSessionInvalidate(decoder) }; decoder = nil
        let old = pending; pending.removeAll(); stats.dropped += old.count
        decodeQueue.reset(); stats.displaySkipped += pictures.clear()
        for item in old.values { item.completion(.dropped) }
        if removeImage { layer.flushAndRemoveImage() }
        else { layer.flush() } // Keep the last displayed picture throughout recovery.
    }
    private func recover(_ reason: String) {
        stats.recoveries[reason, default: 0] += 1
        log?.event("video.recovery", "session=\(stats.session) reason=\(reason) depth=\(pending.count)")
        resetDecoder(); stats.state = config == nil ? "waiting for config" : "stalled"; askForIDR(reason)
    }
    private func decodeFailure(_ reason: String) {
        stats.decodeErrors += 1
        log?.event("video.decodeError", "session=\(stats.session) \(reason)"); recover(reason)
    }
    func discontinuity(_ reason: String) { queue.sync { if !closed { stats.dropped += 1; recover(reason) } } }
    func tick() { queue.sync { service(); sample() } }
    private func sample() {
        let now = radioNow(), seconds = Double(now - sampledAt) / 1e9
        if !closed, let lastDisplay, now - lastDisplay > 1_000_000_000 { stats.state = "stalled" }
        if let lastArrival { stats.longestGapMS = max(stats.longestGapMS, Double(now - lastArrival) / 1e6) }
        let timing = diagnostics.snapshot(now: Double(now) / 1e9)
        stats.timing = timing
        stats.interArrivalP50MS = timing.interArrival.p50MS; stats.interArrivalP95MS = timing.interArrival.p95MS
        if seconds > 0 {
            stats.receivedFPS = Double(stats.received - previous.received) / seconds
            stats.decodedFPS = Double(stats.decoded - previous.decoded) / seconds
            stats.receivedMbit = Double(stats.receivedBytes - previous.bytes) * 8 / seconds / 1e6
        }
        stats.displayedFPS = displayedRate.sample(total: stats.displayed, now: Double(now) / 1e9)
        stats.decodeQueueDepth = decodeQueue.samplePeakDepth(); stats.decodeQueueDepthCurrent = decodeQueue.depth
        previous = (stats.received, stats.decoded, stats.receivedBytes); sampledAt = now
        stats.monotonicNs = now; stats.thermal = radioThermalState(); stats.residentMemoryMB = radioMemoryMB()
        log?.write(stats); publishSnapshot()
    }
    private func publishSnapshot() {
        let delay = publication.delay(now: Double(radioNow()) / 1e9)
        if delay == 0 {
            publishWork?.cancel(); publishWork = nil; onSample?(stats)
        } else if publishWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.publishWork = nil; self?.publishSnapshot() }
            publishWork = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    func close(_ reason: String) {
        queue.sync {
            // Account for already-due output before the partial final metrics interval.
            displayReady(now: Double(radioNow()) / 1e9)
            closed = true; resetDecoder(removeImage: true); format = nil
            stats.state = "disconnected"; sample()
            log?.event("video.disconnected", "session=\(stats.session) \(reason); image cleared to black")
        }
    }
    private static func compressedSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // Validate the complete 4-byte AVCC NAL chain before passing bytes to VT.
        var offset = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { return nil }
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard length > 0, length <= data.count - offset else { return nil }; offset += length
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                        offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?, size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    deinit { publishWork?.cancel(); wake?.cancel(); if let decoder { VTDecompressionSessionInvalidate(decoder) } }
}

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
    var contentRect: VideoRect?
    var received = 0, decoded = 0, displayed = 0, decodeErrors = 0, displayDrops = 0, dropped = 0
    var keyframeRequests = 0, frameBytes = 0, receivedBytes = 0
    var receivedFPS: Double = 0, decodedFPS: Double = 0, displayedFPS: Double = 0, receivedMbit: Double = 0
    var interArrivalP95MS: Double?, longestGapMS: Double = 0
    var thermal = "unknown", residentMemoryMB: Double?
}

/// Owns decode, immediate presentation and counters for exactly one video session.
/// Input is serialized on a private queue; only two async VT callbacks may be pending.
/// The layer is attached on main, but sample enqueue/flush stays with this renderer.
final class VideoSessionRenderer: RadioVideoConsumer {
    let layer = AVSampleBufferDisplayLayer()
    private let queue: DispatchQueue
    private let log: RadioLog?
    private let request: (String) -> Void
    var onSample: ((VideoReceiveSnapshot) -> Void)? // Installed before first configure/tick.
    private var stats: VideoReceiveSnapshot
    private var config: VideoConfig?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var epoch = 0
    private var waitingForIDR = true
    private var closed = false
    private struct Pending { let completion: (VideoDecodeStatus) -> Void; let time: UInt64 }
    private var pending: [UInt64: Pending] = [:]
    private var lastRequest: UInt64 = 0
    private var lastArrival: UInt64?
    private var lastDisplay: UInt64?
    private var intervals: [(UInt64, Double)] = []
    private var sampledAt = radioNow()
    private var previous = (received: 0, decoded: 0, displayed: 0, bytes: 0)
    init(session: UUID, log: RadioLog?, request: @escaping (String) -> Void) {
        queue = DispatchQueue(label: "iosdirect.video.decode.\(session)", qos: .userInteractive)
        stats = VideoReceiveSnapshot(session: session); self.log = log; self.request = request
        layer.videoGravity = .resizeAspect; layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }
    func configure(_ config: VideoConfig) throws {
        try queue.sync {
            guard !closed else { return }
            if self.config == config, decoder != nil { return }
            if let old = self.config, config.generation < old.generation {
                throw RadioError.protocolViolation("video generation regression")
            }
            if let old = self.config, old.generation == config.generation, old != config {
                throw RadioError.protocolViolation("config changed without generation")
            }
            resetDecoder(); self.config = config
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
            format = description
            createDecoder()
            onSample?(stats)
            log?.event("video.config", "session=\(stats.session) generation=\(config.generation) pixels=\(size.width)x\(size.height) orientation=\(config.orientation) contentRect=\(String(describing: config.contentRect)); raw pixels retained; layer applies CGImagePropertyOrientation")
        }
    }
    private func createDecoder() {
        guard let format else { return }
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &decoder)
        guard status == noErr, let decoder else { decodeFailure("decoder create OSStatus=\(status)"); return }
        let realTime = VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        log?.event("video.decoder", "session=\(stats.session) create=\(status) realTime=\(realTime)")
    }
    func receive(_ frame: VideoAccessUnit, completion: @escaping (VideoDecodeStatus) -> Void) {
        queue.sync {
            guard !closed else { completion(.dropped); return }
            let now = radioNow()
            stats.received += 1; stats.receivedBytes += frame.data.count; stats.frameBytes = frame.data.count
            if let lastArrival {
                let gap = Double(now - lastArrival) / 1e6
                stats.longestGapMS = max(stats.longestGapMS, gap); intervals.append((now, gap))
                if intervals.count > 600 { intervals.removeFirst(intervals.count - 600) }
            }
            lastArrival = now
            guard config?.generation == frame.generation, let format else {
                stats.dropped += 1; completion(.dropped); recover("missing config / generation mismatch"); return
            }
            guard !waitingForIDR || frame.keyframe else {
                stats.dropped += 1; completion(.dropped); askForIDR("awaiting keyframe"); return
            }
            guard pending.count < 2 else {
                stats.dropped += 1; completion(.dropped); recover("decode backlog"); return
            }
            if decoder == nil { createDecoder() }
            guard let decoder, let sample = Self.compressedSample(frame.data, format: format) else {
                stats.decodeErrors += 1; completion(.decodeError); recover("missing decoder / sample creation"); return
            }
            waitingForIDR = false
            let token = epoch, seq = frame.seq
            pending[seq] = Pending(completion: completion, time: now)
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                    self?.queue.async { [weak self] in self?.completed(seq: seq, epoch: token, status: status, image: image) }
                }
            // VT guarantees no output handler when submission fails.
            if status != noErr {
                pending.removeValue(forKey: seq)?.completion(.decodeError)
                decodeFailure("decode submit OSStatus=\(status)")
            }
        }
    }
    private func completed(seq: UInt64, epoch: Int, status: OSStatus, image: CVImageBuffer?) {
        guard !closed, epoch == self.epoch, let item = pending.removeValue(forKey: seq) else { return }
        guard status == noErr, let image else {
            item.completion(.decodeError); decodeFailure("decode output OSStatus=\(status) image=\(image != nil)"); return
        }
        stats.decoded += 1
        if present(image) { stats.displayed += 1; lastDisplay = radioNow(); stats.state = "streaming" }
        else { stats.displayDrops += 1 }
        item.completion(.decoded)
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
    private func resetDecoder() {
        epoch += 1
        if let decoder { VTDecompressionSessionInvalidate(decoder) }; decoder = nil
        let old = pending; pending.removeAll(); stats.dropped += old.count
        for item in old.values { item.completion(.dropped) }
        waitingForIDR = true
        layer.flushAndRemoveImage()
    }
    private func recover(_ reason: String) {
        resetDecoder(); stats.state = config == nil ? "waiting for config" : "stalled"; askForIDR(reason)
    }
    private func decodeFailure(_ reason: String) {
        stats.decodeErrors += 1
        log?.event("video.decodeError", "session=\(stats.session) \(reason)"); recover(reason)
    }
    func discontinuity(_ reason: String) { queue.sync { if !closed { stats.dropped += 1; recover(reason) } } }
    func tick() { queue.sync { sample() } }
    private func sample() {
        let now = radioNow(), seconds = Double(now - sampledAt) / 1e9
        if pending.values.contains(where: { now - $0.time > 2_000_000_000 }) { decodeFailure("decode output timeout") }
        if !closed, let lastDisplay, now - lastDisplay > 1_000_000_000 { stats.state = "stalled" }
        if let lastArrival { stats.longestGapMS = max(stats.longestGapMS, Double(now - lastArrival) / 1e6) }
        intervals.removeAll { now - $0.0 > 10_000_000_000 }
        let sorted = intervals.map(\.1).sorted()
        stats.interArrivalP95MS = sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        if seconds > 0 {
            stats.receivedFPS = Double(stats.received - previous.received) / seconds
            stats.decodedFPS = Double(stats.decoded - previous.decoded) / seconds
            stats.displayedFPS = Double(stats.displayed - previous.displayed) / seconds
            stats.receivedMbit = Double(stats.receivedBytes - previous.bytes) * 8 / seconds / 1e6
        }
        previous = (stats.received, stats.decoded, stats.displayed, stats.receivedBytes); sampledAt = now
        stats.monotonicNs = now; stats.thermal = radioThermalState(); stats.residentMemoryMB = radioMemoryMB()
        log?.write(stats); onSample?(stats)
    }
    func close(_ reason: String) {
        queue.sync {
            closed = true; resetDecoder(); format = nil; config = nil; stats.state = "disconnected"; sample()
            log?.event("video.disconnected", "session=\(stats.session) \(reason)")
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
    deinit { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
}

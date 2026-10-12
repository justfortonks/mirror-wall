import AVFoundation
import CoreMedia
import MirrorCore
import VideoToolbox

/// Decodes H.264 or H.265 frames once with VideoToolbox and shows each picture in any number of
/// AVSampleBufferDisplayLayers, so a slot can appear in its tile and in its own window at once.
///
/// Frames are shown the moment they arrive (no timestamp sync), which is what keeps the
/// picture alive after a phone sleeps and wakes. With `smoothMotion`, each picture instead waits
/// a moment and is shown at the pace the phone captured it (see `PlayoutClock`).
///
/// `render` and `reset` run on the slot's UDP thread or after it has stopped; layers are added
/// and removed on the main thread.
final class H264Renderer {
    private var codec: VideoCodec = .h264
    /// H.265 only.
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true

    private let lock = NSLock()
    // Guarded by `lock`.
    private var layers: [AVSampleBufferDisplayLayer] = []
    private var lastPicture: CMSampleBuffer?
    private var pictureFormat: CMVideoFormatDescription?
    private var smoothing = false
    private var playout = PlayoutClock()
    /// Counts pictures, so one held back can't replace a later one already shown.
    private var pictureNumber = 0
    private var shownNumber = 0
    private let playoutQueue = DispatchQueue(label: "Mirror Wall playout", qos: .userInteractive)

    /// Shows pictures at the pace the phone captured them, about a tenth of a second later,
    /// rather than as Wi-Fi delivers them.
    var smoothMotion: Bool {
        get { lock.withLock { smoothing } }
        set {
            lock.withLock {
                smoothing = newValue
                playout.reset()
            }
        }
    }

    /// Current picture size in pixels, once known.
    var dimensions: CMVideoDimensions? {
        formatDescription.map(CMVideoFormatDescriptionGetDimensions)
    }

    /// Called with each decoded picture and its frame's RTP timestamp, for recording. Runs on
    /// the decoder's thread.
    var onPicture: ((_ image: CVImageBuffer, _ rtpTimestamp: UInt32) -> Void)?

    /// The picture on screen now, if any, e.g. to start a recording with.
    var currentImage: CVImageBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastPicture.flatMap(CMSampleBufferGetImageBuffer)
    }

    /// The stream's codec, profile and level, e.g. "H.264 High 4.2". Read on the UDP thread.
    var codecDescription: String? {
        switch codec {
        case .h264: return sps.map(h264Description(sps:))
        case .hevc: return sps.map(hevcDescription(sps:))
        }
    }

    /// A new layer showing this slot's picture, starting with the latest one.
    func makeLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        lock.lock()
        layers.append(layer)
        let picture = lastPicture
        lock.unlock()
        if let picture { layer.sampleBufferRenderer.enqueue(picture) }
        return layer
    }

    /// Puts the latest picture into a layer again, e.g. when its view is shown after being hidden.
    func refresh(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        let picture = lastPicture
        lock.unlock()
        guard let picture else { return }
        layer.sampleBufferRenderer.flush()
        layer.sampleBufferRenderer.enqueue(picture)
    }

    func removeLayer(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.removeAll { $0 === layer }
        lock.unlock()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Decodes a frame that arrived at `arrival` (seconds of `DispatchTime` uptime). Returns true
    /// if it was handed to the decoder.
    @discardableResult
    func render(_ frame: H264Frame, arrival: Double) -> Bool {
        if frame.codec != codec {
            // The receiver restarted in the other mode: forget the old stream entirely.
            codec = frame.codec
            vps = nil
            sps = nil
            pps = nil
            formatDescription = nil
            invalidateSession()
        }
        var videoNALs: [[UInt8]] = []
        var parametersChanged = false
        for nal in frame.nalUnits {
            switch ParameterSet(nal, codec: codec) {
            case .vps:
                if nal != vps { vps = nal; parametersChanged = true }
            case .sps:
                if nal != sps { sps = nal; parametersChanged = true }
            case .pps:
                if nal != pps { pps = nal; parametersChanged = true }
            case .skip:
                continue
            case .none:
                videoNALs.append(nal)
            }
        }

        if parametersChanged || formatDescription == nil {
            // New stream or rotation: a fresh decoder that starts at the next keyframe.
            if let description = makeFormatDescription() {
                formatDescription = description
                invalidateSession()
            }
        }

        guard let formatDescription, !videoNALs.isEmpty else { return false }
        if waitingForKeyframe {
            guard frame.isKeyframe else { return false }
            waitingForKeyframe = false
        }
        guard let session = session ?? makeSession(format: formatDescription),
              let sample = Self.makeSampleBuffer(avcc: avccData(for: videoNALs), format: formatDescription) else {
            return false
        }

        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.present(imageBuffer, rtpTimestamp: frame.timestamp, arrival: arrival)
            self?.onPicture?(imageBuffer, frame.timestamp)
        }
        if status == kVTInvalidSessionErr {
            // The Mac slept or the GPU changed: start over at the next keyframe.
            invalidateSession()
        }
        return status == noErr
    }

    /// Clears the picture, e.g. when the slot stops. Only call it once rendering has stopped.
    func reset() {
        invalidateSession()
        vps = nil
        sps = nil
        pps = nil
        formatDescription = nil
        lock.lock()
        let current = layers
        lastPicture = nil
        pictureFormat = nil
        playout.reset()
        shownNumber = pictureNumber
        lock.unlock()
        for layer in current {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func makeSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { return nil }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        return newSession
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        waitingForKeyframe = true
    }

    /// Shows a decoded picture now or, with Smoother Motion, when it's due.
    private func present(_ imageBuffer: CVImageBuffer, rtpTimestamp: UInt32, arrival: Double) {
        lock.lock()
        pictureNumber += 1
        let number = pictureNumber
        guard smoothing else {
            show(imageBuffer, number: number)
            lock.unlock()
            return
        }
        let due = playout.due(rtp: rtpTimestamp, arrival: arrival)
        lock.unlock()
        playoutQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: UInt64(max(due, 0) * 1e9))) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.show(imageBuffer, number: number) }
        }
    }

    /// Hands a decoded picture to every layer. Call with `lock` held.
    private func show(_ imageBuffer: CVImageBuffer, number: Int) {
        guard number > shownNumber else { return }
        shownNumber = number
        if pictureFormat.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: imageBuffer) }) ?? true {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &format)
            pictureFormat = format
        }
        guard let pictureFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var picture: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: pictureFormat,
            sampleTiming: &timing,
            sampleBufferOut: &picture
        )
        guard let picture else { return }
        Self.markDisplayImmediately(picture)
        lastPicture = picture
        for layer in layers {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            renderer.enqueue(picture)
        }
    }

    /// What a NAL unit is to the decoder setup: a parameter set, something to leave out, or
    /// (nil) picture data to decode.
    private enum ParameterSet {
        case vps, sps, pps, skip

        init?(_ nal: [UInt8], codec: VideoCodec) {
            switch codec {
            case .h264:
                switch H264NALType(of: nal) {
                case .sps: self = .sps
                case .pps: self = .pps
                case .accessUnitDelimiter, .none: self = .skip
                default: return nil
                }
            case .hevc:
                guard let type = HEVCNALType.of(nal) else { self = .skip; return }
                switch type {
                case HEVCNALType.vps: self = .vps
                case HEVCNALType.sps: self = .sps
                case HEVCNALType.pps: self = .pps
                case HEVCNALType.accessUnitDelimiter: self = .skip
                default: return nil
                }
            }
        }
    }

    /// The decoder's format from the current parameter sets, once there are enough of them.
    private func makeFormatDescription() -> CMVideoFormatDescription? {
        guard let sps, let pps else { return nil }
        let sets: [[UInt8]]
        switch codec {
        case .h264: sets = [sps, pps]
        case .hevc:
            guard let vps else { return nil }
            sets = [vps, sps, pps]
        }
        // Copies the sets into one buffer, so their pointers stay valid for the call.
        let joined = sets.flatMap { $0 }
        var description: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            var offset = 0
            var pointers: [UnsafePointer<UInt8>] = []
            for set in sets {
                pointers.append(buffer.baseAddress! + offset)
                offset += set.count
            }
            let sizes = sets.map(\.count)
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(avcc: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }

    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

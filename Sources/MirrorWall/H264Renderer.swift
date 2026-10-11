import AVFoundation
import CoreMedia
import MirrorCore

/// Decodes and displays H.264 frames with an AVSampleBufferDisplayLayer.
///
/// Frames are shown the moment they arrive (no timestamp sync), which is what keeps the
/// picture alive after a phone sleeps and wakes.
final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Current picture size in pixels, once known.
    var dimensions: CMVideoDimensions? {
        formatDescription.map(CMVideoFormatDescriptionGetDimensions)
    }

    /// Enqueues a frame. Returns true if it was handed to the decoder.
    @discardableResult
    func render(_ frame: H264Frame) -> Bool {
        var videoNALs: [[UInt8]] = []
        var parametersChanged = false
        for nal in frame.nalUnits {
            switch H264NALType(of: nal) {
            case .sps:
                if nal != sps { sps = nal; parametersChanged = true }
            case .pps:
                if nal != pps { pps = nal; parametersChanged = true }
            case .accessUnitDelimiter, .none:
                continue
            default:
                videoNALs.append(nal)
            }
        }

        if parametersChanged || formatDescription == nil {
            // New stream or rotation: rebuild the format and start clean at the next keyframe.
            if let sps, let pps, let description = Self.makeFormatDescription(sps: sps, pps: pps) {
                if parametersChanged { layer.sampleBufferRenderer.flush() }
                formatDescription = description
                waitingForKeyframe = true
            }
        }

        guard let formatDescription, !videoNALs.isEmpty else { return false }
        if waitingForKeyframe {
            guard frame.isKeyframe else { return false }
            waitingForKeyframe = false
        }

        if layer.sampleBufferRenderer.status == .failed {
            layer.sampleBufferRenderer.flush()
            waitingForKeyframe = true
            if !frame.isKeyframe { return false }
            waitingForKeyframe = false
        }

        guard let sample = Self.makeSampleBuffer(avcc: avccData(for: videoNALs), format: formatDescription) else {
            return false
        }
        layer.sampleBufferRenderer.enqueue(sample)
        return true
    }

    /// Clears the picture, e.g. when the slot stops.
    func reset() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        sps = nil
        pps = nil
        formatDescription = nil
        waitingForKeyframe = true
    }

    private static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                let pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes = [spsBuffer.count, ppsBuffer.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
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

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Turns ReplayKit's screen frames into H.264 access units in Annex B, the way Mirror Wall Cast
/// sends them: every keyframe carries its SPS and PPS in front, so the Mac can start decoding at
/// any keyframe and tell the codec from the first NAL unit.
///
/// ReplayKit hands over portrait buffers whatever way the phone is held, with the orientation as
/// an attachment; frames are turned upright here first (VTPixelRotationSession, on the GPU) so
/// the Mac gets the picture the way it looks on the phone.
///
/// Memory: a broadcast extension is killed past about 50 MB. The pixel buffers live in IOSurfaces
/// and the encoder in the media server, so the extension itself stays small, but nothing here
/// keeps frames around: each is encoded and dropped.
final class ScreenEncoder {
    /// Called on the encoder's queue with each access unit and its capture time.
    var onAccessUnit: ((_ captureMicros: Int64, _ annexB: [UInt8], _ keyframe: Bool) -> Void)?

    /// The tallest picture sent; Mirror Wall's own H.264 limit (1920, as for Android).
    var maxLongSide: Int32 = 1920
    var maxFrameRate: Int = 30 {
        didSet { if let session { setFrameRate(session) } }
    }

    private var session: VTCompressionSession?
    private var sessionSize: (width: Int32, height: Int32) = (0, 0)
    private var rotation: VTPixelRotationSession?
    private var rotatedPool: CVPixelBufferPool?
    private var rotatedPoolSize: (width: Int, height: Int) = (0, 0)
    private var lastFrameAt: CMTime = .invalid
    private var forceKeyframe = true

    func requestKeyframe() { forceKeyframe = true }

    /// One frame from ReplayKit. `turns` is quarter turns left from upright (0 to 3).
    func encode(_ sampleBuffer: CMSampleBuffer, turns: Int) {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Keep to the Mac's frame rate; ReplayKit can deliver 60 or more.
        if lastFrameAt.isValid, maxFrameRate > 0 {
            let gap = CMTimeGetSeconds(CMTimeSubtract(pts, lastFrameAt))
            if gap < 1.0 / Double(maxFrameRate) * 0.9 && !forceKeyframe { return }
        }
        lastFrameAt = pts

        let upright = turns == 0 ? source : rotate(source, turns: turns) ?? source
        let width = Int32(CVPixelBufferGetWidth(upright))
        let height = Int32(CVPixelBufferGetHeight(upright))
        let scale = min(1, Double(maxLongSide) / Double(max(width, height)))
        // Even sizes, as H.264 needs.
        let target = (Int32(Double(width) * scale) & ~1, Int32(Double(height) * scale) & ~1)
        if session == nil || sessionSize != target {
            makeSession(width: target.0, height: target.1)
        }
        guard let session else { return }

        var properties: [CFString: Any]?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            forceKeyframe = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: upright, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: properties as CFDictionary?, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample)
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
        rotation = nil
        rotatedPool = nil
    }

    // MARK: Session

    private func makeSession(width: Int32, height: Int32) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        var created: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            Shared.log("Couldn't start the H.264 encoder (\(status))", from: "broadcast")
            return
        }
        let pixels = Double(width) * Double(height)
        // About 0.12 bits a pixel a frame at 30 fps: ~6 Mb/s for 880×1920, close to the Android app.
        let bitrate = Int(pixels * 30 * 0.12)
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate * 2 / 8, 1] as CFArray,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        for (key, value) in settings { VTSessionSetProperty(created, key: key, value: value as CFTypeRef) }
        setFrameRate(created)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        sessionSize = (width, height)
        forceKeyframe = true
        Shared.log("Encoding H.264 \(width)×\(height) at up to \(maxFrameRate) fps, \(bitrate / 1000) kb/s", from: "broadcast")
    }

    private func setFrameRate(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: maxFrameRate as CFNumber)
    }

    // MARK: Rotation

    private func rotate(_ source: CVPixelBuffer, turns: Int) -> CVPixelBuffer? {
        if rotation == nil {
            var created: VTPixelRotationSession?
            VTPixelRotationSessionCreate(nil, &created)
            rotation = created
        }
        guard let rotation else { return nil }
        let angle: CFString
        switch turns & 3 {
        case 1: angle = kVTRotation_CCW90
        case 2: angle = kVTRotation_180
        default: angle = kVTRotation_CW90
        }
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
        let sideways = turns & 1 == 1
        let width = sideways ? CVPixelBufferGetHeight(source) : CVPixelBufferGetWidth(source)
        let height = sideways ? CVPixelBufferGetWidth(source) : CVPixelBufferGetHeight(source)
        if rotatedPool == nil || rotatedPoolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attributes as CFDictionary, &pool)
            rotatedPool = pool
            rotatedPoolSize = (width, height)
        }
        guard let rotatedPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, rotatedPool, &output)
        guard let output, VTPixelRotationSessionRotateImage(rotation, source, output) == noErr else { return nil }
        return output
    }

    // MARK: Output

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func deliver(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let keyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        var annexB: [UInt8] = []
        if keyframe {
            // SPS and PPS in front, as the Mac expects on every keyframe.
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    annexB += Self.startCode
                    annexB += UnsafeBufferPointer(start: pointer, count: size)
                }
            }
        }

        // AVCC (4-byte lengths) to Annex B (start codes).
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }
        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        annexB.reserveCapacity(annexB.count + length + 16)
        while offset + 4 <= length {
            let unitLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard unitLength > 0, offset + unitLength <= length else { break }
            annexB += Self.startCode
            annexB += UnsafeBufferPointer(start: bytes + offset, count: unitLength)
            offset += unitLength
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        onAccessUnit?(micros, annexB, keyframe)
    }
}

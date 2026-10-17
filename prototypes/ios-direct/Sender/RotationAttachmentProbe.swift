import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Capture-queue only. Inspect metadata without copying or describing pixel bytes.
/// A changing timestamp is itself a change; at most one event per second is emitted.
struct RotationAttachmentProbe {
    private var last: String?
    private var lastTime: Double?
    mutating func inspect(_ sample: CMSampleBuffer, log: RunLog?) {
        let now = uptime()
        guard lastTime.map({ now - $0 >= 1 }) ?? true else { return }
        var fields = [String: Any]()
        fields["sampleAttachmentsArray"] = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        fields["sampleCMGetAttachment"] = cmAttachments(sample)
        if let image = sample.imageBuffer {
            fields["bufferDimensions"] = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))"
            fields["imageCMGetAttachment"] = cmAttachments(image)
            fields["imageCVShouldPropagate"] = CVBufferCopyAttachments(image, .shouldPropagate)
            fields["imageCVShouldNotPropagate"] = CVBufferCopyAttachments(image, .shouldNotPropagate)
        } else { fields["bufferDimensions"] = "no image buffer" }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] {
            // Enumerate all present keys, including unknown SDK/runtime additions.
            fields["SCStreamFrameInfo"] = array.map { info in
                Dictionary(info.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { _, last in last })
            }
        }
        let snapshot = metadata(fields)
        guard snapshot != last else { return }
        last = snapshot; lastTime = now
        log?.event("capture.rotationAttachments", snapshot)
    }
    private func cmAttachments(_ bearer: CMAttachmentBearer) -> [String: Any] {
        var values = [String: Any]()
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            guard let keys = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: bearer,
                                                         attachmentMode: mode) as? [String: Any] else { continue }
            for key in keys.keys {
                var actualMode: CMAttachmentMode = 0
                if let value = CMGetAttachment(bearer, key: key as CFString, attachmentModeOut: &actualMode) {
                    values["\(key) [mode=\(actualMode)]"] = value
                }
            }
        }
        return values
    }
    private func metadata(_ value: Any) -> String {
        // Keep log lines small: blobs such as ICC profiles are summarized by size and a short prefix.
        if let bytes = value as? Data { return "<attachment data \(bytes.count) bytes; prefix=\(bytes.prefix(64).base64EncodedString())>" }
        if let dictionary = value as? NSDictionary {
            return "{" + dictionary.map { (String(describing: $0.key), metadata($0.value)) }
                .sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ", ") + "}"
        }
        if let array = value as? NSArray { return "[" + array.map { metadata($0) }.joined(separator: ", ") + "]" }
        if let string = value as? String { return String(reflecting: string) }
        if let number = value as? NSNumber { return number.stringValue }
        if let boxed = value as? NSValue { return boxed.description }
        // Never invoke descriptions on opaque media objects (e.g. CVPixelBuffer).
        return "<opaque \(type(of: value))>"
    }
}

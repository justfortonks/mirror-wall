import AVFoundation
import CoreMedia
import MirrorCore
import VideoToolbox

/// Writes one slot's pictures to movie files, compressing them with the Mac's video encoder.
///
/// It records the pictures already decoded for the tile rather than copying the phone's video,
/// because a copied stream can only start on a keyframe, and an iPhone sends one only when
/// mirroring starts, the screen wakes or it rotates. Re-compressing lets a recording start the
/// moment it's asked for.
///
/// The video is a square, sized when the file starts to hold the phone's picture either way up,
/// so turning the phone doesn't start a new file: each picture is scaled to fit it, upright with
/// black bars at the sides, sideways with bars above and below. (Turning can change the picture's
/// longer side, not just swap its width and height: an iPhone sends 498×1080 upright but
/// 1920×884 sideways.) A new file starts when a new connection begins. Frames are timed from the stream's own timestamps where it has them
/// (`RecordingClock`), not their bursty arrival.
///
/// Files are written in fragments every couple of seconds, so a file cut short (the app quits
/// unexpectedly, or the encoder fails) still plays up to its last fragment. If the writer fails
/// or the encoder stops taking pictures, that file is closed and the next one starts a moment
/// later, rather than the slot showing it's recording while nothing gets written.
///
/// Not thread-safe: the slot calls it under its own lock.
final class SlotRecorder {
    private let folder: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// The square video's side, in pixels.
    private var side: Int?
    /// Fits each picture into the square, with black bars.
    private var transfer: VTPixelTransferSession?
    private var canvasPool: CVPixelBufferPool?
    /// Names later files, e.g. after the phone that's mirroring.
    var baseName: String
    private var part = 0
    private var startedAt = Date()
    private var clock = RecordingClock()
    /// When the encoder began refusing pictures (`append`'s arrival), to notice one that has
    /// stopped; nil while it's taking them.
    private var refusingSince: Double?
    /// After a failure, no new file starts before this arrival time, so a failure that repeats
    /// doesn't make a file per picture.
    private var retryAfter = 0.0

    /// An encoder that has refused every picture for this long counts as stuck.
    static let stallLimit = 5.0
    static let retryDelay = 2.0

    /// Fine enough that frames a few milliseconds apart never share a time.
    static let timescale: CMTimeScale = 90_000

    /// The file being written, if any.
    private(set) var currentURL: URL?
    /// Called (on any thread) with a message when writing fails.
    var onError: ((String) -> Void)?

    init(folder: URL, baseName: String) {
        self.folder = folder
        self.baseName = baseName
    }

    /// Adds a decoded picture stamped `rtpTimestamp` (nil if unknown) that arrived at `arrival`
    /// (seconds of `DispatchTime` uptime).
    func append(image: CVImageBuffer, rtpTimestamp: UInt32?, arrival: Double) {
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        if let writer, writer.status != .writing {
            // Failed between pictures (e.g. the encoder was lost while the Mac slept).
            abandonFile(writer, at: arrival)
        }
        if writer == nil {
            guard arrival >= retryAfter else { return }
            clock = RecordingClock()
            startFile(side: Self.side(width: width, height: height), format: CVPixelBufferGetPixelFormatType(image), at: arrival)
        }
        guard let writer, let input, let adaptor else { return }
        guard input.isReadyForMoreMediaData else {
            // Dropped; the encoder keeps up with a phone easily, so this is rare. One that has
            // refused every picture for seconds is stuck: close the file and start another.
            let since = refusingSince ?? arrival
            refusingSince = since
            if arrival - since > Self.stallLimit {
                onError?("the encoder stopped taking pictures; starting a new file")
                endFile(at: arrival)
                retryAfter = arrival + Self.retryDelay
            }
            return
        }
        refusingSince = nil
        guard let squared = fitted(image) else {
            onError?("couldn't fit a \(width)×\(height) picture into the recording")
            return
        }
        let time = CMTime(seconds: clock.time(rtp: rtpTimestamp, arrival: arrival), preferredTimescale: Self.timescale)
        if !adaptor.append(squared, withPresentationTime: time) {
            abandonFile(writer, at: arrival)
        }
    }

    /// Gives up on a file whose writer has failed: it can't be finished, but its fragments so far
    /// still play. The next picture after a short pause starts a new file.
    private func abandonFile(_ writer: AVAssetWriter, at arrival: Double) {
        fail(writer)
        self.writer = nil
        input = nil
        adaptor = nil
        side = nil
        currentURL = nil
        retryAfter = arrival + Self.retryDelay
    }

    /// The square's side for a recording whose first picture is this size: long enough for the
    /// phone turned the other way too. The stream fits a 16:9 box, so an upright picture's height
    /// is the box's height and a sideways one may be up to 16/9 of that wide (1080 → 1920). Capped
    /// at 2560, within what H.264 encoders take, so Sharper Picture's 3840-wide landscape is
    /// scaled down a little. Even, as H.264 needs.
    static func side(width: Int, height: Int) -> Int {
        let long = max(width, height)
        let roomy = height > width ? max(long, long * 16 / 9) : long
        return min(roomy, 2560) & ~1
    }

    /// The picture centred in a square buffer, scaled to fit if needed, with black around it.
    private func fitted(_ image: CVImageBuffer) -> CVPixelBuffer? {
        guard let transfer, let canvasPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, canvasPool, &output)
        guard let output, VTPixelTransferSessionTransferImage(transfer, from: image, to: output) == noErr else { return nil }
        return output
    }

    /// Finishes the current file but keeps recording: the next picture starts a new one.
    func endFile(wait: Bool = false) {
        endFile(at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9, wait: wait)
    }

    private func endFile(at arrival: Double, wait: Bool = false) {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        adaptor = nil
        side = nil
        currentURL = nil
        guard writer.status == .writing else { return }
        input.markAsFinished()
        // Keep the last picture on screen until now, e.g. through a still screen that sent no frames.
        writer.endSession(atSourceTime: CMTime(seconds: clock.time(atArrival: arrival), preferredTimescale: Self.timescale))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { [weak self] in
            if writer.status == .failed { self?.fail(writer) }
            done.signal()
        }
        // When the app is quitting, wait so the file is complete before it exits.
        if wait { _ = done.wait(timeout: .now() + 3) }
    }

    private func startFile(side: Int, format: OSType, at arrival: Double) {
        // If this one can't start either, wait before trying again.
        retryAfter = arrival + Self.retryDelay
        part += 1
        if part == 1 { startedAt = Date() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(base: baseName, startedAt: startedAt, part: part))
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieTimeScale = Self.timescale
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(side: side))
            input.mediaTimeScale = Self.timescale
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                onError?("couldn't record a \(side)×\(side) video")
                return
            }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else {
                fail(writer)
                return
            }
            writer.startSession(atSourceTime: .zero)
            if transfer == nil {
                VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
                if let transfer {
                    VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
                }
            }
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: side,
                kCVPixelBufferHeightKey: side,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            canvasPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &canvasPool)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.side = side
            currentURL = url
            refusingSince = nil
            // Started: the next file (e.g. after the phone rotates) may start at once.
            retryAfter = 0
        } catch {
            onError?("couldn't create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// H.264, which every player and editor reads, in a `side`-pixel square, at a generous
    /// bitrate for a 16:9 picture that wide so the copy looks like what the phone sent (the black
    /// bars cost almost nothing): about 15 Mbps for a 1920 square.
    static func videoSettings(side: Int) -> [String: Any] {
        let bitsPerSecond = max(4_000_000, Double(side * side * 9 / 16) * 60 * 0.12)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                // A keyframe every 2 seconds so players can jump around the file.
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    private func fail(_ writer: AVAssetWriter) {
        onError?("recording failed: \(writer.error?.localizedDescription ?? "unknown error")")
    }

    /// "iPhone 2026-10-11 21.05.33.mov", then "… part 2.mov" and so on.
    static func fileName(base: String, startedAt: Date, part: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let suffix = part > 1 ? " part \(part)" : ""
        return "\(safe) \(formatter.string(from: startedAt))\(suffix).mov"
    }

    /// Where recordings go: Documents › MirrorWall › Recordings, or the folder chosen in Settings.
    static var defaultFolder: URL { SaveFolders.recordings }
}

import AVFoundation
import CoreMedia
import MirrorCore

/// Writes one slot's video to movie files as it arrives, without re-encoding: the phone's own
/// H.264 goes straight into the file, so recording costs almost nothing and loses no quality.
///
/// A file starts at the next keyframe. A new file starts whenever the stream's format changes
/// (the phone rotates) or a new connection begins, because one movie track can't change size.
/// A piece cut short by a format change within `minimumPiece` seconds (the phone briefly thinking
/// it's sideways as mirroring starts) is thrown away rather than kept as a stub.
///
/// Frames are timed from the stream's own timestamps (`RecordingClock`), not their bursty arrival.
///
/// Not thread-safe: the slot calls it under its own lock.
final class SlotRecorder {
    private let folder: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMVideoFormatDescription?
    /// Names later files, e.g. after the phone that's mirroring.
    var baseName: String
    private var part = 0
    private var startedAt = Date()
    private var clock = RecordingClock()

    static let minimumPiece = 3.0
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

    /// Adds a compressed frame stamped `rtpTimestamp` that arrived at `arrival` (seconds of
    /// `DispatchTime` uptime).
    func append(avcc: [UInt8], format: CMVideoFormatDescription, isKeyframe: Bool, rtpTimestamp: UInt32, arrival: Double) {
        if let current = self.format, !CMFormatDescriptionEqual(current, otherFormatDescription: format) {
            endFile(at: arrival, discardIfShort: true)
        }
        if writer == nil {
            guard isKeyframe else { return }
            clock = RecordingClock()
            startFile(format: format)
        }
        guard let writer, let input, writer.status == .writing else { return }
        let time = CMTime(seconds: clock.time(rtp: rtpTimestamp, arrival: arrival), preferredTimescale: Self.timescale)
        guard input.isReadyForMoreMediaData,
              let sample = H264Renderer.makeSampleBuffer(avcc: avcc, format: format, presentationTime: time) else {
            return // dropped; writing is far faster than a phone sends, so this is rare
        }
        if !input.append(sample) {
            fail(writer)
        }
    }

    /// Finishes the current file but keeps recording: the next connection starts a new one.
    func endFile(wait: Bool = false) {
        endFile(at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9, discardIfShort: false, wait: wait)
    }

    private func endFile(at arrival: Double, discardIfShort: Bool, wait: Bool = false) {
        guard let writer, let input else { return }
        let url = currentURL
        self.writer = nil
        self.input = nil
        format = nil
        currentURL = nil
        guard writer.status == .writing else { return }
        if discardIfShort, clock.duration < Self.minimumPiece {
            writer.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            part -= 1 // the next piece takes this one's name
            return
        }
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

    private func startFile(format: CMVideoFormatDescription) {
        part += 1
        if part == 1 { startedAt = Date() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(base: baseName, startedAt: startedAt, part: part))
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieTimeScale = Self.timescale
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.mediaTimeScale = Self.timescale
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                onError?("couldn't record this video format")
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                fail(writer)
                return
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.format = format
            currentURL = url
        } catch {
            onError?("couldn't create \(url.lastPathComponent): \(error.localizedDescription)")
        }
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

    /// Where recordings go: ~/Movies/Mirror Wall.
    static var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Mirror Wall")
    }
}

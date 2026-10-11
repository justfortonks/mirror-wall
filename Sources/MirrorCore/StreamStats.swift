/// One second's worth of a slot's video stream, for the Stats for Nerds overlay.
public struct StreamSnapshot: Equatable {
    /// Frames that reached the screen, per second.
    public var framesPerSecond: Double
    /// Video data arriving, in bits per second.
    public var bitsPerSecond: Double
    /// How unevenly frames arrive: the standard deviation of the gaps between them, in seconds.
    public var frameJitter: Double
    /// Average time the Mac took to decode a frame and hand it to the screen, in seconds.
    public var macTime: Double?
    /// RTP packets that never arrived from uxplay (local drops), in this second and in total.
    public var packetsLost: Int
    public var totalPacketsLost: Int
    /// Frames that couldn't be shown (waiting for a keyframe after a loss, or a decode error).
    public var totalFramesSkipped: Int
    public var totalKeyframes: Int
    /// Seconds between the last two keyframes.
    public var keyframeInterval: Double?

    public init(
        framesPerSecond: Double = 0, bitsPerSecond: Double = 0, frameJitter: Double = 0, macTime: Double? = nil,
        packetsLost: Int = 0, totalPacketsLost: Int = 0, totalFramesSkipped: Int = 0, totalKeyframes: Int = 0,
        keyframeInterval: Double? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.bitsPerSecond = bitsPerSecond
        self.frameJitter = frameJitter
        self.macTime = macTime
        self.packetsLost = packetsLost
        self.totalPacketsLost = totalPacketsLost
        self.totalFramesSkipped = totalFramesSkipped
        self.totalKeyframes = totalKeyframes
        self.keyframeInterval = keyframeInterval
    }
}

/// Measures a video stream as it arrives and sums it up once a second.
///
/// Not thread-safe: feed it from one thread (the slot's UDP thread). Times are in seconds on any
/// steady clock.
public final class StreamMeter {
    private let window: Double
    private var windowStart: Double?
    private var bytes = 0
    private var shown = 0
    private var lost = 0
    private var macTimeTotal = 0.0
    private var macTimeCount = 0
    private var gaps: [Double] = []
    private var lastFrameAt: Double?
    private var lastKeyframeAt: Double?
    private var keyframeInterval: Double?
    private var totalLost = 0
    private var totalSkipped = 0
    private var totalKeyframes = 0

    static let pauseGap = 0.5

    public init(window: Double = 1) {
        self.window = window
    }

    /// A packet of `bytes` arrived; `lost` packets were missing before it.
    public func packet(bytes: Int, lost: Int, at time: Double) {
        if windowStart == nil { windowStart = time }
        self.bytes += bytes
        self.lost += lost
        totalLost += lost
    }

    /// A complete frame arrived. `macTime` is how long decoding and display took, or nil if the
    /// frame couldn't be shown.
    public func frame(at time: Double, isKeyframe: Bool, macTime: Double?) {
        if windowStart == nil { windowStart = time }
        guard let macTime else {
            totalSkipped += 1
            return
        }
        shown += 1
        macTimeTotal += macTime
        macTimeCount += 1
        // A longer gap is a pause (an unchanging screen sends no frames), not jitter.
        if let lastFrameAt, time - lastFrameAt < Self.pauseGap { gaps.append(time - lastFrameAt) }
        lastFrameAt = time
        if isKeyframe {
            totalKeyframes += 1
            if let lastKeyframeAt { keyframeInterval = time - lastKeyframeAt }
            lastKeyframeAt = time
        }
    }

    /// Once a window has passed, sums it up and starts the next one; otherwise nil.
    public func snapshotIfDue(at time: Double) -> StreamSnapshot? {
        guard let start = windowStart, time - start >= window else { return nil }
        let elapsed = time - start
        let snapshot = StreamSnapshot(
            framesPerSecond: Double(shown) / elapsed,
            bitsPerSecond: Double(bytes * 8) / elapsed,
            frameJitter: Self.standardDeviation(gaps),
            macTime: macTimeCount > 0 ? macTimeTotal / Double(macTimeCount) : nil,
            packetsLost: lost,
            totalPacketsLost: totalLost,
            totalFramesSkipped: totalSkipped,
            totalKeyframes: totalKeyframes,
            keyframeInterval: keyframeInterval
        )
        windowStart = time
        bytes = 0
        shown = 0
        lost = 0
        macTimeTotal = 0
        macTimeCount = 0
        gaps = []
        return snapshot
    }

    /// Starts over, for a new connection.
    public func reset() {
        windowStart = nil
        bytes = 0
        shown = 0
        lost = 0
        macTimeTotal = 0
        macTimeCount = 0
        gaps = []
        lastFrameAt = nil
        lastKeyframeAt = nil
        keyframeInterval = nil
        totalLost = 0
        totalSkipped = 0
        totalKeyframes = 0
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

/// "H.264 High 4.2" from a sequence parameter set (its profile and level bytes).
public func h264Description(sps: [UInt8]) -> String {
    guard sps.count >= 4 else { return "H.264" }
    let profiles: [UInt8: String] = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"]
    let profile = profiles[sps[1]] ?? "profile \(sps[1])"
    let level = sps[3]
    return "H.264 \(profile) \(level / 10).\(level % 10)"
}

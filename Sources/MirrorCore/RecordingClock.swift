/// Times a recording's frames from the stream's own RTP timestamps, so playback is as smooth as
/// the phone made it. Arrival times alone come in network bursts (2 ms, 2 ms, then 47 ms) and
/// sometimes tie, which players such as QuickTime show as stutter.
///
/// Falls back to arrival time when a timestamp jumps backwards or too far, and pulls back to it
/// if the two drift more than a second apart, so a bad stamp can't throw the timeline off.
public struct RecordingClock {
    /// H.264 over RTP counts at 90 kHz.
    public static let rtpRate = 90_000.0
    static let maxStep = 2.0
    static let maxDrift = 1.0
    static let minStep = 0.001

    private var start: Double?
    private var last: (rtp: UInt32?, arrival: Double, time: Double)?

    public init() {}

    /// Seconds into the recording for a frame stamped `rtp` that arrived at `arrival` (seconds
    /// on any steady clock). Always later than the previous frame's. A nil stamp (a picture whose
    /// stamp isn't known, such as the one on screen when recording starts) is timed by arrival,
    /// and so is the frame after it.
    public mutating func time(rtp: UInt32?, arrival: Double) -> Double {
        guard let last, let start else {
            start = arrival
            last = (rtp, arrival, 0)
            return 0
        }
        let stamped = rtp.flatMap { rtp in last.rtp.map { Double(rtp &- $0) / Self.rtpRate } } ?? -1
        var time = last.time + (stamped > 0 && stamped <= Self.maxStep ? stamped : arrival - last.arrival)
        let wall = arrival - start
        if abs(time - wall) > Self.maxDrift { time = wall }
        time = max(time, last.time + Self.minStep)
        self.last = (rtp, arrival, time)
        return time
    }

    /// Seconds into the recording at `arrival`, for ending it: the last frame stays on screen
    /// until then.
    public func time(atArrival arrival: Double) -> Double {
        guard let last else { return 0 }
        return last.time + max(arrival - last.arrival, Self.minStep)
    }

    /// Seconds from the first frame to the last.
    public var duration: Double { last?.time ?? 0 }
}

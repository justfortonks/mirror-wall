/// Decides when to show each frame for Smoother Motion: at the pace the phone captured them
/// (their RTP timestamps), a short delay after they arrive, instead of in Wi-Fi's bursts.
///
/// Each frame is due at its capture time plus the quickest trip any recent frame made, plus
/// `delay`. A frame that arrives later than that is shown at once. The quickest trip is
/// re-measured every `window` seconds, so a network that gets slower (or the two clocks drifting
/// apart) doesn't leave every frame late. A timestamp that jumps backwards or more than
/// `maxStep` ahead, such as after the screen was off, starts over.
public struct PlayoutClock {
    /// H.264 over RTP counts at 90 kHz.
    static let rtpRate = 90_000.0
    static let maxStep = 2.0
    public static let defaultDelay = 0.1
    static let window = 5.0

    /// How long frames wait beyond the quickest trip, to absorb the network's jitter.
    public var delay: Double

    private var lastRTP: UInt32?
    private var lastArrival = 0.0
    /// The current frame's capture time, in seconds on the clock's own timeline.
    private var media = 0.0
    /// The quickest trip (arrival minus capture time) in use, and the quickest in this window.
    private var bestTrip: Double?
    private var windowBest: Double?
    private var windowStart = 0.0
    private var lastDue = -Double.infinity

    public init(delay: Double = PlayoutClock.defaultDelay) {
        self.delay = delay
    }

    /// When to show a frame stamped `rtp` that arrived at `arrival` (seconds on any steady clock),
    /// on the same clock. Never earlier than `arrival` or than the frame before it.
    public mutating func due(rtp: UInt32, arrival: Double) -> Double {
        if let lastRTP {
            let step = Double(Int32(bitPattern: rtp &- lastRTP)) / Self.rtpRate
            if step < 0 || step > Self.maxStep {
                media += max(arrival - lastArrival, 0)
                bestTrip = nil
                windowBest = nil
            } else {
                media += step
            }
        }
        lastRTP = rtp
        lastArrival = arrival

        let trip = arrival - media
        if bestTrip == nil || trip < bestTrip! {
            bestTrip = trip
        }
        if windowBest == nil || trip < windowBest! {
            windowBest = trip
        }
        if arrival - windowStart >= Self.window {
            bestTrip = windowBest
            windowBest = trip
            windowStart = arrival
        }

        let due = max(media + bestTrip! + delay, arrival, lastDue)
        lastDue = due
        return due
    }

    /// Forgets the stream, e.g. when a new phone connects.
    public mutating func reset() {
        self = PlayoutClock(delay: delay)
    }
}

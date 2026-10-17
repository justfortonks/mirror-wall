import Foundation

public struct VideoTimingSummary: Codable, Equatable {
    public let count: Int
    public let p50MS: Double?, p95MS: Double?, maxMS: Double?
}
/// Bounded, rolling last-one-second samples. Empty windows stay unavailable.
public struct VideoTimingWindow {
    private var samples: [(time: Double, ms: Double)] = []
    public init() {}
    private mutating func prune(now: Double) { samples.removeAll { now - $0.time > 1 } }
    public mutating func add(milliseconds: Double, at now: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, now.isFinite else { return }
        prune(now: now); samples.append((now, milliseconds))
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }
    }
    public mutating func summary(now: Double) -> VideoTimingSummary {
        prune(now: now); let sorted = samples.map(\.ms).sorted(), n = samples.count
        return VideoTimingSummary(count: n,
            p50MS: n == 0 ? nil : (sorted[(n - 1) / 2] + sorted[n / 2]) / 2,
            p95MS: n == 0 ? nil : sorted[max(0, Int(ceil(Double(n) * 0.95)) - 1)], maxMS: sorted.last)
    }
}
public struct VideoStageSnapshot: Codable {
    public let arrivalToSubmit: VideoTimingSummary
    public let decode: VideoTimingSummary
    public let completeToEnqueue: VideoTimingSummary
    public let interArrival: VideoTimingSummary
}
public struct VideoStageDiagnostics {
    private var arrivalToSubmit = VideoTimingWindow(), decode = VideoTimingWindow()
    private var completeToEnqueue = VideoTimingWindow(), interArrival = VideoTimingWindow()
    private var lastArrival: Double?
    public init() {}
    public mutating func arrived(at now: Double) {
        if let lastArrival { interArrival.add(milliseconds: (now - lastArrival) * 1000, at: now) }
        lastArrival = now
    }
    public mutating func submitted(arrival: Double, at now: Double) { arrivalToSubmit.add(milliseconds: (now - arrival) * 1000, at: now) }
    public mutating func completed(submitted: Double, at now: Double) { decode.add(milliseconds: (now - submitted) * 1000, at: now) }
    public mutating func enqueued(completed: Double, at now: Double) { completeToEnqueue.add(milliseconds: (now - completed) * 1000, at: now) }
    public mutating func snapshot(now: Double) -> VideoStageSnapshot {
        VideoStageSnapshot(arrivalToSubmit: arrivalToSubmit.summary(now: now), decode: decode.summary(now: now),
            completeToEnqueue: completeToEnqueue.summary(now: now), interArrival: interArrival.summary(now: now))
    }
}

/// Immediate pictures use the next available worker turn, with no extra 1 ms
/// timer. Already queued completions can still coalesce to their newest picture.
public enum VideoServiceSchedule {
    public static func next(now: Double, decodeDeadline: Double?, pictureDue: Double?) -> Double? {
        [decodeDeadline, pictureDue.map { max(now, $0) }].compactMap { $0 }.min()
    }
}
public struct VideoPublicationGate {
    private var last = -Double.infinity
    public init() {}
    public mutating func delay(now: Double) -> Double {
        let delay = max(0, last + 0.5 - now)
        if delay == 0 { last = now }
        return delay
    }
}

import Foundation

public enum VideoDecodeAdmission: Equatable {
    case decode, waitForKeyframe
    case recover(String)
}

/// Outstanding compressed units, including those already submitted to VT. Never
/// skip a reference frame inside these bounds. Caller invalidates VT on recovery.
public struct VideoDecodeQueuePolicy {
    public static let maxFrames = 8
    public static let maxAge = 0.3
    private var pending: [UInt64: Double] = [:]
    public private(set) var waitingForKeyframe = true
    private var peakDepth = 0
    public var depth: Int { pending.count }
    public var deadline: Double? { pending.values.min().map { $0 + Self.maxAge } }
    public init() {}
    public mutating func reset() { pending.removeAll(); waitingForKeyframe = true }
    public mutating func expire(now: Double) -> String? {
        guard let deadline, now >= deadline else { return nil }
        reset(); return "decode queue age"
    }
    public mutating func admit(seq: UInt64, keyframe: Bool, now: Double) -> VideoDecodeAdmission {
        if waitingForKeyframe && !keyframe { return .waitForKeyframe }
        if depth >= Self.maxFrames {
            reset(); return .recover("decode queue count")
        }
        waitingForKeyframe = false; pending[seq] = now
        peakDepth = max(peakDepth, depth)
        return .decode
    }
    public mutating func complete(seq: UInt64) { pending.removeValue(forKey: seq) }
    /// Peak since the preceding metrics line, including frames drained before sampling.
    public mutating func samplePeakDepth() -> Int {
        defer { peakDepth = depth }; return peakDepth
    }
}

public enum VideoConfigChange: Equatable { case identical, changed }
public struct VideoConfigurationState {
    public private(set) var current: VideoConfig?
    public init() {}
    public mutating func update(_ config: VideoConfig) throws -> VideoConfigChange {
        if current == config { return .identical }
        if let old = current {
            guard config.generation >= old.generation else { throw RadioError.protocolViolation("video generation regression") }
            guard config.generation != old.generation else { throw RadioError.protocolViolation("config changed without generation") }
        }
        current = config; return .changed
    }
}

/// PTS-based receiver clock, independent of the sender's clock offset. Like Mirror
/// Wall's clock, anchors to the quickest recent trip, remeasures every five seconds,
/// and resets the anchor on a backwards timestamp or >2 s discontinuity.
public struct VideoPlayoutClock {
    private var lastPTS: UInt64?
    private var lastArrival = 0.0, media = 0.0
    private var bestTrip: Double?, windowBest: Double?
    private var windowStart = 0.0, lastDue = -Double.infinity
    public init() {}
    public mutating func due(ptsNs: UInt64, arrival: Double) -> Double {
        if let lastPTS {
            let step = ptsNs >= lastPTS ? Double(ptsNs - lastPTS) / 1e9 : -1
            if step < 0 || step > 2 {
                media += max(0, arrival - lastArrival); bestTrip = nil; windowBest = nil
            } else { media += step }
        }
        lastPTS = ptsNs; lastArrival = arrival
        let trip = arrival - media
        bestTrip = min(bestTrip ?? trip, trip); windowBest = min(windowBest ?? trip, trip)
        if arrival - windowStart >= 5 {
            bestTrip = windowBest; windowBest = trip; windowStart = arrival
        }
        let due = max(media + bestTrip! + 0.1, arrival, lastDue)
        lastDue = due; return due
    }
}

/// Decoded buffers only: dropping an entry here never drops a decoder reference.
/// Immediate mode retains one newest buffer; smoothing retains at most eight.
public struct VideoPresentationQueue<Element> {
    private struct Entry { let seq: UInt64; let due: Double; let value: Element }
    private var entries: [Entry] = []
    private var newest: UInt64?
    private var clock = VideoPlayoutClock()
    public private(set) var smooth = false
    public var nextDue: Double? { entries.first?.due }
    public var count: Int { entries.count }
    public init() {}
    @discardableResult public mutating func clear() -> Int {
        let count = entries.count; entries.removeAll(); newest = nil; clock = VideoPlayoutClock(); return count
    }
    @discardableResult public mutating func setSmoothing(_ enabled: Bool) -> Int {
        guard enabled != smooth else { return 0 }
        let skipped = entries.count; entries.removeAll(); clock = VideoPlayoutClock(); smooth = enabled
        return skipped
    }
    /// Returns the number of superseded/stale decoded buffers.
    @discardableResult public mutating func offer(_ value: Element, seq: UInt64, ptsNs: UInt64, arrival: Double, now: Double) -> Int {
        if let newest, seq <= newest { return 1 }
        newest = seq
        let due = smooth ? clock.due(ptsNs: ptsNs, arrival: arrival) : now
        var skipped = 0
        if !smooth { skipped = entries.count; entries.removeAll() }
        entries.append(Entry(seq: seq, due: due, value: value))
        if entries.count > 8 { entries.removeFirst(); skipped += 1 }
        return skipped
    }
    /// When several images are due, show the newest once, never replay a burst.
    public mutating func takeReady(now: Double) -> (value: Element?, skipped: Int) {
        let count = entries.prefix { $0.due <= now }.count
        guard count > 0 else { return (nil, 0) }
        let latest = entries[count - 1].value
        entries.removeFirst(count); return (latest, count - 1)
    }
}

/// Counts actual layer enqueues over elapsed time, including a partial final second.
public struct VideoFrameRate {
    private var time: Double
    private var total = 0
    public init(now: Double) { time = now }
    public mutating func sample(total: Int, now: Double) -> Double {
        guard now > time else { return 0 }
        defer { self.total = total; time = now }
        return Double(total - self.total) / (now - time)
    }
}

/// A config repeat/recreate never resizes a window. Geometry changes do it once.
public struct VideoWindowGeometry: Equatable {
    public let width: Int, height: Int
    public let orientation: UInt8
    public let rotationDegrees: UInt16
    public init(width: Int, height: Int, orientation: UInt8, rotationDegrees: UInt16 = 0) {
        self.width = width; self.height = height; self.orientation = orientation
        self.rotationDegrees = rotationDegrees
    }
    public var swapsAxes: Bool { (5...8).contains(orientation) != (rotationDegrees == 90 || rotationDegrees == 270) }
    public var aspect: Double {
        swapsAxes ? Double(height) / Double(width) : Double(width) / Double(height)
    }
}

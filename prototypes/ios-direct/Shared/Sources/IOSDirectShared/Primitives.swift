import Foundation

public struct Dimensions: Codable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    /// Rounding down to even pixels introduces less than two pixels of aspect error.
    public static func fit(width: Int, height: Int) -> Dimensions? {
        guard width >= 2, height >= 2 else { return nil }
        let portrait = height > width
        let scale = min(1, min(Double(portrait ? 720 : 1280) / Double(width),
                               Double(portrait ? 1280 : 720) / Double(height)))
        return Dimensions(width: max(2, Int(Double(width) * scale) / 2 * 2),
                          height: max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

public struct FramePacer {
    private let interval: Double
    private var next: Double?
    public init(fps: Double = 30) { precondition(fps > 0); interval = 1 / fps }
    public mutating func accept(pts: Double) -> Bool {
        guard pts.isFinite else { return false }
        guard let next else {
            next = pts + interval
            return true
        }
        guard pts >= next - 0.001 else { return false }
        self.next = max(next + interval, pts)
        return true
    }
}

/// Monotonic deadlines; successful output (not just session creation) resets retries.
public struct EncoderBackoff {
    public private(set) var retryAfter: Double = 0
    private var nextDelay: Double = 0.25
    public init() {}
    public func canAttempt(now: Double) -> Bool { now >= retryAfter }
    @discardableResult public mutating func failed(now: Double) -> Double {
        let delay = nextDelay
        retryAfter = now + delay
        nextDelay = min(2, nextDelay * 2)
        return delay
    }
    public mutating func reset() { self = EncoderBackoff() }
}

/// Caller owns synchronization. Admission and dequeue both expire old entries.
/// Payloads never enter a dispatch backlog outside this bounded container.
public struct BoundedQueue<Element> {
    private struct Entry { let value: Element; let bytes: Int; let time: Double }
    private var entries: [Entry] = []
    public let maxBytes: Int
    public let maxAge: Double
    public private(set) var bytes = 0
    public private(set) var drops = 0
    public var count: Int { entries.count }
    public init(maxBytes: Int = 1_048_576, maxAge: Double = 0.1) {
        precondition(maxBytes > 0 && maxAge > 0)
        self.maxBytes = maxBytes; self.maxAge = maxAge
    }
    public func age(now: Double) -> Double { entries.first.map { max(0, now - $0.time) } ?? 0 }
    public mutating func expire(now: Double) {
        while let first = entries.first, now - first.time >= maxAge {
            bytes -= entries.removeFirst().bytes; drops += 1
        }
    }
    @discardableResult public mutating func enqueue(_ value: Element, bytes size: Int, now: Double) -> Bool {
        expire(now: now)
        guard size >= 0, size <= maxBytes - bytes else { drops += 1; return false }
        entries.append(Entry(value: value, bytes: size, time: now)); bytes += size
        return true
    }
    public mutating func dequeue(now: Double) -> Element? {
        expire(now: now)
        guard !entries.isEmpty else { return nil }
        let first = entries.removeFirst(); bytes -= first.bytes
        return first.value
    }
    public mutating func removeAll() { entries.removeAll(); bytes = 0 }
}

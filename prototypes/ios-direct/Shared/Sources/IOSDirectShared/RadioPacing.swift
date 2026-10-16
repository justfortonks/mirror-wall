import Foundation

public func radioNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// No catch-up bursts. Caller owns the ACK map; admission includes wire overhead.
public struct RadioPacer {
    public let bytesPerSecond: Double
    public let cap: Int
    public let chunk: Int
    private var next: Double = 0
    private var blockedSince: Double?
    private var blocked: Double = 0
    public init(mbit: Int) {
        precondition([2, 6, 12, 24].contains(mbit))
        bytesPerSecond = Double(mbit) * 1_000_000 / 8
        cap = min(150_000, Int(bytesPerSecond * 0.1))
        chunk = min(16_384, cap - 30, RadioFrame.maxData)
    }
    public mutating func canSend(now: Double, outstanding: Int, sending: Bool) -> Bool {
        let capped = outstanding + chunk + 30 > cap || sending
        if capped { if blockedSince == nil { blockedSince = max(now, next) } }
        else if let start = blockedSince { blocked += max(0, now - start); blockedSince = nil }
        return !capped && now >= next
    }
    public func delay(now: Double) -> Double { max(0, next - now) }
    public mutating func sent(now: Double, payloadBytes: Int) {
        next = max(next, now) + Double(payloadBytes) / bytesPerSecond
    }
    public func blockedMS(now: Double) -> Double { (blocked + (blockedSince.map { max(0, now - $0) } ?? 0)) * 1000 }
}

public struct RadioRTT {
    private var samples: [(Double, Double)] = []
    public init() {}
    public mutating func add(milliseconds: Double, now: Double) {
        samples.append((now, milliseconds)); prune(now: now)
    }
    private mutating func prune(now: Double) { samples.removeAll { now - $0.0 > 10 }; if samples.count > 100 { samples.removeFirst(samples.count - 100) } }
    public mutating func values(now: Double) -> (Double?, Double?) {
        prune(now: now); let sorted = samples.map(\.1).sorted()
        guard !sorted.isEmpty else { return (nil, nil) }
        return ((sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2,
                sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)])
    }
}

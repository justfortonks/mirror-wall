import Foundation

public func radioNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

public enum RadioWindowMode: String, Codable, CaseIterable {
    case latency, capacityProbe
    public var label: String { self == .latency ? "Latency" : "Capacity probe" }
    public func bytes(mbit: Int) -> Int {
        self == .latency ? min(150_000, mbit * 12_500) : 2 * 1_048_576
    }
}

/// Payload-rate deadlines retain up to max(one packet interval, 10 ms) of lateness credit.
/// Actual backpressure discards credit. ACK-window admission includes wire overhead.
public struct RadioPacer {
    public static let rates = [2, 6, 12, 24, 36, 48]
    public let bytesPerSecond: Double
    public let cap: Int
    public let chunk: Int
    private var next: Double = 0
    private var blockedSince: Double?
    private var blocked: Double = 0
    public init(mbit: Int, window: RadioWindowMode = .latency) {
        precondition(Self.rates.contains(mbit))
        bytesPerSecond = Double(mbit) * 1_000_000 / 8
        cap = window.bytes(mbit: mbit)
        chunk = min(16_384, cap - 30, RadioFrame.maxData)
    }
    public mutating func canSend(now: Double, outstanding: Int, sending: Bool) -> Bool {
        let capped = outstanding + chunk + 30 > cap || sending
        if capped { if blockedSince == nil { blockedSince = max(now, next) } }
        else if let start = blockedSince {
            blocked += max(0, now - start); blockedSince = nil
            if now > start { next = max(next, now) }
        }
        return !capped && now >= next
    }
    public func delay(now: Double) -> Double { max(0, next - now) }
    public mutating func sent(now: Double, payloadBytes: Int) {
        let interval = Double(payloadBytes) / bytesPerSecond
        let creditLimit = max(interval, 0.010)
        // Clamp the old deadline to now - creditLimit, then charge this packet.
        // This form avoids subtracting and re-adding the same interval at low rates.
        next = next == 0 ? now + interval : max(next + interval, now - (creditLimit - interval))
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

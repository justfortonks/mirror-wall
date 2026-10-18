import Foundation

public enum StreamPreset: String, Codable, CaseIterable {
    case standard = "Standard", high = "High", native = "Native"
    public var targetBitrate: Int {
        switch self { case .standard: return 6_000_000; case .high: return 12_000_000; case .native: return 20_000_000 }
    }
    public var portraitBox: Dimensions? {
        switch self {
        case .standard: return Dimensions(width: 720, height: 1280)
        case .high: return Dimensions(width: 1080, height: 2400)
        case .native: return nil
        }
    }
    var wireID: UInt8 { switch self { case .standard: return 0; case .high: return 1; case .native: return 2 } }
    init(wireID: UInt8) throws {
        switch wireID {
        case 0: self = .standard
        case 1: self = .high
        case 2: self = .native
        default: throw RadioError.protocolViolation("unknown stream preset")
        }
    }
    public func output(width: Int, height: Int) -> Dimensions? {
        Dimensions.fit(width: width, height: height, portraitBox: portraitBox)
    }
}

public struct StreamSettings: Equatable, Codable {
    public let preset: StreamPreset
    public let sixtyFPS: Bool
    public var fps: Int { sixtyFPS ? 60 : 30 }
    public var targetBitrate: Int { preset.targetBitrate }
    public var latencyWindowBytes: Int { min(150_000, targetBitrate / 80) }
    public init(preset: StreamPreset = .standard, sixtyFPS: Bool = false) {
        self.preset = preset; self.sixtyFPS = sixtyFPS
    }
}

public struct Dimensions: Codable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    /// Rounding down to even pixels introduces less than two pixels of aspect error.
    public static func fit(width: Int, height: Int,
                           portraitBox: Dimensions? = Dimensions(width: 720, height: 1280)) -> Dimensions? {
        guard width >= 2, height >= 2 else { return nil }
        let portrait = height > width
        if let portraitBox, portraitBox.width < 2 || portraitBox.height < 2 { return nil }
        let box = portraitBox ?? Dimensions(width: width, height: height)
        let scale = portraitBox == nil ? 1 : min(1, min(Double(portrait ? box.width : box.height) / Double(width),
                               Double(portrait ? box.height : box.width) / Double(height)))
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

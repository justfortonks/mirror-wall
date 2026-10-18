import Foundation

public enum RadioMode: String, Codable { case synthetic, video }
public enum VideoDecodeStatus: UInt8 { case decoded = 0, dropped = 1, decodeError = 2 }
public struct VideoRect: Equatable, Codable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
public struct VideoConfig: Equatable {
    public let generation: UInt32
    public let width: UInt16, height: UInt16
    /// Raw SCStreamFrameInfo.videoOrientation (CGImagePropertyOrientation); pixels are not rotated here.
    public let orientation: UInt8
    public let contentRect: VideoRect?
    public let streamSettings: StreamSettings?
    public let avcC: Data
    public init(generation: UInt32, width: UInt16, height: UInt16, orientation: UInt8,
                contentRect: VideoRect? = nil, streamSettings: StreamSettings? = nil, avcC: Data) {
        self.generation = generation; self.width = width; self.height = height
        self.orientation = orientation; self.contentRect = contentRect; self.avcC = avcC
        self.streamSettings = streamSettings
    }
    public func withGeneration(_ generation: UInt32) -> VideoConfig {
        VideoConfig(generation: generation, width: width, height: height, orientation: orientation,
                    contentRect: contentRect, streamSettings: streamSettings, avcC: avcC)
    }
    /// Parse AVCDecoderConfigurationRecord without trusting its length fields. High-profile
    /// extension bytes may follow PPS; VideoToolbox only needs the SPS/PPS parameter sets.
    public func parameterSets() throws -> [Data] {
        guard width >= 2, height >= 2, width <= 4096, height <= 4096,
              (1...8).contains(orientation), avcC.count >= 7, avcC[0] == 1, avcC[4] & 3 == 3 else {
            throw RadioError.protocolViolation("invalid video config / NAL length size")
        }
        var offset = 6, sets = [Data]()
        func readSets(_ count: Int, type: UInt8) throws {
            guard count > 0 else { throw RadioError.protocolViolation("missing parameter sets") }
            for _ in 0..<count {
                guard offset + 2 <= avcC.count else { throw RadioError.protocolViolation("short avcC") }
                let size: UInt16 = avcC.integer(at: offset); offset += 2
                guard size > 0, offset + Int(size) <= avcC.count, avcC[offset] & 31 == type else {
                    throw RadioError.protocolViolation("invalid parameter set")
                }
                sets.append(Data(avcC[offset..<offset + Int(size)])); offset += Int(size)
            }
        }
        try readSets(Int(avcC[5] & 31), type: 7)
        guard offset < avcC.count else { throw RadioError.protocolViolation("missing PPS count") }
        let count = Int(avcC[offset]); offset += 1
        try readSets(count, type: 8)
        return sets
    }
    func body() throws -> Data {
        _ = try parameterSets()
        var b = Data(); b.put(generation); b.put(width); b.put(height); b.put(orientation)
        b.put(UInt8((contentRect == nil ? 0 : 1) | (streamSettings == nil ? 0 : 2)))
        if let rect = contentRect {
            for value in [rect.x, rect.y, rect.width, rect.height] {
                guard value.isFinite else { throw RadioError.protocolViolation("invalid content rect") }
                b.put(value.bitPattern)
            }
        }
        if let settings = streamSettings {
            b.put(settings.preset.wireID); b.put(UInt8(settings.fps)); b.put(UInt32(settings.targetBitrate))
        }
        b.append(avcC); return b
    }
    init(_ data: Data) throws {
        var r = BodyReader(data: data)
        let generation: UInt32 = try r.number(), width: UInt16 = try r.number(), height: UInt16 = try r.number()
        let orientation: UInt8 = try r.number(), present: UInt8 = try r.number()
        guard present <= 3 else { throw RadioError.protocolViolation("invalid config flags") }
        var rect: VideoRect?
        if present & 1 != 0 {
            var values = [Double]()
            for _ in 0..<4 {
                let bits: UInt64 = try r.number(), value = Double(bitPattern: bits)
                guard value.isFinite else { throw RadioError.protocolViolation("invalid content rect") }
                values.append(value)
            }
            rect = VideoRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        var settings: StreamSettings?
        if present & 2 != 0 {
            let preset = try StreamPreset(wireID: r.number())
            let fps: UInt8 = try r.number(), bitrate: UInt32 = try r.number()
            guard (fps == 30 || fps == 60), bitrate == UInt32(preset.targetBitrate) else {
                throw RadioError.protocolViolation("invalid stream settings")
            }
            settings = StreamSettings(preset: preset, sixtyFPS: fps == 60)
        }
        self.init(generation: generation, width: width, height: height, orientation: orientation,
                  contentRect: rect, streamSettings: settings, avcC: Data(data.dropFirst(r.offset)))
        _ = try parameterSets()
    }
}

public struct VideoAccessUnit: Equatable {
    public let generation: UInt32, seq: UInt64, ptsNs: UInt64
    public let keyframe: Bool
    public let data: Data
    public init(generation: UInt32, seq: UInt64, ptsNs: UInt64, keyframe: Bool, data: Data) {
        self.generation = generation; self.seq = seq; self.ptsNs = ptsNs; self.keyframe = keyframe; self.data = data
    }
    public var wireBytes: Int { data.count + ((data.count + VideoFragment.maxData - 1) / VideoFragment.maxData) * 39 }
    public func fragments() throws -> [VideoFragment] {
        guard !data.isEmpty, data.count <= VideoFragment.maxFrame else { throw RadioError.protocolViolation("oversize/empty frame") }
        let count = (data.count + VideoFragment.maxData - 1) / VideoFragment.maxData
        return (0..<count).map { index in
            let start = index * VideoFragment.maxData
            return VideoFragment(generation: generation, seq: seq, ptsNs: ptsNs, keyframe: keyframe,
                index: UInt16(index), count: UInt16(count), total: UInt32(data.count),
                data: Data(data[start..<min(data.count, start + VideoFragment.maxData)]))
        }
    }
}
public struct VideoFragment: Equatable {
    public static let maxFrame = 4 * 1_048_576
    public static let maxData = min(RadioFrame.maxData, RadioFrame.maxBody - 29)
    public let generation: UInt32, seq: UInt64, ptsNs: UInt64
    public let keyframe: Bool
    public let index: UInt16, count: UInt16
    public let total: UInt32
    public let data: Data
    public init(generation: UInt32, seq: UInt64, ptsNs: UInt64, keyframe: Bool,
                index: UInt16, count: UInt16, total: UInt32, data: Data) {
        self.generation = generation; self.seq = seq; self.ptsNs = ptsNs; self.keyframe = keyframe
        self.index = index; self.count = count; self.total = total; self.data = data
    }
    func validate() throws {
        guard total > 0, total <= UInt32(Self.maxFrame) else { throw RadioError.protocolViolation("oversize/empty frame total") }
        guard count > 0, Int(count) <= Int(total), index < count, !data.isEmpty,
              data.count <= Self.maxData, data.count <= Int(total) else { throw RadioError.protocolViolation("invalid fragment") }
    }
    func body() throws -> Data {
        try validate()
        var b = Data(); b.put(generation); b.put(seq); b.put(ptsNs); b.put(UInt8(keyframe ? 1 : 0))
        b.put(index); b.put(count); b.put(total); b.append(data); return b
    }
    init(_ data: Data) throws {
        var r = BodyReader(data: data)
        let generation: UInt32 = try r.number(), seq: UInt64 = try r.number(), pts: UInt64 = try r.number()
        let flags: UInt8 = try r.number(), index: UInt16 = try r.number(), count: UInt16 = try r.number(), total: UInt32 = try r.number()
        guard flags <= 1 else { throw RadioError.protocolViolation("invalid video flags") }
        self.init(generation: generation, seq: seq, ptsNs: pts, keyframe: flags == 1,
                  index: index, count: count, total: total, data: Data(data.dropFirst(r.offset)))
        try validate()
    }
}

public enum VideoAssemblyEvent: Equatable {
    case frame(VideoAccessUnit)
    case dropped(seq: UInt64, ptsNs: UInt64, reason: String)
}
/// One frame only. A replaced/missing/out-of-order frame is forgotten and reported once;
/// the caller ACKs dropped frames and requests an IDR. No partial frame is decoded.
public struct VideoReassembler {
    private var first: VideoFragment?
    private var next: UInt16 = 0
    private var bytes = Data()
    private var started: Double = 0
    private var highest: UInt64?
    public var bufferedBytes: Int { bytes.count }
    public var framesInProgress: Int { first == nil ? 0 : 1 }
    public init() {}
    public mutating func reset() { self = VideoReassembler() }
    public mutating func abandon(_ reason: String) -> [VideoAssemblyEvent] {
        guard let first else { return [] }
        self.first = nil; bytes = Data(); next = 0
        return [.dropped(seq: first.seq, ptsNs: first.ptsNs, reason: reason)]
    }
    public mutating func expire(now: Double) -> [VideoAssemblyEvent] {
        first != nil && now - started >= 1 ? abandon("fragment timeout") : []
    }
    public mutating func accept(_ f: VideoFragment, now: Double) throws -> [VideoAssemblyEvent] {
        try f.validate() // Reject total >4 MiB before reserving/appending anything.
        var events = expire(now: now)
        if let old = first, old.seq != f.seq {
            events += abandon("missing fragment / replaced frame")
        }
        if first == nil {
            // Consume the rest of an already dropped frame without duplicate ACKs.
            if let highest, f.seq <= highest { return events }
            highest = f.seq
            guard f.index == 0 else { return events + [.dropped(seq: f.seq, ptsNs: f.ptsNs, reason: "missing first fragment")] }
            first = f; next = 0; started = now
        }
        guard let first, f.generation == first.generation, f.ptsNs == first.ptsNs,
              f.keyframe == first.keyframe, f.count == first.count, f.total == first.total,
              f.index == next, bytes.count + f.data.count <= Int(first.total) else {
            return events + abandon("out-of-order / inconsistent fragment")
        }
        bytes.append(f.data); next += 1
        if next == first.count {
            guard bytes.count == Int(first.total) else { return events + abandon("missing fragment bytes") }
            let frame = VideoAccessUnit(generation: first.generation, seq: first.seq, ptsNs: first.ptsNs, keyframe: first.keyframe, data: bytes)
            self.first = nil; bytes = Data(); next = 0
            events.append(.frame(frame))
        }
        return events
    }
}

/// The actual network sink uses this policy under its admission lock. Dispatch closures
/// carry no media. Losing any encoded unit invalidates the queued prediction chain.
public struct VideoSendQueue {
    private struct Entry { let frame: VideoAccessUnit; let time: Double }
    private var entries: [Entry] = []
    public private(set) var bytes = 0
    public private(set) var waitingForKeyframe = true
    public private(set) var drops: [String: Int] = [:]
    public var count: Int { entries.count }
    public init() {}
    public func age(now: Double) -> Double { entries.first.map { max(0, now - $0.time) } ?? 0 }
    public mutating func discontinuity(_ reason: String) {
        drops[reason, default: 0] += entries.count
        entries.removeAll(); bytes = 0; waitingForKeyframe = true
    }
    public mutating func expire(now: Double) {
        if age(now: now) >= 0.1 { discontinuity("queueAge") }
    }
    @discardableResult public mutating func offer(_ frame: VideoAccessUnit, now: Double) -> Bool {
        expire(now: now)
        guard !frame.data.isEmpty, frame.data.count <= VideoFragment.maxFrame else {
            discontinuity("oversize"); drops["oversize", default: 0] += 1; return false
        }
        if bytes + frame.data.count > VideoFragment.maxFrame {
            discontinuity("queueBytes"); drops["queueBytes", default: 0] += 1; return false
        }
        if waitingForKeyframe && !frame.keyframe { drops["awaitingIDR", default: 0] += 1; return false }
        if frame.keyframe { waitingForKeyframe = false }
        entries.append(Entry(frame: frame, time: now)); bytes += frame.data.count; return true
    }
    public func peek() -> VideoAccessUnit? { entries.first?.frame }
    public mutating func pop(now: Double) -> VideoAccessUnit? {
        expire(now: now)
        guard !entries.isEmpty else { return nil }
        let first = entries.removeFirst(); bytes -= first.frame.data.count; return first.frame
    }
}

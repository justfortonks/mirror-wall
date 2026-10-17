import Foundation

public enum RadioError: Error, Equatable, CustomStringConvertible {
    case protocolViolation(String)
    public var description: String { switch self { case .protocolViolation(let reason): return reason } }
}

public enum RadioType: UInt8, CaseIterable {
    case hello = 1, welcome, reject, data, ack, ping, pong, stats, bye
    case videoConfig, videoFragment, keyframeRequest, videoAck
    case authChallenge, authResponse, pairRequest, pairGrant, pairDone, pairDenied
    case orientationHint // 20; append to preserve all existing wire IDs
}

public struct RadioFrame: Equatable {
    public static let headerSize = 10
    public static let maxBody = 65_536
    public static let maxData = maxBody - 20
    public let version: UInt8
    public let type: RadioType
    public let body: Data
    public init(_ type: RadioType, _ body: Data = Data(), version: UInt8 = 3) {
        self.version = version; self.type = type; self.body = body
    }
    public func encoded() throws -> Data {
        guard body.count <= Self.maxBody else { throw RadioError.protocolViolation("oversize length") }
        guard version == 1 || version == 2 || version == 3 else { throw RadioError.protocolViolation("bad version") }
        var result = Data([0x4d, 0x57, 0x50, 0x44, version, type.rawValue])
        result.put(UInt32(body.count)); result.append(body); return result
    }
}

/// Retains only one header/body. Validates length before appending any body bytes.
/// A terminal error poisons the parser; caller must close the connection.
public struct RadioParser {
    private var header = Data()
    private var body = Data()
    private var expected: Int?
    private var type: RadioType?
    private var failed = false
    public var bufferedBytes: Int { header.count + body.count }
    public init() {}
    public mutating func feed(_ bytes: Data, onFrame: (RadioFrame) throws -> Void) throws {
        guard !failed else { throw RadioError.protocolViolation("parser already failed") }
        do {
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                if expected == nil {
                    let count = min(10 - header.count, bytes.endIndex - offset)
                    header.append(bytes[offset..<offset + count]); offset += count
                    guard header.count == 10 else { continue }
                    guard header.prefix(4) == Data("MWPD".utf8) else { throw RadioError.protocolViolation("bad magic") }
                    guard header[4] == 1 || header[4] == 2 || header[4] == 3 else { throw RadioError.protocolViolation("bad version") }
                    guard let parsed = RadioType(rawValue: header[5]) else { throw RadioError.protocolViolation("unknown type") }
                    let length: UInt32 = header.integer(at: 6)
                    guard length <= RadioFrame.maxBody else { throw RadioError.protocolViolation("oversize length") }
                    type = parsed; expected = Int(length)
                }
                let count = min(expected! - body.count, bytes.endIndex - offset)
                body.append(bytes[offset..<offset + count]); offset += count
                if body.count == expected! {
                    let frame = RadioFrame(type!, body, version: header[4])
                    header.removeAll(keepingCapacity: true); body = Data(); expected = nil; type = nil
                    try onFrame(frame)
                }
            }
        } catch { failed = true; throw error }
    }
    public mutating func finish() throws {
        guard !failed, bufferedBytes == 0 else { failed = true; throw RadioError.protocolViolation("EOF mid-message") }
    }
}

extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        // Byte-wise access avoids alignment assumptions and handles Data slices.
        (0..<MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T(self[startIndex + offset + $1]) }
    }
}

struct BodyReader {
    let data: Data
    var offset = 0
    mutating func number<T: FixedWidthInteger>() throws -> T {
        guard offset + MemoryLayout<T>.size <= data.count else { throw RadioError.protocolViolation("short body") }
        defer { offset += MemoryLayout<T>.size }; return data.integer(at: offset)
    }
    mutating func text() throws -> String {
        let count: UInt16 = try number()
        guard count <= 256, offset + Int(count) <= data.count,
              let text = String(data: data.dropFirst(offset).prefix(Int(count)), encoding: .utf8) else {
            throw RadioError.protocolViolation("invalid text")
        }
        offset += Int(count); return text
    }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count <= data.count - offset else { throw RadioError.protocolViolation("short body") }
        defer { offset += count }; return Data(data.dropFirst(offset).prefix(count))
    }
    func end() throws { guard offset == data.count else { throw RadioError.protocolViolation("trailing body bytes") } }
}
extension Data {
    mutating func text(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 256 else { throw RadioError.protocolViolation("text too long") }
        put(UInt16(bytes.count)); append(bytes)
    }
}

public enum RadioMessage: Equatable {
    case authChallenge(Data)
    case authResponse(String, Data)
    case pairRequest(install: UUID, label: String, model: String)
    case pairGrant(DeviceCredential)
    case pairDone, pairDenied
    case hello(install: UUID, label: String, version: UInt8, rate: UInt32, window: RadioWindowMode = .latency, mode: RadioMode = .synthetic)
    case welcome(session: UUID, label: String)
    case reject(String)
    case data(seq: UInt64, time: UInt64, payload: Data, crc: UInt32)
    case ack(seq: UInt64, time: UInt64, total: UInt64)
    case ping(UInt64), pong(UInt64)
    case stats(Data)
    case bye(String)

    case orientationHint(OrientationHint)
    case videoConfig(VideoConfig)
    case videoFragment(VideoFragment)
    case keyframeRequest(String)
    case videoAck(seq: UInt64, ptsNs: UInt64, status: VideoDecodeStatus)

    public func frame(version wireVersion: UInt8? = nil) throws -> RadioFrame {
        var version: UInt8 = wireVersion ?? 3
        var b = Data(); let type: RadioType
        switch self {
        case .authChallenge(let nonce):
            guard nonce.count == 32 else { throw RadioError.protocolViolation("invalid nonce") }
            type = .authChallenge; b = nonce
        case let .authResponse(identity, proof):
            guard proof.count == 32 else { throw RadioError.protocolViolation("invalid proof") }
            type = .authResponse; try b.text(identity); b.append(proof)
        case let .pairRequest(install, label, model):
            type = .pairRequest; try b.text(install.uuidString); try b.text(label); try b.text(model)
        case .pairGrant(let credential):
            guard credential.deviceKey.count == 32 else { throw RadioError.protocolViolation("invalid key") }
            type = .pairGrant; try b.text(credential.deviceID.uuidString); b.append(credential.deviceKey)
            try b.text(credential.rid.uuidString); try b.text(credential.receiverName)
        case .pairDone: type = .pairDone
        case .pairDenied: type = .pairDenied
        case let .hello(install, label, helloVersion, rate, window, mode):
            version = helloVersion
            type = .hello; try b.text(install.uuidString); try b.text(label); b.put(helloVersion); b.put(rate)
            b.put(UInt8(window == .latency ? 0 : 1))
            if helloVersion >= 2 { try b.text(mode.rawValue) }
        case let .welcome(session, label): type = .welcome; try b.text(session.uuidString); try b.text(label)
        case .reject(let reason): type = .reject; try b.text(reason)
        case let .data(seq, time, payload, crc):
            type = .data; b.put(seq); b.put(time); b.append(payload); b.put(crc)
        case let .ack(seq, time, total): type = .ack; b.put(seq); b.put(time); b.put(total)
        case .ping(let echo): type = .ping; b.put(echo)
        case .pong(let echo): type = .pong; b.put(echo)
        case .stats(let json): type = .stats; b = json
        case .bye(let reason): type = .bye; try b.text(reason)
        case .orientationHint(let hint):
            guard version == 3 else { throw RadioError.protocolViolation("orientation hint requires v3") }
            try hint.validate(); type = .orientationHint
            b.put(hint.degrees); b.put(hint.source.rawValue); b.put(hint.monotonicNs)
        case .videoConfig(let config): type = .videoConfig; version = wireVersion ?? 3; b = try config.body()
        case .videoFragment(let fragment): type = .videoFragment; version = wireVersion ?? 3; b = try fragment.body()
        case .keyframeRequest(let reason): type = .keyframeRequest; version = wireVersion ?? 3; try b.text(reason)
        case let .videoAck(seq, ptsNs, status):
            type = .videoAck; version = wireVersion ?? 3; b.put(seq); b.put(ptsNs); b.put(status.rawValue)
        }
        guard b.count <= RadioFrame.maxBody else { throw RadioError.protocolViolation("oversize length") }
        return RadioFrame(type, b, version: version)
    }
    public init(_ frame: RadioFrame) throws {
        var r = BodyReader(data: frame.body)
        if (10...13).contains(frame.type.rawValue), frame.version < 2 {
            throw RadioError.protocolViolation("video requires v2")
        }
        if frame.type.rawValue >= 14, frame.version != 3 { throw RadioError.protocolViolation("control requires v3") }
        switch frame.type {
        case .authChallenge: self = .authChallenge(try r.bytes(32))
        case .authResponse: self = .authResponse(try r.text(), try r.bytes(32))
        case .pairRequest:
            guard let id = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad install UUID") }
            self = .pairRequest(install: id, label: try r.text(), model: try r.text())
        case .pairGrant:
            guard let id = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad device UUID") }
            let key = try r.bytes(32)
            guard let rid = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad receiver UUID") }
            self = .pairGrant(DeviceCredential(deviceID: id, deviceKey: key, rid: rid, receiverName: try r.text()))
        case .pairDone: self = .pairDone
        case .pairDenied: self = .pairDenied
        case .hello:
            guard let id = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad install UUID") }
            let label = try r.text(), version: UInt8 = try r.number(), rate: UInt32 = try r.number()
            // Original G2 hello has no window byte and always uses latency mode.
            let raw: UInt8
            if r.offset == frame.body.count { raw = 0 } else { raw = try r.number() }
            let window: RadioWindowMode
            switch raw {
            case 0: window = .latency
            case 1: window = .capacityProbe
            default: throw RadioError.protocolViolation("invalid window")
            }
            guard version == frame.version else { throw RadioError.protocolViolation("hello framing mismatch") }
            let mode: RadioMode
            if version >= 2 {
                guard let parsed = RadioMode(rawValue: try r.text()) else { throw RadioError.protocolViolation("invalid mode") }
                mode = parsed
            } else { mode = .synthetic }
            self = .hello(install: id, label: label, version: version, rate: rate, window: window, mode: mode)
        case .welcome:
            guard let id = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad session UUID") }
            self = .welcome(session: id, label: try r.text())
        case .reject: self = .reject(try r.text())
        case .data:
            guard frame.body.count >= 20 else { throw RadioError.protocolViolation("short data") }
            let seq: UInt64 = try r.number(), time: UInt64 = try r.number()
            let payload = Data(frame.body.dropFirst(16).dropLast(4))
            let crc: UInt32 = frame.body.integer(at: frame.body.count - 4)
            self = .data(seq: seq, time: time, payload: payload, crc: crc); r.offset = frame.body.count
        case .ack: self = .ack(seq: try r.number(), time: try r.number(), total: try r.number())
        case .ping: self = .ping(try r.number())
        case .pong: self = .pong(try r.number())
        case .stats:
            guard frame.body.count <= 8192, (try? JSONSerialization.jsonObject(with: frame.body)) != nil else {
                throw RadioError.protocolViolation("invalid stats JSON")
            }
            self = .stats(frame.body); r.offset = frame.body.count
        case .bye: self = .bye(try r.text())
        case .orientationHint:
            let degrees: UInt16 = try r.number(), raw: UInt8 = try r.number(), time: UInt64 = try r.number()
            guard let source = OrientationSource(rawValue: raw) else { throw RadioError.protocolViolation("invalid orientation source") }
            let hint = OrientationHint(degrees: degrees, source: source, monotonicNs: time)
            try hint.validate(); self = .orientationHint(hint)
        case .videoConfig: self = .videoConfig(try VideoConfig(frame.body)); r.offset = frame.body.count
        case .videoFragment: self = .videoFragment(try VideoFragment(frame.body)); r.offset = frame.body.count
        case .keyframeRequest: self = .keyframeRequest(try r.text())
        case .videoAck:
            let seq: UInt64 = try r.number(), pts: UInt64 = try r.number(), raw: UInt8 = try r.number()
            guard let status = VideoDecodeStatus(rawValue: raw) else { throw RadioError.protocolViolation("bad decode status") }
            self = .videoAck(seq: seq, ptsNs: pts, status: status)
        }
        try r.end()
    }
}

public enum RadioCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { c, _ in (c >> 1) ^ ((c & 1) != 0 ? 0xedb88320 : 0) }
    }
    public static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32.max) { ($0 >> 8) ^ table[Int(($0 ^ UInt32($1)) & 255)] } ^ UInt32.max
    }
}
public enum SyntheticPayload {
    /// Byte i = (sequence + i) mod 256; no screen/capture input exists here.
    public static func make(seq: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: seq &+ UInt64($0)) })
    }
}

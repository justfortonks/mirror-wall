import Foundation

public enum RadioError: Error, Equatable, CustomStringConvertible {
    case protocolViolation(String)
    public var description: String { switch self { case .protocolViolation(let reason): return reason } }
}

public enum RadioType: UInt8, CaseIterable {
    case hello = 1, welcome, reject, data, ack, ping, pong, stats, bye
}

public struct RadioFrame: Equatable {
    public static let headerSize = 10
    public static let maxBody = 65_536
    public static let maxData = maxBody - 20
    public let type: RadioType
    public let body: Data
    public init(_ type: RadioType, _ body: Data = Data()) { self.type = type; self.body = body }
    public func encoded() throws -> Data {
        guard body.count <= Self.maxBody else { throw RadioError.protocolViolation("oversize length") }
        var result = Data([0x4d, 0x57, 0x50, 0x44, 1, type.rawValue])
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
                    guard header[4] == 1 else { throw RadioError.protocolViolation("bad version") }
                    guard let parsed = RadioType(rawValue: header[5]) else { throw RadioError.protocolViolation("unknown type") }
                    let length: UInt32 = header.integer(at: 6)
                    guard length <= RadioFrame.maxBody else { throw RadioError.protocolViolation("oversize length") }
                    type = parsed; expected = Int(length)
                }
                let count = min(expected! - body.count, bytes.endIndex - offset)
                body.append(bytes[offset..<offset + count]); offset += count
                if body.count == expected! {
                    let frame = RadioFrame(type!, body)
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

private struct BodyReader {
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
    func end() throws { guard offset == data.count else { throw RadioError.protocolViolation("trailing body bytes") } }
}
private extension Data {
    mutating func text(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 256 else { throw RadioError.protocolViolation("text too long") }
        put(UInt16(bytes.count)); append(bytes)
    }
}

public enum RadioMessage: Equatable {
    case hello(install: UUID, label: String, version: UInt8, rate: UInt32)
    case welcome(session: UUID, label: String)
    case reject(String)
    case data(seq: UInt64, time: UInt64, payload: Data, crc: UInt32)
    case ack(seq: UInt64, time: UInt64, total: UInt64)
    case ping(UInt64), pong(UInt64)
    case stats(Data)
    case bye(String)

    public func frame() throws -> RadioFrame {
        var b = Data(); let type: RadioType
        switch self {
        case let .hello(install, label, version, rate):
            type = .hello; try b.text(install.uuidString); try b.text(label); b.put(version); b.put(rate)
        case let .welcome(session, label): type = .welcome; try b.text(session.uuidString); try b.text(label)
        case .reject(let reason): type = .reject; try b.text(reason)
        case let .data(seq, time, payload, crc):
            type = .data; b.put(seq); b.put(time); b.append(payload); b.put(crc)
        case let .ack(seq, time, total): type = .ack; b.put(seq); b.put(time); b.put(total)
        case .ping(let echo): type = .ping; b.put(echo)
        case .pong(let echo): type = .pong; b.put(echo)
        case .stats(let json): type = .stats; b = json
        case .bye(let reason): type = .bye; try b.text(reason)
        }
        guard b.count <= RadioFrame.maxBody else { throw RadioError.protocolViolation("oversize length") }
        return RadioFrame(type, b)
    }
    public init(_ frame: RadioFrame) throws {
        var r = BodyReader(data: frame.body)
        switch frame.type {
        case .hello:
            guard let id = UUID(uuidString: try r.text()) else { throw RadioError.protocolViolation("bad install UUID") }
            self = .hello(install: id, label: try r.text(), version: try r.number(), rate: try r.number())
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

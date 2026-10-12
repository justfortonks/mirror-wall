import Foundation

/// Mirror Wall Cast: how the Android app sends its screen to a slot (see docs/mirror-wall-cast.md).
///
/// One TCP connection per phone. Every message is a one-byte type, a four-byte big-endian payload
/// length, then the payload. The phone says hello, waits for welcome (or busy), then sends video.
public enum CastMessageType: UInt8 {
    // Phone to Mac.
    case hello = 0x01
    case video = 0x02
    case paused = 0x03
    case resumed = 0x04
    case heartbeat = 0x05
    case bye = 0x06
    // Mac to phone.
    case welcome = 0x81
    case busy = 0x82
}

/// The phone's introduction.
public struct CastHello: Codable, Equatable {
    public var `protocol`: Int
    /// The phone's name, e.g. "HC50 Front Desk".
    public var name: String
    /// Maker and model, e.g. "Zebra HC50".
    public var model: String
    /// A stable ID the app makes for the phone, for the allow-list.
    public var deviceID: String

    public init(protocol: Int = 1, name: String, model: String, deviceID: String) {
        self.protocol = `protocol`
        self.name = name
        self.model = model
        self.deviceID = deviceID
    }
}

/// The Mac's answer to a hello.
public struct CastWelcome: Codable, Equatable {
    /// The slot's name.
    public var slot: String
    /// The most frames a second the phone should send.
    public var maxFrameRate: Int

    public init(slot: String, maxFrameRate: Int) {
        self.slot = slot
        self.maxFrameRate = maxFrameRate
    }
}

/// Why the Mac turned a phone away, shown on the phone.
public struct CastBusy: Codable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public enum CastMessage: Equatable {
    case hello(CastHello)
    /// One encoded picture (H.264 access unit, Annex B), captured at `captureMicros` on the phone's
    /// steady clock.
    case video(captureMicros: Int64, accessUnit: [UInt8])
    /// The phone's screen turned off.
    case paused
    case resumed
    case heartbeat
    case bye
    case welcome(CastWelcome)
    case busy(CastBusy)

    /// The message as sent over the connection.
    public func encoded() -> [UInt8] {
        let type: CastMessageType
        var payload: [UInt8] = []
        let encoder = JSONEncoder()
        switch self {
        case .hello(let hello):
            type = .hello
            payload = Array((try? encoder.encode(hello)) ?? Data())
        case .video(let micros, let accessUnit):
            type = .video
            payload = withUnsafeBytes(of: micros.bigEndian, Array.init) + accessUnit
        case .paused: type = .paused
        case .resumed: type = .resumed
        case .heartbeat: type = .heartbeat
        case .bye: type = .bye
        case .welcome(let welcome):
            type = .welcome
            payload = Array((try? encoder.encode(welcome)) ?? Data())
        case .busy(let busy):
            type = .busy
            payload = Array((try? encoder.encode(busy)) ?? Data())
        }
        let length = UInt32(payload.count).bigEndian
        return [type.rawValue] + withUnsafeBytes(of: length, Array.init) + payload
    }
}

/// Splits a Mirror Wall Cast byte stream into messages, however the bytes arrive.
///
/// Not thread-safe: feed it from one thread.
public final class CastReader {
    public enum Failure: Error, Equatable {
        case tooLarge(Int)
        case malformed(UInt8)
    }

    /// No picture comes anywhere near this; anything bigger means the stream is out of step.
    public static let maxPayload = 16 << 20
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Adds bytes and returns the messages they complete. Unknown message types are skipped, so a
    /// newer phone app can add messages. Throws if the stream can't be followed any more.
    public func push(_ bytes: [UInt8]) throws -> [CastMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [CastMessage] = []
        while buffer.count - start >= 5 {
            let type = buffer[start]
            let length = buffer[(start + 1)...(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxPayload else { throw Failure.tooLarge(length) }
            guard buffer.count - start >= 5 + length else { break }
            let payload = Array(buffer[(start + 5)..<(start + 5 + length)])
            start += 5 + length
            if let message = try Self.decode(type: type, payload: payload) {
                messages.append(message)
            }
        }
        // Drop what's been read once it's worth the copy.
        if start > 1 << 16 || start == buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return messages
    }

    private static func decode(type rawType: UInt8, payload: [UInt8]) throws -> CastMessage? {
        guard let type = CastMessageType(rawValue: rawType) else { return nil }
        let decoder = JSONDecoder()
        do {
            switch type {
            case .hello: return .hello(try decoder.decode(CastHello.self, from: Data(payload)))
            case .welcome: return .welcome(try decoder.decode(CastWelcome.self, from: Data(payload)))
            case .busy: return .busy(try decoder.decode(CastBusy.self, from: Data(payload)))
            case .video:
                guard payload.count >= 8 else { throw Failure.malformed(rawType) }
                let micros = payload[0..<8].reduce(Int64(0)) { $0 << 8 | Int64($1) }
                return .video(captureMicros: micros, accessUnit: Array(payload[8...]))
            case .paused: return .paused
            case .resumed: return .resumed
            case .heartbeat: return .heartbeat
            case .bye: return .bye
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.malformed(rawType)
        }
    }
}

/// The NAL units in an Annex B byte stream (each after a 00 00 01 or 00 00 00 01 start code),
/// without their start codes.
public func annexBNALUnits(_ bytes: [UInt8]) -> [[UInt8]] {
    var units: [[UInt8]] = []
    var unitStart: Int?
    var index = 0
    while index + 2 < bytes.count {
        if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
            if let unitStart {
                var end = index
                // A four-byte start code's leading zero belongs to it, not to the unit before.
                if end > unitStart, bytes[end - 1] == 0 { end -= 1 }
                if end > unitStart { units.append(Array(bytes[unitStart..<end])) }
            }
            index += 3
            unitStart = index
        } else {
            index += 1
        }
    }
    if let unitStart, unitStart < bytes.count {
        units.append(Array(bytes[unitStart...]))
    }
    return units
}

/// Converts the phone's capture time to the 90 kHz clock the renderer and recorder use for RTP.
public func castRTPTimestamp(captureMicros: Int64) -> UInt32 {
    UInt32(truncatingIfNeeded: captureMicros &* 9 / 100)
}

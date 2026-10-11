/// A parsed RTP packet (RFC 3550). Only the fields the H.264 depacketizer needs are kept.
public struct RTPPacket: Equatable {
    public let payloadType: UInt8
    public let marker: Bool
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: [UInt8]

    public init(payloadType: UInt8 = 96, marker: Bool, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32 = 0, payload: [UInt8]) {
        self.payloadType = payloadType
        self.marker = marker
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Parses a datagram. Returns nil for anything that is not a well-formed RTP version 2 packet.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)

        var offset = 12 + csrcCount * 4
        guard bytes.count >= offset else { return nil }
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
            guard bytes.count >= offset else { return nil }
        }

        var end = bytes.count
        if hasPadding {
            let padding = Int(bytes[end - 1])
            guard padding > 0, padding <= end - offset else { return nil }
            end -= padding
        }

        self.payloadType = bytes[1] & 0x7F
        self.marker = bytes[1] & 0x80 != 0
        self.sequenceNumber = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        self.timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        self.ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        self.payload = Array(bytes[offset..<end])
    }

    /// Serializes the packet (no CSRCs, extension or padding). Used by tests.
    public var bytes: [UInt8] {
        var out: [UInt8] = [0x80, (marker ? 0x80 : 0) | (payloadType & 0x7F)]
        out += [UInt8(sequenceNumber >> 8), UInt8(sequenceNumber & 0xFF)]
        out += [UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF)]
        out += [UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF)]
        return out + payload
    }
}

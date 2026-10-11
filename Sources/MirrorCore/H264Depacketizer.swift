/// One video frame (access unit): the NAL units that share an RTP timestamp, without start codes.
public struct H264Frame: Equatable {
    public var nalUnits: [[UInt8]]
    public var timestamp: UInt32

    public init(nalUnits: [[UInt8]], timestamp: UInt32) {
        self.nalUnits = nalUnits
        self.timestamp = timestamp
    }

    public var isKeyframe: Bool {
        nalUnits.contains { H264NALType(of: $0) == .idr }
    }
}

public enum H264NALType: UInt8 {
    case slice = 1
    case idr = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case accessUnitDelimiter = 9
    case stapA = 24
    case fuA = 28

    public init?(of nal: [UInt8]) {
        guard let first = nal.first else { return nil }
        self.init(rawValue: first & 0x1F)
    }
}

/// Reassembles H.264 frames from RTP packets (RFC 6184 non-interleaved mode:
/// single NAL unit packets, STAP-A and FU-A), which is what GStreamer's rtph264pay sends.
///
/// Not thread-safe: feed it from one thread.
public final class H264Depacketizer {
    private var pending: [[UInt8]] = []
    private var pendingTimestamp: UInt32?
    private var fragment: [UInt8]?
    private var lastSequence: UInt16?

    /// Number of gaps seen in RTP sequence numbers.
    public private(set) var sequenceGaps = 0
    /// Number of packets missing from those gaps.
    public private(set) var lostPackets = 0

    public init() {}

    /// Adds a packet and returns any frames it completed.
    ///
    /// A frame is complete when a packet carries the RTP marker bit, or when a packet with a
    /// new timestamp arrives while the previous frame is still open (its marker was lost).
    public func push(_ packet: RTPPacket) -> [H264Frame] {
        var completed: [H264Frame] = []

        if let last = lastSequence, packet.sequenceNumber != last &+ 1 {
            sequenceGaps += 1
            let missing = Int(packet.sequenceNumber &- last &- 1)
            // A packet arriving late looks like a gap of almost 65536; it isn't a loss.
            if missing < 1000 { lostPackets += missing }
            fragment = nil
        }
        lastSequence = packet.sequenceNumber

        if let timestamp = pendingTimestamp, timestamp != packet.timestamp {
            if !pending.isEmpty {
                completed.append(H264Frame(nalUnits: pending, timestamp: timestamp))
            }
            pending = []
            fragment = nil
        }
        pendingTimestamp = packet.timestamp

        let payload = packet.payload
        if let header = payload.first {
            switch header & 0x1F {
            case 1...23:
                pending.append(payload)
            case H264NALType.stapA.rawValue:
                var index = 1
                while index + 2 <= payload.count {
                    let size = Int(payload[index]) << 8 | Int(payload[index + 1])
                    index += 2
                    guard size > 0, index + size <= payload.count else { break }
                    pending.append(Array(payload[index..<index + size]))
                    index += size
                }
            case H264NALType.fuA.rawValue:
                guard payload.count >= 2 else { break }
                let fuHeader = payload[1]
                let isStart = fuHeader & 0x80 != 0
                let isEnd = fuHeader & 0x40 != 0
                if isStart {
                    fragment = [(header & 0xE0) | (fuHeader & 0x1F)] + payload[2...]
                } else if fragment != nil {
                    fragment! += payload[2...]
                }
                if isEnd, let nal = fragment {
                    pending.append(nal)
                    fragment = nil
                }
            default:
                break // STAP-B, MTAP and FU-B are not used in non-interleaved mode.
            }
        }

        if packet.marker {
            if !pending.isEmpty {
                completed.append(H264Frame(nalUnits: pending, timestamp: packet.timestamp))
            }
            pending = []
            pendingTimestamp = nil
            fragment = nil
        }
        return completed
    }

    /// Drops any partial frame, for example when the phone reconnects.
    public func reset() {
        pending = []
        pendingTimestamp = nil
        fragment = nil
        lastSequence = nil
    }
}

/// Converts NAL units to AVCC format: each unit prefixed with its 4-byte big-endian length.
public func avccData(for nalUnits: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(nalUnits.reduce(0) { $0 + $1.count + 4 })
    for nal in nalUnits {
        let length = UInt32(nal.count)
        out += [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        out += nal
    }
    return out
}

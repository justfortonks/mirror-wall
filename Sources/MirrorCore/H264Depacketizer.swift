/// The video format a phone sends: H.264, or H.265 (HEVC) when a slot asks for the sharper picture.
public enum VideoCodec: Equatable {
    case h264
    case hevc
}

/// One video frame (access unit): the NAL units that share an RTP timestamp, without start codes.
/// Named for H.264, but carries H.265 frames too (see `codec`).
public struct H264Frame: Equatable {
    public var nalUnits: [[UInt8]]
    public var timestamp: UInt32
    public var codec: VideoCodec

    public init(nalUnits: [[UInt8]], timestamp: UInt32, codec: VideoCodec = .h264) {
        self.nalUnits = nalUnits
        self.timestamp = timestamp
        self.codec = codec
    }

    public var isKeyframe: Bool {
        switch codec {
        case .h264: return nalUnits.contains { H264NALType(of: $0) == .idr }
        case .hevc: return nalUnits.contains { HEVCNALType.of($0).map(HEVCNALType.isKeyframe) ?? false }
        }
    }
}

/// H.265 NAL unit types the app cares about (ITU-T H.265 table 7-1, RFC 7798).
public enum HEVCNALType {
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let accessUnitDelimiter: UInt8 = 35
    static let aggregation: UInt8 = 48
    static let fragment: UInt8 = 49

    /// The type from a NAL unit's two-byte header.
    public static func of(_ nal: [UInt8]) -> UInt8? {
        nal.first.map { ($0 >> 1) & 0x3F }
    }

    /// IRAP pictures (BLA, IDR, CRA): the decoder can start at one.
    public static func isKeyframe(_ type: UInt8) -> Bool {
        (16...21).contains(type)
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

/// Reassembles video frames from RTP packets: H.264 as GStreamer's rtph264pay sends it (RFC 6184
/// non-interleaved mode: single NAL unit packets, STAP-A and FU-A), or H.265 as rtph265pay sends
/// it (RFC 7798: single NAL unit packets, aggregation packets and fragmentation units).
///
/// The codec is read from the stream: from the parameter sets that come before every keyframe
/// (the receiver runs rtph26xpay with config-interval=1). Their first bytes can't be mistaken for
/// the other codec's. Until one arrives, the stream is taken to be H.264, the phones' usual format;
/// anything collected before it is dropped when it shows otherwise.
///
/// Not thread-safe: feed it from one thread.
public final class H264Depacketizer {
    /// The codec the stream is in: H.264 until a parameter set shows otherwise.
    public private(set) var codec: VideoCodec = .h264
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

        let payload = packet.payload
        if let detected = Self.codecOfParameterSets(in: payload), detected != codec {
            // The stream is in the other codec: drop whatever was collected as this one.
            codec = detected
            pending = []
            pendingTimestamp = nil
            fragment = nil
        }

        if let timestamp = pendingTimestamp, timestamp != packet.timestamp {
            if !pending.isEmpty {
                completed.append(H264Frame(nalUnits: pending, timestamp: timestamp, codec: codec))
            }
            pending = []
            fragment = nil
        }
        pendingTimestamp = packet.timestamp

        if codec == .hevc {
            pushHEVC(payload)
        } else if let header = payload.first {
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
                completed.append(H264Frame(nalUnits: pending, timestamp: packet.timestamp, codec: codec))
            }
            pending = []
            pendingTimestamp = nil
            fragment = nil
        }
        return completed
    }

    /// Collects the NAL units in one H.265 packet's payload.
    private func pushHEVC(_ payload: [UInt8]) {
        guard payload.count >= 3, let type = HEVCNALType.of(payload) else { return }
        switch type {
        case HEVCNALType.aggregation:
            var index = 2
            while index + 2 <= payload.count {
                let size = Int(payload[index]) << 8 | Int(payload[index + 1])
                index += 2
                guard size > 0, index + size <= payload.count else { break }
                pending.append(Array(payload[index..<index + size]))
                index += size
            }
        case HEVCNALType.fragment:
            let fuHeader = payload[2]
            let isStart = fuHeader & 0x80 != 0
            let isEnd = fuHeader & 0x40 != 0
            if isStart {
                // The NAL header again, with the fragment's own type in place of 49.
                fragment = [(payload[0] & 0x81) | (fuHeader & 0x3F) << 1, payload[1]] + payload[3...]
            } else if fragment != nil {
                fragment! += payload[3...]
            }
            if isEnd, let nal = fragment {
                pending.append(nal)
                fragment = nil
            }
        case 0..<HEVCNALType.aggregation:
            pending.append(payload)
        default:
            break // PACI and reserved types aren't sent by rtph265pay.
        }
    }

    /// The codec a packet shows, if it carries a parameter set: an H.265 VPS (alone or first in an
    /// aggregation packet) or an H.264 SPS (alone or first in a STAP-A). Every other packet, nil.
    ///
    /// H.265 NAL headers from a phone always have an even first byte (layer 0), and an H.264 SPS's
    /// is odd, so the two can't be confused. 0x40 or 0x60 in H.264 would be type 0, which isn't used.
    static func codecOfParameterSets(in payload: [UInt8]) -> VideoCodec? {
        guard payload.count >= 2 else { return nil }
        let first = payload[0]
        if payload[1] == 0x01 {
            if first == 0x40 { return .hevc }
            if first == 0x60, payload.count >= 5, payload[4] == 0x40 { return .hevc }
        }
        if first & 0x80 == 0, first & 0x1F == H264NALType.sps.rawValue { return .h264 }
        if first & 0x80 == 0, first & 0x1F == H264NALType.stapA.rawValue,
           payload.count >= 4, payload[3] & 0x1F == H264NALType.sps.rawValue {
            return .h264
        }
        return nil
    }

    /// Drops any partial frame and forgets the codec, for example when the phone reconnects.
    public func reset() {
        pending = []
        pendingTimestamp = nil
        fragment = nil
        lastSequence = nil
        codec = .h264
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

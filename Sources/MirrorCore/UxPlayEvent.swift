import Foundation

/// Connection events recognised in uxplay's output (it must run with `-d 1` for `openConnections`).
public enum UxPlayEvent: Equatable {
    /// An iPhone asked to connect: "connection request from NAME (MODEL) with deviceID = ..."
    case clientConnecting(name: String, model: String)
    /// uxplay's count of open connections changed; 0 means no phone is attached.
    case openConnections(Int)
    /// uxplay gave up on a phone that stopped sending heartbeats.
    case lostConnection
    /// The phone paused the video stream, which iOS does when its screen locks.
    case streamPaused
    /// The phone started or resumed the video stream.
    case streamStarted
    /// The phone's regular check-in ("POST /feedback", every 2 seconds while it's connected).
    case heartbeat
    /// Network round trip to the phone, in seconds, from uxplay's clock sync (every few seconds).
    case networkRoundTrip(Double)
    /// A frame's arrival time at uxplay minus the phone's timestamp for it, in seconds (offset by
    /// a fixed, unknown amount per phone). Printed once a second by a uxplay with
    /// `patches/uxplay-latency-report.patch`.
    case videoLatency(Double)

    public init?(line: String) {
        if let range = line.range(of: "connection request from "),
           let tail = line[range.upperBound...].range(of: " with deviceID") {
            let nameAndModel = line[range.upperBound..<tail.lowerBound]
            // The name may itself contain parentheses, so split on the last " (".
            if let open = nameAndModel.range(of: " (", options: .backwards), nameAndModel.hasSuffix(")") {
                let name = String(nameAndModel[..<open.lowerBound])
                let model = String(nameAndModel[open.upperBound...].dropLast())
                self = .clientConnecting(name: name, model: model)
            } else {
                self = .clientConnecting(name: String(nameAndModel), model: "")
            }
        } else if let range = line.range(of: "Open connections: ") {
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            guard let count = Int(digits) else { return nil }
            self = .openConnections(count)
        } else if line.contains("raop_rtp video:"), let latency = Self.number(after: "latency = ", in: line) {
            self = .videoLatency(latency)
        } else if line.contains("best NTP data:"), let delay = Self.number(after: "delay ", in: line) {
            self = .networkRoundTrip(delay)
        } else if line.contains("POST /feedback") {
            self = .heartbeat
        } else if line.contains("lost connection with client") {
            self = .lostConnection
        } else if line.contains("video stream is stopping") {
            self = .streamPaused
        } else if line.contains("codec packet from client"), let range = line.range(of: " header ") {
            // "... header 01 00 56 01 ..." when the stream stops, "... header 01 00 16 01 ..." when it
            // (re)starts: the third byte's 0x40 bit marks a stop.
            let bytes = line[range.upperBound...].split(separator: " ").prefix(3)
            guard bytes.count == 3, let flags = UInt8(bytes[bytes.index(bytes.startIndex, offsetBy: 2)], radix: 16) else {
                return nil
            }
            self = flags & 0x40 != 0 ? .streamPaused : .streamStarted
        } else if line.contains("video renderer resumed") || line.contains("starting mirroring") {
            // Not "begin video stream": uxplay prints that after a stop as well as a start.
            self = .streamStarted
        } else {
            return nil
        }
    }

    /// The number following `label`, e.g. 0.0079 in "latency =  0.007900, ts = ...".
    private static func number(after label: String, in line: String) -> Double? {
        guard let range = line.range(of: label) else { return nil }
        let text = line[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(text)
    }
}

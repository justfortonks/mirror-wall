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
        } else if line.contains("lost connection with client") {
            self = .lostConnection
        } else if line.contains("video stream is stopping") {
            self = .streamPaused
        } else if line.hasPrefix("begin video stream") || line.contains("starting mirroring") {
            self = .streamStarted
        } else {
            return nil
        }
    }
}

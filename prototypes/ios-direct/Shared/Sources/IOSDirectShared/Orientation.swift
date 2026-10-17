import Foundation

public enum OrientationSource: UInt8, Codable { case capture = 0, device = 1 }

/// Clockwise presentation rotation relative to portrait panel pixels. Sender clock;
/// never compare it with receiver uptime or use it to schedule video decode.
public struct OrientationHint: Equatable, Codable {
    public let degrees: UInt16
    public let source: OrientationSource
    public let monotonicNs: UInt64
    public init(degrees: UInt16, source: OrientationSource, monotonicNs: UInt64) {
        self.degrees = degrees; self.source = source; self.monotonicNs = monotonicNs
    }
    public func validate() throws {
        guard [0, 90, 180, 270].contains(degrees) else {
            throw RadioError.protocolViolation("invalid rotation degrees")
        }
    }
}

/// Presentation only: owns no decoder, configuration, reassembly or media queue.
/// Keep one latest hint per source for this authenticated session. Capture wins for
/// its lifetime; a device timestamp cannot displace a capture measurement.
public struct VideoRotationState: Equatable {
    public private(set) var manualDegrees: UInt16
    public var automatic = false
    public private(set) var capture: OrientationHint?
    public private(set) var device: OrientationHint?
    public init(manualDegrees: UInt16 = 0) {
        self.manualDegrees = [0, 90, 180, 270].contains(manualDegrees) ? manualDegrees : 0
    }
    public var selectedHint: OrientationHint? { capture ?? device }
    public var degrees: UInt16 { automatic ? selectedHint?.degrees ?? manualDegrees : manualDegrees }
    public var sourceLabel: String {
        guard automatic else { return "manual" }
        guard let hint = selectedHint else { return "manual (awaiting hint)" }
        return hint.source == .capture ? "capture" : "device"
    }
    public mutating func cycle() { automatic = false; manualDegrees = (manualDegrees + 90) % 360 }
    public mutating func reset() { automatic = false; manualDegrees = 0 }
    public mutating func resetHints() { capture = nil; device = nil }
    public mutating func accept(_ hint: OrientationHint) {
        guard (try? hint.validate()) != nil else { return }
        let previous = hint.source == .capture ? capture : device
        guard previous == nil || hint.monotonicNs > previous!.monotonicNs else { return }
        if hint.source == .capture { capture = hint } else { device = hint }
    }
}

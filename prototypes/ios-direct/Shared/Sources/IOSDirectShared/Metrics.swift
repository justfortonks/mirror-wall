import Foundation

/// Cumulative counters since reset; each sample includes its reset epoch.
public struct MetricsSnapshot: Codable {
    public var kind = "metrics"
    public var monotonicTime: Double = 0
    public var wallTime = ""
    public var resetEpoch = 0
    public var appState = "active"
    public var captureState = "idle"
    public var encoderState = "unavailable: no session"
    public var encoderRecreateAttempts = 0
    public var encoderRecreateSuccesses = 0
    public var encoderLastFailingOSStatus: Int32?
    public var encoderNoSessionDrops = 0
    public var encoderRetryAfter: Double = 0
    public var capturedFPS: Double = 0
    public var pacedFPS: Double = 0
    public var encodedFPS: Double = 0
    public var encodedMbit: Double = 0
    public var streamPreset = StreamPreset.standard.rawValue
    public var maxFPS = 30
    public var sentFPS: Double = 0
    public var ackedFPS: Double = 0
    public var sentMbit: Double = 0
    public var video: VideoSendSnapshot?
    public var captureCallbacks = 0
    public var validFrames = 0
    public var pacedFrames = 0
    public var pacingDrops = 0
    public var sourceDrops = 0
    public var latestPTS: Double?
    public var dimensions: Dimensions?
    public var sourceDimensions: Dimensions?
    public var frameOrientation: UInt32?
    public var frameScreenRect: String?
    public var frameContentRect: String?
    public var frameScaleFactor: Double?
    public var frameContentScale: Double?
    public var sourcePixelFormat: UInt32?
    public var generation = 0
    public var bitrate = 6_000_000
    public var hardwareEncoder = "unknown"
    public var negotiatedProfile: String?
    public var encodeSubmitted = 0
    public var encodeCompleted = 0
    public var encodeErrors = 0
    public var encodeBytes = 0
    public var keyframes = 0
    public var sinkEnqueued = 0
    public var sinkDrained = 0
    public var sinkBytes = 0
    public var sinkQueueBytes = 0
    public var sinkQueueAgeMS: Double = 0
    public var sinkDrops = 0
    public var sinkLatestPTS: Double?
    public var sinkHash = "cbf29ce484222325"
    public var thermalState = "unknown"
    public var lowPower = false
    public var batteryLevel: Double = -1
    public var batteryState = "unknown"
    public var residentMemoryMB: Double?
    public init() {}
    public func jsonLine() throws -> Data { try JSONLine.encode(self) }
}

public struct Event: Encodable {
    public let kind = "event"
    public let monotonicTime: Double
    public let wallTime: String
    public let name: String
    public let details: String
    public init(monotonicTime: Double, wallTime: String, name: String, details: String) {
        self.monotonicTime = monotonicTime; self.wallTime = wallTime
        self.name = name; self.details = details
    }
}

public enum JSONLine {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(0x0a); return data
    }
}

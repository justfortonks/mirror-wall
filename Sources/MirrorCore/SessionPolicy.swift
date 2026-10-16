import Foundation

/// Screen-off iOS sessions can be quiet while the user prepares the next demo step.
public enum SessionLiveness {
    public static func silenceLimit(screenOff: Bool, android: Bool) -> TimeInterval {
        screenOff && !android ? 300 : 10
    }
}

/// Old companions treat a closed socket as an outage. Refuse their automatic retry after Stop.
/// The cooldown exceeds the companion's 60-second retry window; it does not affect other phones.
public struct CastAdmission {
    private struct Key: Hashable { let device: String; let share: String? }
    private var stoppedUntil: [Key: Date] = [:]
    public init() {}
    public mutating func stop(deviceID: String, shareID: String? = nil, now: Date = Date()) {
        stoppedUntil = stoppedUntil.filter { $0.value > now }
        stoppedUntil[Key(device: deviceID, share: shareID)] = now.addingTimeInterval(70)
    }
    public func permits(_ deviceID: String, shareID: String? = nil, now: Date = Date()) -> Bool {
        stoppedUntil[Key(device: deviceID, share: shareID)].map { $0 <= now } ?? true
    }
}

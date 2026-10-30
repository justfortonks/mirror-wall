import Foundation

/// A random number made once per Mac (and user) that goes into every slot's AirPlay device ID
/// (see `SlotConfig.deviceID(computer:)`), so slots on two computers running Mirror Wall on the
/// same network never claim the same identity.
enum ReceiverTag {
    private static let key = "receiverTag"

    static let current: UInt32 = {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: key) as? Int, saved != 0 { return UInt32(truncatingIfNeeded: saved) }
        let tag = UInt32.random(in: 1...UInt32.max)
        defaults.set(Int(tag), forKey: key)
        return tag
    }()
}

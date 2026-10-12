import Foundation

/// One mirroring slot: an AirPlay receiver that a single iPhone can mirror to.
///
/// Each slot gets its own uxplay process with its own name, ports and device ID, because one
/// uxplay instance only accepts one phone at a time.
public struct SlotConfig: Codable, Hashable, Identifiable {
    /// 1-based slot number. Ports and the device ID are derived from it, so it never changes.
    public let id: Int
    /// The name shown in Screen Mirroring on the iPhone.
    public var name: String
    /// The name of the last iPhone that mirrored to this slot. Kept after it disconnects so the
    /// slot's own window keeps the same title (OBS finds windows by title).
    public var lastPhoneName: String?
    /// What the slot shows while no phone is mirroring; nil for the usual waiting message.
    public var standby: StandbyPicture?

    public init(id: Int, name: String, lastPhoneName: String? = nil) {
        precondition(id >= 1 && id <= 99, "slot id out of range")
        self.id = id
        self.name = name
        self.lastPhoneName = lastPhoneName
    }

    /// "Alex's MacBook Pro 1": the Mac's name, so phones can tell two Macs' slots apart.
    public static func defaultName(for id: Int, computerName: String?) -> String {
        let computer = computerName.map { shortened(collapsed($0), limit: maxComputerNameLength) } ?? ""
        return (computer.isEmpty ? "Mirror Wall" : computer) + " \(id)"
    }

    /// The name every slot had before names included the Mac's.
    public static func isOldDefaultName(_ name: String, id: Int) -> Bool {
        name == "Mirror Wall \(id)"
    }

    static let maxComputerNameLength = 20
    /// Longer names get cut in the iPhone's Screen Mirroring list anyway.
    public static let maxNameLength = 30
    /// Bonjour allows 63 bytes; a little to spare.
    static let maxNameBytes = 60

    /// A name as typed, made tidy: single spaces, at most `maxNameLength` characters, cut at a
    /// word where possible. Empty if nothing is left.
    public static func tidyName(_ name: String) -> String {
        shortened(collapsed(name), limit: maxNameLength)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts `text` to `limit` characters, at the last space if that keeps at least half of it.
    static func shortened(_ text: String, limit: Int) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        var cut = false
        if result.count > limit {
            let prefix = result.prefix(limit)
            if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) >= limit / 2 {
                result = String(prefix[..<space])
            } else {
                result = String(prefix)
            }
            cut = true
        }
        while result.utf8.count > maxNameBytes {
            result.removeLast()
            cut = true
        }
        // Don't leave a dangling separator where the name was cut.
        while cut, let last = result.last, " -–,.;:&+/".contains(last) { result.removeLast() }
        return result
    }

    /// First of the three TCP/UDP ports uxplay uses (base, base+1, base+2): 7300, 7400, ...
    public var airplayBasePort: UInt16 {
        7200 + UInt16(id) * 100
    }

    /// Localhost UDP port uxplay forwards the decrypted H.264 RTP stream to: 5600, 5602, ...
    public var rtpPort: UInt16 {
        5598 + UInt16(id) * 2
    }

    /// A locally administered MAC-style device ID, unique per slot.
    public var deviceID: String {
        let hex = String(id, radix: 16, uppercase: true)
        return "02:00:00:00:00:" + (hex.count == 1 ? "0" + hex : hex)
    }

    /// The highest frame rates the app offers to ask phones for. uxplay's own default is 30.
    public static let frameRates = [30, 60]

    /// Command-line arguments for this slot's uxplay process.
    public var uxplayArguments: [String] {
        uxplayArguments(maxFrameRate: 30)
    }

    /// Command-line arguments for this slot's uxplay process. `maxFrameRate` is the most frames a
    /// second the phone is asked to send; it may send fewer. With `allowedDevices`, only phones
    /// with those device IDs may connect.
    public func uxplayArguments(maxFrameRate: Int, allowedDevices: [String]? = nil) -> [String] {
        var arguments = [
            "-n", name,
            "-nh",                      // don't append "@hostname" to the name
            "-p", String(airplayBasePort),
            "-m", deviceID,
            "-vsync", "no",             // show frames as they arrive; with sync on the picture froze after the phone slept
            "-as", "0",                 // view only: no audio
            "-d", "1",                  // debug log without packet dumps: reports connects and disconnects
            "-fps", String(maxFrameRate),
            "-vrtp", "config-interval=1 ! udpsink host=127.0.0.1 port=\(rtpPort)",
        ]
        if let allowedDevices {
            arguments.append("-restrict")
            for device in allowedDevices { arguments += ["-allow", device] }
        }
        return arguments
    }
}

/// A slot's picture while no phone is mirroring, in place of the usual waiting message.
public enum StandbyPicture: Codable, Hashable {
    case blank
    /// An image file the app keeps a copy of, by its file name in the app's own folder.
    case image(fileName: String)
}

/// A phone that has mirrored to this Mac, remembered for the allow-list.
public struct KnownPhone: Codable, Hashable, Identifiable {
    /// The ID the phone gives AirPlay receivers, e.g. "0E:90:EE:EE:61:54".
    public var deviceID: String
    public var name: String
    public var model: String
    public var lastSeen: Date

    public var id: String { deviceID }

    public init(deviceID: String, name: String, model: String, lastSeen: Date) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.lastSeen = lastSeen
    }
}

public extension SlotConfig {
    /// Titles for the slots' own windows: "MacMirror-" plus the last phone's name, or the slot's
    /// name before any phone has connected. Slots whose names would clash get "-<slot number>".
    static func windowTitles(for slots: [SlotConfig]) -> [Int: String] {
        let bases = slots.map { slot -> (Int, String) in
            let name = slot.lastPhoneName.flatMap { $0.isEmpty ? nil : $0 } ?? slot.name
            return (slot.id, "MacMirror-" + name)
        }
        var counts: [String: Int] = [:]
        for (_, base) in bases { counts[base, default: 0] += 1 }
        return Dictionary(uniqueKeysWithValues: bases.map { id, base in
            (id, counts[base]! > 1 ? "\(base)-\(id)" : base)
        })
    }
}

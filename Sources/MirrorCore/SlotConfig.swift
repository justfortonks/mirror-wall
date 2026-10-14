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
    /// The model code of that iPhone, e.g. "iPhone18,2", for sizing the slot's own window.
    public var lastPhoneModel: String?
    /// What the slot shows while no phone is mirroring; nil to use the one set for all slots.
    public var standby: StandbyPicture?
    /// Whether the slot also sends its picture to OBS through Syphon (Spout on Windows); nil
    /// follows the setting for all slots, which is off by default.
    public var obsFeed: Bool?
    /// Whether the slot's picture has a phone frame around it on the wall and in its own window;
    /// nil follows the setting for all slots, which is off by default.
    public var bezel: Bool?
    /// Whether the slot's OBS feed has the phone frame around the picture, with see-through
    /// corners; nil (off) by default.
    public var feedBezel: Bool?
    /// Whether the slot's phone appears in the Stage window while it's mirroring; nil (on) by
    /// default.
    public var onStage: Bool?

    public init(id: Int, name: String, lastPhoneName: String? = nil) {
        precondition(id >= 1 && id <= 99, "slot id out of range")
        self.id = id
        self.name = name
        self.lastPhoneName = lastPhoneName
    }

    /// "Mirror Wall 1 · MacBook Air": the Mac's name, without its owner, so phones can tell two
    /// Macs' slots apart. "Mirror Wall" comes first because the phone's list cuts long names at
    /// the end, and because the Mac's own AirPlay receiver goes by the Mac's full name.
    public static func defaultName(for id: Int, computerName: String?) -> String {
        let computer = computerName.map { shortened(withoutOwner(collapsed($0)), limit: maxComputerNameLength) } ?? ""
        return "Mirror Wall \(id)" + (computer.isEmpty ? "" : " · " + computer)
    }

    /// Names given by earlier versions, which a slot still using one should replace: "Mirror Wall 1",
    /// and "Thomas's MacBook Air 1" (which looked too much like the Mac's own AirPlay receiver).
    public static func isOldDefaultName(_ name: String, id: Int, computerName: String?) -> Bool {
        if name == "Mirror Wall \(id)" { return true }
        guard let computerName else { return false }
        return name == shortened(collapsed(computerName), limit: 20) + " \(id)"
    }

    /// "Thomas's MacBook Air" → "MacBook Air".
    static func withoutOwner(_ name: String) -> String {
        for apostrophe in ["'s ", "’s "] {
            if let range = name.range(of: apostrophe), !name[range.upperBound...].isEmpty {
                return String(name[range.upperBound...])
            }
        }
        return name
    }

    static let maxComputerNameLength = 14
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

    /// TCP port Android phones (Mirror Wall Cast) connect to: 7350, 7450, ... Clear of uxplay's
    /// three ports.
    public var castPort: UInt16 {
        airplayBasePort + 50
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
    /// with those device IDs may connect. With `sharpPicture`, phones are offered H.265 at up to
    /// 3840×2160, and send portrait pictures twice as tall and wide as with H.264's 1920×1080.
    public func uxplayArguments(maxFrameRate: Int, allowedDevices: [String]? = nil, sharpPicture: Bool = false) -> [String] {
        var arguments = [
            "-n", name,
            "-nh",                      // don't append "@hostname" to the name
            "-p", String(airplayBasePort),
            "-m", deviceID,
            "-vsync", "no",             // show frames as they arrive; with sync on the picture froze after the phone slept
            "-as", "0",                 // view only: no audio
            "-d", "1",                  // debug log without packet dumps: reports connects and disconnects
            "-fps", String(maxFrameRate),
            // Rebuild the video pipeline after every disconnect. uxplay on macOS skips that from a
            // receiver's second disconnect on (its "-nc" workaround for closing its own window,
            // which Mirror Wall never opens), leaving the next phone with no video in H.264 mode
            // and crashing the receiver in H.265 mode.
            "-nc", "no",
            // sync=false: send each frame on at once even when the receiver stamps it with the
            // phone's capture time (patches/uxplay-frame-timestamps.patch).
            "-vrtp", "config-interval=1 ! udpsink sync=false host=127.0.0.1 port=\(rtpPort)",
        ]
        if sharpPicture {
            arguments.append("-h265")
        }
        if let allowedDevices {
            arguments.append("-restrict")
            for device in allowedDevices { arguments += ["-allow", device] }
        }
        return arguments
    }
}

/// What a slot shows while no phone is mirroring.
public enum StandbyPicture: Codable, Hashable {
    /// "Waiting for … to mirror to …", the default.
    case message
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

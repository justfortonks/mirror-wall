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

    public init(id: Int, name: String, lastPhoneName: String? = nil) {
        precondition(id >= 1 && id <= 99, "slot id out of range")
        self.id = id
        self.name = name
        self.lastPhoneName = lastPhoneName
    }

    public static func defaultName(for id: Int) -> String {
        "Mirror Wall \(id)"
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

    /// Command-line arguments for this slot's uxplay process.
    public var uxplayArguments: [String] {
        [
            "-n", name,
            "-nh",                      // don't append "@hostname" to the name
            "-p", String(airplayBasePort),
            "-m", deviceID,
            "-vsync", "no",             // show frames as they arrive; with sync on the picture froze after the phone slept
            "-as", "0",                 // view only: no audio
            "-d", "1",                  // debug log without packet dumps: reports connects and disconnects
            "-vrtp", "config-interval=1 ! udpsink host=127.0.0.1 port=\(rtpPort)",
        ]
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

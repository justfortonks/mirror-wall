import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the app and the broadcast extension share through the App Group: where to send the
/// screen, this phone's name and ID, and how sharing is going. The app writes the target when a
/// slot is picked; the extension reads it when the broadcast starts and writes its status back.
enum Shared {
    static let appGroup = "group.com.justfortonks.mirrorwall.cast"
    /// Darwin notification the extension posts when its status changes, so the app redraws.
    static let statusChanged = "com.justfortonks.mirrorwall.cast.status" as CFString

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// A slot to share to: its direct addresses (tried in order) and, if the Mac is on the
    /// Mirror Wall Relay, the relay and the slot's code there (tried when no address answers).
    struct Target: Codable, Equatable {
        var name: String
        var port: UInt16
        var hosts: [String]
        var relay: String?
        var code: String?

        var hasRelay: Bool { (relay?.isEmpty == false) && (code?.isEmpty == false) }
    }

    static var target: Target? {
        get { defaults.data(forKey: "target").flatMap { try? JSONDecoder().decode(Target.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "target") }
    }

    /// The phone's name on Mirror Wall. iOS doesn't tell apps the name the user gave the phone,
    /// so the app asks once and keeps it here.
    static var phoneName: String {
        get { defaults.string(forKey: "phoneName").flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone" }
        set { defaults.set(newValue, forKey: "phoneName") }
    }

    /// A stable ID for the allow-list and for telling a reconnect from a new phone.
    static var deviceID: String {
        if let id = defaults.string(forKey: "deviceID") { return id }
        let id = "ios-" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: "deviceID")
        return id
    }

    /// The hardware code, e.g. "iPhone18,2"; Mirror Wall turns it into a name and a frame.
    static var modelCode: String {
        var info = utsname()
        uname(&info)
        let code = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? code
        #else
        return code
        #endif
    }

    /// The extension's latest word, shown in the app: "Sharing to Mirror Wall 1", or why not.
    struct Status: Codable, Equatable {
        var sharing: Bool
        var text: String
        var at: Date
    }

    static var status: Status? {
        get { defaults.data(forKey: "status").flatMap { try? JSONDecoder().decode(Status.self, from: $0) } }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "status")
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(statusChanged), nil, nil, true)
        }
    }

    /// The last few hundred lines from both sides, for Share Log.
    static func log(_ line: String, from side: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullTime, .withFractionalSeconds])
        var lines = defaults.stringArray(forKey: "log") ?? []
        lines.append("\(stamp) [\(side)] \(line)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        defaults.set(lines, forKey: "log")
        #if DEBUG
        print("[\(side)] \(line)")
        #endif
    }

    static var logText: String { (defaults.stringArray(forKey: "log") ?? []).joined(separator: "\n") }
}

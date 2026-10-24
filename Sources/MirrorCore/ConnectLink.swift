import Foundation

/// A link that tells the Mirror Wall Cast app how to reach one slot without finding it on the
/// network: `mirrorwall://connect?name=Mirror%20Wall%201&port=7350&host=192.168.1.20&host=100.101.1.2`.
///
/// Mirror Wall shows it as a QR code (Connect with QR Code…). It carries every address this
/// computer has, so a phone on the same Wi-Fi uses the Wi-Fi one and a phone that only shares a
/// VPN with the computer (Tailscale, say) uses that one; the app tries them in order and shares
/// to the first that answers. Hosts are IPv4 addresses or names; the order is the computer's
/// preference.
public struct ConnectLink: Equatable {
    public static let scheme = "mirrorwall"
    public static let action = "connect"

    public var name: String
    public var port: UInt16
    public var hosts: [String]
    /// The Mirror Wall Relay's host and this slot's code there, when the Mac is on a relay.
    /// The app tries the direct hosts first and the relay when none answers.
    public var relay: String?
    public var code: String?

    public init(name: String, port: UInt16, hosts: [String], relay: String? = nil, code: String? = nil) {
        self.name = name
        self.port = port
        self.hosts = hosts
        self.relay = relay
        self.code = code
    }

    public var hasRelay: Bool { relay.map { !$0.isEmpty } == true && code.map { !$0.isEmpty } == true }

    /// The link as text, for the QR code and the clipboard.
    public var text: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        var items = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "port", value: String(port))]
        items += hosts.map { URLQueryItem(name: "host", value: $0) }
        if hasRelay, let relay, let code {
            items.append(URLQueryItem(name: "relay", value: relay))
            items.append(URLQueryItem(name: "code", value: code))
        }
        components.queryItems = items
        return components.string ?? ""
    }

    public var url: URL? { URL(string: text) }

    /// Reads a link back; nil if it isn't one. Unknown query items are ignored, so either side
    /// can add some later. Without a port the link means slot 1.
    public init?(text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.action else { return nil }
        var name = ""
        var port: UInt16 = 7350
        var hosts: [String] = []
        var relay: String?
        var code: String?
        for item in components.queryItems ?? [] {
            guard let value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            switch item.name {
            case "name": name = value
            case "port": guard let number = UInt16(value) else { return nil }; port = number
            case "host": if !hosts.contains(value) { hosts.append(value) }
            case "relay": relay = value
            case "code": code = value.replacingOccurrences(of: " ", with: "")
            default: break
            }
        }
        let hasRelay = relay != nil && code != nil
        guard !hosts.isEmpty || hasRelay else { return nil }
        if name.isEmpty { name = hosts.first ?? relay ?? "" }
        self.init(name: name, port: port, hosts: hosts, relay: hasRelay ? relay : nil, code: hasRelay ? code : nil)
    }
}

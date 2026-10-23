import Foundation

/// The IPv4 addresses phones could reach this Mac at, best first: Wi-Fi and Ethernet, then a
/// Tailscale address (100.64.0.0/10 on a utun interface), then any other VPN. Loopback and
/// self-assigned (169.254.x.x) addresses are left out; so is IPv6, which the Cast app doesn't dial.
struct LocalAddress: Equatable, Identifiable {
    enum Kind: Int, Comparable {
        case lan, tailscale, vpn
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let address: String
    let interface: String
    let kind: Kind

    var id: String { address }

    /// What to call it next to the QR code.
    var label: String {
        switch kind {
        case .lan: return "Wi-Fi or Ethernet"
        case .tailscale: return "Tailscale"
        case .vpn: return "VPN (\(interface))"
        }
    }

    static func current() -> [LocalAddress] {
        var list: [LocalAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            let interface = String(cString: entry.pointee.ifa_name)
            guard let kind = kind(of: address, on: interface) else { continue }
            if !list.contains(where: { $0.address == address }) {
                list.append(LocalAddress(address: address, interface: interface, kind: kind))
            }
        }
        return list.sorted { ($0.kind, $0.interface) < ($1.kind, $1.interface) }
    }

    /// Nil for addresses phones can't use. Visible for the tests.
    static func kind(of address: String, on interface: String) -> Kind? {
        if address.hasPrefix("169.254.") || address.hasPrefix("127.") { return nil }
        if interface.hasPrefix("utun") || interface.hasPrefix("tun") || interface.hasPrefix("tap") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") {
            return isTailscale(address) ? .tailscale : .vpn
        }
        if interface.hasPrefix("en") || interface.hasPrefix("bridge") { return .lan }
        if interface.hasPrefix("awdl") || interface.hasPrefix("llw") || interface.hasPrefix("gif") || interface.hasPrefix("stf") || interface.hasPrefix("anpi") || interface.hasPrefix("ap") { return nil }
        return isTailscale(address) ? .tailscale : .vpn
    }

    /// Tailscale hands out 100.64.0.0/10 (100.64.x.x through 100.127.x.x).
    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

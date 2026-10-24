import Foundation
import Network

/// Mirror Wall slots on this network (Bonjour, `_mirrorwall._tcp`), as the Android app lists them.
/// A slot only advertises while it's free, so the list is the slots a phone can take.
@MainActor
final class SlotBrowser: ObservableObject {
    struct Slot: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var slots: [Slot] = []
    @Published private(set) var problem: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_mirrorwall._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let slots = results.compactMap { result -> Slot? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Slot(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.slots = slots }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error), .waiting(let error):
                    // Usually Local Network access is off for the app (Settings › Privacy).
                    self?.problem = "Can't look for slots: \(error.localizedDescription). Allow Local Network for Mirror Wall Cast in Settings › Privacy & Security."
                case .ready:
                    self?.problem = nil
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The slot's address and port, by opening a connection to it and asking where it went. The
    /// Mac closes a connection that never says hello, so this costs nothing.
    nonisolated static func resolve(_ slot: Slot) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: slot.endpoint, using: .tcp)
            let once = Once()
            let finish: @Sendable ((String, UInt16)?) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        var text: String
                        switch host {
                        case .ipv4(let address): text = "\(address)"
                        case .ipv6(let address): text = "\(address)"
                        case .name(let name, _): text = name
                        @unknown default: text = "\(host)"
                        }
                        // Drop an interface suffix ("%en0").
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        finish((text, port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    /// A quick knock: whether something answers at host:port within two seconds.
    nonisolated static func answers(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 2
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
    }
}

/// True for the first caller only, from any thread: so a continuation is resumed exactly once
/// whether the connection answers, fails or times out first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

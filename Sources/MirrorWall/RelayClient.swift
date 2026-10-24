import Foundation
import MirrorCore
import Network

/// Keeps one slot reachable through the Mirror Wall Relay (`relay/`): a connection to the relay
/// that waits, idle, for a phone with the slot's six-digit code. When one joins, the relay says
/// so and the same connection becomes that phone's Cast stream, handed to the slot exactly like
/// a connection `CastServer` accepted; a fresh waiting connection is opened for the next phone.
///
/// Everything here runs on the queue it is given, which is the slot's cast queue, so handed-off
/// connections behave like local ones. Dropped connections are redialed with backoff.
final class RelayClient {
    struct Settings: Equatable {
        var host: String
        var port: UInt16 = 443
        var token: String

        var isUsable: Bool { !host.isEmpty && !token.isEmpty }
    }

    let settings: Settings
    private let slotName: String
    private let deviceID: String
    private let queue: DispatchQueue
    private let onCode: (String?) -> Void
    private let onConnection: (CastConnection) -> Void
    /// A line for the slot's log.
    var log: (String) -> Void = { _ in }

    private var waiting: NWConnection?
    /// Phones handed to the slot; kept alive here until they end, as CastServer keeps its own.
    private var handed: [CastConnection] = []
    private var buffer = Data()
    private var stopped = false
    private var attempts = 0
    private(set) var code: String?

    init(settings: Settings, slot: String, deviceID: String, queue: DispatchQueue,
         onCode: @escaping (String?) -> Void, onConnection: @escaping (CastConnection) -> Void) {
        self.settings = settings
        self.slotName = slot
        self.deviceID = deviceID
        self.queue = queue
        self.onCode = onCode
        self.onConnection = onConnection
    }

    func start() {
        queue.async { [self] in
            stopped = false
            dial()
        }
    }

    /// Drops the waiting connection. A phone already handed to the slot keeps its connection.
    func stop() {
        queue.async { [self] in
            stopped = true
            waiting?.cancel()
            waiting = nil
            for phone in handed { phone.close() }
            handed.removeAll()
            setCode(nil)
        }
    }

    // MARK: Dialing

    private func dial() {
        guard !stopped else { return }
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 10
            tcp.connectionTimeout = 15
            return tcp
        }())
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(settings.host), port: NWEndpoint.Port(rawValue: settings.port)!)
        let connection = NWConnection(to: endpoint, using: parameters)
        waiting = connection
        log("Relay: dialing \(settings.host):\(settings.port) for \(slotName)")
        buffer.removeAll()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.waiting else { return }
            self.log("Relay: \(state)")
            switch state {
            case .ready:
                self.log("Relay: connected to \(self.settings.host), offering \(self.slotName)")
                self.send(["type": "open", "token": self.settings.token, "slot": self.slotName, "device": self.deviceID], on: connection)
                self.readLine(on: connection) { [weak self] line, leftover in
                    self?.gotCode(line, leftover: leftover, on: connection)
                }
            case .failed, .cancelled:
                self.lost(connection)
            case .waiting(let error):
                // No route yet (offline, DNS); NWConnection keeps trying, but a long wait with
                // no code shown is confusing, so redial on a timer instead.
                _ = error
                self.lost(connection)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func gotCode(_ line: [String: Any]?, leftover: Data, on connection: NWConnection) {
        guard connection === waiting else { return }
        guard let line, line["type"] as? String == "code", let code = line["code"] as? String else {
            let reason = line?["reason"] as? String ?? "no answer"
            log("Relay: refused: \(reason)")
            setCode(nil)
            lastError = reason
            lost(connection)
            return
        }
        attempts = 0
        lastError = nil
        setCode(code)
        // Now wait, however long, for a phone. The next line is "joined".
        readLine(on: connection, initial: leftover) { [weak self] line, leftover in
            self?.gotJoined(line, leftover: leftover, on: connection)
        }
    }

    private func gotJoined(_ line: [String: Any]?, leftover: Data, on connection: NWConnection) {
        guard connection === waiting else { return }
        guard let line, line["type"] as? String == "joined" else {
            log("Relay: connection dropped while waiting (\(line?["reason"] as? String ?? "no reason"))")
            lost(connection)
            return
        }
        log("Relay: a phone joined (\(leftover.count) bytes already in)")
        // This connection is a phone's now; the slot takes it over. Open another for the next one.
        waiting = nil
        connection.stateUpdateHandler = nil
        let phone = CastConnection(connection, queue: queue, initialData: leftover, via: "relay \(settings.host)")
        handed.append(phone)
        phone.onEnded = { [weak self, weak phone] in
            self?.handed.removeAll { $0 === phone }
        }
        onConnection(phone)
        phone.start()
        dial()
    }

    /// Something went wrong with the waiting connection; redial with backoff (2, 4, 8… 60 s).
    private(set) var lastError: String?

    private func lost(_ connection: NWConnection) {
        guard connection === waiting else { return }
        waiting = nil
        connection.cancel()
        setCode(nil)
        guard !stopped else { return }
        attempts += 1
        log("Relay: lost the waiting connection (attempt \(attempts)); redialing")
        let delay = min(60, pow(2, Double(min(attempts, 6))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.waiting == nil else { return }
            self.dial()
        }
    }

    private func setCode(_ new: String?) {
        guard new != code else { return }
        code = new
        onCode(new)
    }

    // MARK: Lines

    private func send(_ message: [String: String], on connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Reads up to a newline, hands back the parsed JSON and whatever followed it.
    private func readLine(on connection: NWConnection, initial: Data = Data(), completion: @escaping ([String: Any]?, Data) -> Void) {
        buffer = initial
        func step() {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                let rest = Data(buffer[(newline + 1)...])
                buffer.removeAll()
                let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                completion(parsed, rest)
                return
            }
            guard buffer.count < 4096 else { completion(nil, Data()); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if error != nil || (isComplete && data == nil) {
                    completion(nil, Data())
                    return
                }
                step()
            }
        }
        step()
    }
}

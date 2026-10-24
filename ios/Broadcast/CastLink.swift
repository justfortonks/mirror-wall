import Foundation
import MirrorCore
import Network

/// One phone's connection to a Mirror Wall slot, as the Android app makes it: the slot's direct
/// addresses in order, then the Mirror Wall Relay with the slot's code; then hello, welcome, and
/// video until the broadcast ends. Reconnects to the same target for up to a minute if the
/// connection drops, keeping the share ID so the Mac knows it's the same phone coming back.
///
/// All state lives on `queue`.
final class CastLink {
    enum Event {
        case connecting(String)
        case welcomed(CastWelcome)
        /// The Mac turned this phone away, with the reason to show.
        case refused(String)
        /// The presenter stopped sharing from the Mac; don't come back.
        case stoppedByPresenter
        /// Gave up reconnecting.
        case lost(String)
    }

    var onEvent: ((Event) -> Void)?

    let queue = DispatchQueue(label: "Mirror Wall Cast link", qos: .userInteractive)
    private let target: Shared.Target
    private let hello: CastHello
    private var connection: NWConnection?
    private let reader = CastReader()
    private var welcomed = false
    private var ended = false
    private var lostSince: Date?
    private var heartbeat: DispatchSourceTimer?

    /// Bytes handed to the connection and not yet sent; video is dropped past this, until the next
    /// keyframe, so a slow network makes the picture skip rather than fall behind.
    private var inFlight = 0
    private let maxInFlight = 1_500_000
    private(set) var needsKeyframe = false

    init(target: Shared.Target, hello: CastHello) {
        self.target = target
        self.hello = hello
    }

    func start() { queue.async { self.connect() } }

    /// Ends sharing: a bye, then hang up. Safe from any queue.
    func finish() {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            heartbeat?.cancel()
            if let connection {
                connection.send(content: Data(CastMessage.bye.encoded()), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Sends a message if connected and welcomed. Video past the backlog limit is dropped; the
    /// caller asks the encoder for a keyframe when `needsKeyframe` turns true.
    func send(_ message: CastMessage, isVideo: Bool = false, keyframe: Bool = false) {
        queue.async { [self] in
            guard let connection, welcomed, !ended else { return }
            if isVideo {
                if needsKeyframe && !keyframe { return }
                if inFlight > maxInFlight {
                    needsKeyframe = true
                    return
                }
                needsKeyframe = false
            }
            let data = Data(message.encoded())
            inFlight += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.inFlight -= data.count }
            })
        }
    }

    // MARK: Connecting

    private enum Route {
        case direct(String)
        case relay(String, code: String)
    }

    private var routes: [Route] {
        var routes = target.hosts.map(Route.direct)
        if target.hasRelay, let relay = target.relay, let code = target.code { routes.append(.relay(relay, code: code)) }
        return routes
    }

    private func connect(routeIndex: Int = 0) {
        guard !ended else { return }
        let routes = routes
        guard routeIndex < routes.count else {
            retryOrGiveUp("Couldn't reach \(target.name) at any address\(target.hasRelay ? " or through the relay" : "")")
            return
        }
        let route = routes[routeIndex]
        let connection: NWConnection
        switch route {
        case .direct(let host):
            onEvent?(.connecting("Connecting to \(target.name) at \(host)…"))
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 3
            connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: target.port)!, using: NWParameters(tls: nil, tcp: tcp))
        case .relay(let relay, _):
            onEvent?(.connecting("Connecting to \(target.name) through the relay…"))
            let host = relay.split(separator: ":").first.map(String.init) ?? relay
            let port = relay.split(separator: ":").dropFirst().first.flatMap { UInt16($0) } ?? 443
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
        }
        self.connection = connection
        welcomed = false
        inFlight = 0
        var started = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                guard !started else { return }
                started = true
                Shared.log("Connected: \(connection.endpoint)", from: "broadcast")
                switch route {
                case .direct: self.sayHello(on: connection)
                case .relay(_, let code): self.joinRelay(code: code, on: connection)
                }
            case .failed(let error), .waiting(let error):
                guard !started else {
                    self.dropped("\(error.localizedDescription)")
                    return
                }
                started = true
                Shared.log("No answer at \(connection.endpoint): \(error.localizedDescription)", from: "broadcast")
                connection.cancel()
                self.connect(routeIndex: routeIndex + 1)
            case .cancelled:
                if self.welcomed { self.dropped("cancelled") }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func joinRelay(code: String, on connection: NWConnection) {
        let line = (try? JSONSerialization.data(withJSONObject: ["type": "join", "code": code])) ?? Data()
        connection.send(content: line + Data([0x0A]), completion: .contentProcessed { _ in })
        readLine(on: connection, buffer: Data()) { [weak self] answer, leftover in
            guard let self, connection === self.connection else { return }
            guard let answer, answer["type"] as? String == "joined" else {
                let reason = answer?["reason"] as? String ?? "The relay didn't answer."
                Shared.log("Relay: \(reason)", from: "broadcast")
                connection.cancel()
                self.ended = true
                self.onEvent?(.refused(reason))
                return
            }
            Shared.log("Joined \(self.target.name) through the relay", from: "broadcast")
            self.sayHello(on: connection, leftover: leftover)
        }
    }

    private func sayHello(on connection: NWConnection, leftover: Data = Data()) {
        connection.send(content: Data(CastMessage.hello(hello).encoded()), completion: .contentProcessed { _ in })
        if !leftover.isEmpty { handle(Array(leftover), on: connection) }
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection, !self.ended else { return }
            if let data, !data.isEmpty { self.handle(Array(data), on: connection) }
            if isComplete || error != nil {
                self.dropped(error?.localizedDescription ?? "Mirror Wall closed the connection")
            } else if connection === self.connection {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ bytes: [UInt8], on connection: NWConnection) {
        let messages: [CastMessage]
        do { messages = try reader.push(bytes) } catch {
            dropped("Mirror Wall sent something this app doesn't understand")
            return
        }
        for message in messages {
            switch message {
            case .welcome(let welcome):
                welcomed = true
                lostSince = nil
                needsKeyframe = true
                startHeartbeat(on: connection)
                onEvent?(.welcomed(welcome))
            case .busy(let busy):
                ended = true
                connection.cancel()
                onEvent?(.refused(busy.reason))
            case .ping(let value):
                connection.send(content: Data(CastMessage.pong(value).encoded()), completion: .contentProcessed { _ in })
            case .stopSharing:
                ended = true
                connection.cancel()
                onEvent?(.stoppedByPresenter)
            default:
                break
            }
        }
    }

    private func startHeartbeat(on connection: NWConnection) {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, connection === self.connection, self.welcomed, !self.ended else { return }
            connection.send(content: Data(CastMessage.heartbeat.encoded()), completion: .contentProcessed { _ in })
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: Dropping and coming back

    private func dropped(_ why: String) {
        guard !ended else { return }
        heartbeat?.cancel()
        connection?.cancel()
        connection = nil
        welcomed = false
        Shared.log("Connection ended: \(why)", from: "broadcast")
        retryOrGiveUp(why)
    }

    private func retryOrGiveUp(_ why: String) {
        guard !ended else { return }
        let since = lostSince ?? Date()
        lostSince = since
        guard Date().timeIntervalSince(since) < 60 else {
            ended = true
            onEvent?(.lost(why))
            return
        }
        onEvent?(.connecting("Reconnecting to \(target.name)…"))
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    // MARK: Lines (the relay's handshake)

    private func readLine(on connection: NWConnection, buffer: Data, completion: @escaping ([String: Any]?, Data) -> Void) {
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            completion(try? JSONSerialization.jsonObject(with: line) as? [String: Any], Data(buffer[(newline + 1)...]))
            return
        }
        guard buffer.count < 4096 else { completion(nil, Data()); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard self != nil else { return }
            if error != nil || (isComplete && data == nil) { completion(nil, Data()); return }
            self?.readLine(on: connection, buffer: buffer + (data ?? Data()), completion: completion)
        }
    }
}

import Foundation
import Network
import Security

/// All mutable state/callbacks are confined to queue. One channel per connection;
/// handlers are installed before start. Never admits application bytes before TLS ready.
public final class RadioChannel {
    public let queue: DispatchQueue
    public let connection: NWConnection
    public var snapshot = RadioSnapshot()
    public var onReady: (() -> Void)?
    public var onMessage: ((RadioMessage) throws -> Void)?
    public var onClosed: ((String) -> Void)?
    public var onSample: ((RadioSnapshot) -> Void)?
    public var onTick: (() -> Void)?
    public var protocolVersion: UInt8 = 3 // Fixed before start; production sessions use v3.
    public var active = false
    public private(set) var closed = false
    private var draining = false
    public private(set) var tlsReady = false
    public private(set) var closeCause = RadioCloseCause.protocolFailure
    public var isPreparing: Bool { if case .preparing = connection.state { return true }; return false }
    private var parser = RadioParser()
    private var timer: DispatchSourceTimer?
    private var lastSample = radioNow()
    private var lastSent: UInt64 = 0, lastDelivered: UInt64 = 0
    private var rtt = RadioRTT()
    private var ping: UInt64?
    private let log: RadioLog?
    public init(_ connection: NWConnection, id: UUID = UUID(), log: RadioLog? = nil) {
        self.connection = connection; self.log = log
        queue = DispatchQueue(label: "iosdirect.radio.\(id.uuidString)", qos: .userInitiated)
        snapshot.id = id; snapshot.endpoint = String(describing: connection.endpoint)
    }
    public func event(_ name: String, _ details: String = "") {
        log?.event(name, "connection=\(snapshot.id) \(details)")
    }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            self.snapshot.state = String(describing: state); self.event("connection.state", String(describing: state))
            switch state {
            case .ready:
                guard let tls = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                    self.close("TLS metadata unavailable", cause: .authentication); return
                }
                let metadata = tls.securityProtocolMetadata
                let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
                let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata)
                self.snapshot.tlsVersion = version.rawValue; self.snapshot.cipherSuite = cipher.rawValue
                guard version == .TLSv12, cipher.rawValue == RadioTLS.cipherSuite else {
                    self.close("unexpected TLS negotiation", cause: .authentication); return
                }
                self.event("tls.negotiated", "version=\(version.rawValue) cipher=\(cipher.rawValue)")
                self.snapshot.path = self.connection.currentPath.map(RadioPath.init)
                self.tlsReady = true; self.onReady?()
            // A TLS error (e.g. wrong code) leaves the connection waiting to retry; treat it as final.
            case .waiting(let error):
                switch error {
                case .tls: self.close("handshake failed: \(error)", cause: .authentication)
                case .posix(.ECONNRESET), .posix(.ECONNABORTED), .posix(.EPIPE), .posix(.ENOTCONN):
                    if !self.active { self.close("handshake peer closed: \(error)", cause: .linkLoss) }
                default: break
                }
            case .failed(let error): self.close("connection failed: \(error)", cause: Self.cause(for: error))
            case .cancelled: self.close("connection cancelled", cause: .localStop)
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, !self.closed else { return }; self.snapshot.path = RadioPath(path)
            self.event("connection.path", "\(path)"); self.sample()
        }
        connection.viabilityUpdateHandler = { [weak self] in self?.event("connection.viable", "\($0)") }
        connection.betterPathUpdateHandler = { [weak self] in self?.event("connection.betterPath", "\($0)") }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.onTick?()
            if self.active && !self.draining {
                let now = radioNow()
                if let ping = self.ping {
                    if now - ping > 10_000_000_000 { self.close("pong timeout", cause: .linkLoss); return }
                } else { self.ping = now; self.send(.ping(now)) }
            }
            self.sample()
        }
        self.timer = timer; timer.resume()
        connection.start(queue: queue)
        // Register before ready so a peer close/reset while negotiating TLS can
        // complete this receive instead of waiting for a welcome timeout.
        receive()
    }
    private func receive() {
        guard !closed, !draining else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] content, _, eof, error in
            guard let self, !self.closed, !self.draining else { return }
            do {
                if let content {
                    guard self.tlsReady else { throw RadioError.protocolViolation("application bytes before TLS ready") }
                    self.snapshot.receivedWireBytes += UInt64(content.count)
                    try self.parser.feed(content) { frame in
                        guard !self.closed, !self.draining else { return }
                        let message = try RadioMessage(frame)
                        if frame.version != self.protocolVersion { throw RadioError.protocolViolation("session version changed") }
                        if self.active {
                            switch message {
                            case .ping(let echo): self.send(.pong(echo)); return
                            case .pong(let echo):
                                guard self.ping == echo, radioNow() >= echo else { throw RadioError.protocolViolation("unexpected pong") }
                                self.rtt.add(milliseconds: Double(radioNow() - echo) / 1e6, now: Double(radioNow()) / 1e9)
                                self.ping = nil; return
                            default: break
                            }
                        }
                        try self.onMessage?(message)
                    }
                }
                if let error { self.close("receive: \(error)", cause: Self.cause(for: error)); return }
                if eof { try self.parser.finish(); self.close("EOF", cause: self.tlsReady && !self.active ? .authentication : .linkLoss); return }
                self.receive()
            } catch { self.close(String(describing: error), cause: self.tlsReady && !self.active ? .authentication : .protocolFailure) }
        }
    }
    public func send(_ message: RadioMessage, completion: (() -> Void)? = nil) {
        guard !closed, !draining else { return }
        do {
            let bytes = try message.frame(version: protocolVersion).encoded()
            guard snapshot.pendingNetworkBytes + bytes.count <= 262_144 else { close("network send backlog limit"); return }
            snapshot.pendingNetworkBytes += bytes.count
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                self.snapshot.pendingNetworkBytes -= bytes.count
                if let error { self.close("send: \(error)", cause: Self.cause(for: error)); return }
                self.snapshot.sentWireBytes += UInt64(bytes.count)
                switch message {
                case .data(_, _, let payload, _): self.snapshot.sentBytes += UInt64(payload.count)
                case .videoFragment(let fragment): self.snapshot.sentBytes += UInt64(fragment.data.count)
                default: break
                }
                completion?()
            })
        } catch { close(String(describing: error)) }
    }
    public func finish(_ message: RadioMessage, reason: String) {
        guard !closed, !draining else { return }
        send(message) { [weak self] in self?.close(reason) }
        draining = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(reason) }
    }
    public func sample() {
        let now = radioNow(), seconds = Double(now - lastSample) / 1e9
        if seconds >= 0.5 {
            snapshot.sentMbit = Double(snapshot.sentBytes - lastSent) * 8 / seconds / 1e6
            snapshot.deliveredMbit = Double(snapshot.deliveredBytes - lastDelivered) * 8 / seconds / 1e6
            lastSent = snapshot.sentBytes; lastDelivered = snapshot.deliveredBytes; lastSample = now
        }
        snapshot.monotonicNs = now; snapshot.wallTime = ISO8601DateFormatter().string(from: Date())
        let values = rtt.values(now: Double(now) / 1e9)
        snapshot.rttMedianMS = values.0; snapshot.rttP95MS = values.1
        snapshot.thermal = radioThermalState()
        snapshot.residentMemoryMB = radioMemoryMB()
        log?.write(snapshot); onSample?(snapshot)
    }
    private static func cause(for error: NWError) -> RadioCloseCause {
        if case .tls = error { return .authentication }; return .linkLoss
    }
    public func close(_ reason: String, cause: RadioCloseCause = .protocolFailure) {
        guard !closed else { return }; closeCause = cause; closed = true; active = false
        snapshot.error = reason; snapshot.state = "closed"; timer?.cancel(); timer = nil
        event("connection.closed", reason); sample(); connection.cancel(); onClosed?(reason)
    }
    deinit { timer?.cancel(); connection.cancel() }
}

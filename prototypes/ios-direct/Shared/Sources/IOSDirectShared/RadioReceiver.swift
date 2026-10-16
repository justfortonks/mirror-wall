import Foundation
import Network

private final class ReceiverSessionState {
    var helloSeen = false
    var admitted = false
    var expected: UInt64 = 0
}

/// Admission is serialized here; parsing, payload validation, metrics and sends
/// remain on the individual channel queues. No display label is a routing key.
public final class RadioReceiver {
    private let queue = DispatchQueue(label: "iosdirect.radio.listener")
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var channels: [UUID: RadioChannel] = [:]
    private var pending = Set<UUID>()
    private var active: [UUID: UUID] = [:] // Session -> install UUID (self-reported, not G3 identity).
    private var generation = UUID()
    private var state = "stopped"
    private let label: String
    private let log: RadioLog?
    // Configure callbacks before start; retain the receiver until stop.
    public var onState: ((String, NWEndpoint.Port?) -> Void)?
    public var onSample: ((RadioSnapshot) -> Void)?
    public var onRemoved: ((UUID) -> Void)?
    public var onEvent: ((String) -> Void)?
    public var onData: ((UUID, Int) -> Void)? // Metadata-only test/diagnostic hook; session queue.
    public init(label: String, log: RadioLog? = nil) { self.label = String(label.prefix(60)); self.log = log }
    private func event(_ name: String, _ details: String = "") { log?.event(name, details); onEvent?("\(name) \(details)") }
    public func start(code: RadioCode, advertise: Bool = true, loopbackOnly: Bool = false) {
        queue.async { [self] in
            stopOnQueue(); let run = generation
            do {
                let parameters = RadioTLS.parameters(code: code)
                if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                if advertise { listener.service = NWListener.Service(name: label, type: RadioTLS.service) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == run else { return }
                    self.state = String(describing: state); self.event("listener.state", self.state)
                    self.onState?(self.state, self.listener?.port)
                    if case .failed = state {
                        let failure = self.state; self.stopOnQueue()
                        self.state = failure; self.onState?(failure, nil)
                    }
                }
                listener.serviceRegistrationUpdateHandler = { [weak self] change in self?.event("listener.service", String(describing: change)) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, run: run) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.event("listener.sample", "state=\(self.state) active=\(self.active.count) pending=\(self.pending.count) thermal=\(radioThermalState()) memoryMB=\(radioMemoryMB().map { String($0) } ?? "unavailable")")
                }
                self.timer = timer; timer.resume(); listener.start(queue: queue)
            } catch { state = "failed: \(error)"; event("listener.error", state); onState?(state, nil) }
        }
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        generation = UUID(); timer?.cancel(); timer = nil; listener?.cancel(); listener = nil
        event("listener.stopped")
        for (id, channel) in channels { channel.queue.async { channel.close("receiver stopped / new code") }; onRemoved?(id) }
        channels.removeAll(); pending.removeAll(); active.removeAll(); state = "stopped"; onState?(state, nil)
    }
    private func accept(_ connection: NWConnection, run: UUID) {
        guard generation == run else { connection.cancel(); return }
        guard pending.count < 2 else {
            // Cannot send an authenticated application reject without starting a third
            // handshake. Enforce pending cap before start; active-cap rejects use TLS.
            event("listener.capacity", "pending handshake limit; transport closed"); connection.cancel(); return
        }
        let id = UUID(), channel = RadioChannel(connection, id: id, log: log)
        channels[id] = channel; pending.insert(id)
        let session = ReceiverSessionState()
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            if !session.helloSeen {
                guard case let .hello(install, label, version, rate) = message else { throw RadioError.protocolViolation("hello required") }
                session.helloSeen = true; channel.snapshot.label = label; channel.snapshot.installID = install
                self.queue.async {
                    guard self.generation == run, self.pending.contains(id), self.channels[id] === channel else { return }
                    let rejection: String?
                    if version != 1 { rejection = "version" }
                    else if self.active.count >= 2 { rejection = "capacity" }
                    else if self.active.values.contains(install) { rejection = "busy" }
                    else if ![2, 6, 12, 24].contains(rate) { rejection = "version" }
                    else { rejection = nil }
                    if let rejection {
                        self.event("session.reject", "session=\(id) reason=\(rejection)")
                        channel.queue.async { channel.finish(.reject(rejection), reason: "reject \(rejection)") }
                    } else {
                        self.pending.remove(id); self.active[id] = install
                        self.event("session.admit", "session=\(id) install=\(install)")
                        channel.queue.async {
                            guard !channel.closed else { return }; session.admitted = true; channel.active = true
                            channel.send(.welcome(session: id, label: self.label)); channel.sample()
                        }
                    }
                }
                return
            }
            guard session.admitted else { throw RadioError.protocolViolation("payload before welcome") }
            switch message {
            case let .data(seq, time, payload, crc):
                guard !payload.isEmpty else { throw RadioError.protocolViolation("empty data") }
                if RadioCRC32.checksum(payload) != crc {
                    channel.snapshot.crcFailures += 1; throw RadioError.protocolViolation("CRC failure")
                }
                guard seq >= session.expected, seq != UInt64.max else { throw RadioError.protocolViolation("sequence regression/overflow") }
                channel.snapshot.seqGaps += seq - session.expected; session.expected = seq + 1
                channel.snapshot.deliveredBytes += UInt64(payload.count)
                channel.send(.ack(seq: seq, time: time, total: channel.snapshot.deliveredBytes))
                self.onData?(id, payload.count)
            case .bye(let reason): channel.close("peer bye: \(reason)")
            default: throw RadioError.protocolViolation("unexpected receiver message")
            }
        }
        channel.onTick = { [weak channel] in
            guard let channel, channel.active, let json = try? JSONEncoder().encode(channel.snapshot) else { return }
            channel.send(.stats(json))
        }
        channel.onSample = { [weak self] sample in
            self?.queue.async { [weak self] in
                guard let self, self.generation == run, self.channels[id] != nil else { return }
                self.onSample?(sample)
            }
        }
        channel.onClosed = { [weak self] reason in
            self?.queue.async { [weak self] in
                guard let self, self.generation == run else { return }
                self.channels.removeValue(forKey: id); self.pending.remove(id); self.active.removeValue(forKey: id)
                self.event("session.removed", "session=\(id) reason=\(reason)"); self.onRemoved?(id)
            }
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak channel] in
            guard let self, self.generation == run, self.pending.contains(id), let channel else { return }
            channel.queue.async { channel.close("5 s TLS/hello timeout") }
        }
    }
    deinit { timer?.cancel(); listener?.cancel(); for channel in channels.values { channel.connection.cancel() } }
}

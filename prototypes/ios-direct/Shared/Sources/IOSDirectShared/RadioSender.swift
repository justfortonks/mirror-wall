import Foundation
import Network

public final class RadioSender {
    private let channel: RadioChannel
    private var pacer: RadioPacer
    private var timer: DispatchSourceTimer?
    private var seq: UInt64 = 0
    private var sending = false
    private struct Outstanding { let bytes: Int; let payload: Int; let time: UInt64 }
    private var outstanding: [UInt64: Outstanding] = [:]
    private var lastAck: UInt64?
    private var total: UInt64 = 0
    private var welcomed = false
    private var challenged = false
    private var lastBlockedMS: Double = 0
    private var lastPacerSample = radioNow()
    public var onState: ((String) -> Void)?
    public var onSample: ((RadioSnapshot) -> Void)?
    public var onReceiverStats: ((RadioSnapshot) -> Void)?
    public init(endpoint: NWEndpoint, credential: DeviceCredential, rate: Int, window: RadioWindowMode = .latency, install: UUID, label: String, log: RadioLog? = nil) {
        channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(credential: credential)), log: log)
        pacer = RadioPacer(mbit: rate, window: window)
        channel.snapshot.installID = install; channel.snapshot.label = String(label.prefix(60))
        channel.snapshot.windowMode = window; channel.snapshot.windowBytes = pacer.cap
        channel.snapshot.sendBlockedMSPerSecond = 0
        channel.snapshot.deviceID = credential.deviceID
        channel.onReady = { [weak self] in self?.onState?("TLS ready; awaiting welcome") }
        channel.onMessage = { [weak self] message in
            guard let self else { return }
            if case .authChallenge = message {
                guard !self.challenged else { throw RadioError.protocolViolation("duplicate challenge") }
                self.challenged = true
                _ = try credential.authenticate(message, on: self.channel)
                self.channel.send(.hello(install: install, label: String(label.prefix(60)), version: 3, rate: UInt32(rate), window: window))
                return
            }
            if case .welcome = message, !self.challenged { throw RadioError.protocolViolation("authentication required") }
            try self.receive(message)
        }
        channel.onClosed = { [weak self] reason in
            guard let self else { return }; self.timer?.cancel(); self.timer = nil
            self.outstanding.removeAll(); self.channel.snapshot.outstandingBytes = 0
            let text = !self.welcomed && reason != "stopped" && !reason.hasPrefix("reject ")
                ? "Not paired anymore (revoked), or handshake failed: \(reason)" : reason
            if text != reason { self.channel.event("sender.handshakeFailed", text) }
            self.onState?(text)
        }
        channel.onSample = { [weak self] in self?.onSample?($0) }
        channel.onTick = { [weak self] in
            guard let self else { return }
            self.pump(); self.samplePacer()
            if self.channel.active, let json = try? JSONEncoder().encode(self.channel.snapshot) {
                self.channel.send(.stats(json))
            }
        }
    }
    public func start() {
        channel.start()
        // NWConnection may remain preparing while racing paths after a peer TLS
        // rejection. Bound that silent case as well as handling explicit errors.
        channel.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.channel.active, !self.channel.closed else { return }
            self.channel.close("TLS/auth/welcome deadline (5 s)")
        }
    }
    public func stop() {
        channel.queue.async { [self] in
            timer?.cancel(); timer = nil
            if channel.active { channel.finish(.bye("user stop"), reason: "stopped") }
            else { channel.close("stopped") }
        }
    }
    private func receive(_ message: RadioMessage) throws {
        switch message {
        case let .welcome(id, _):
            guard !channel.active else { throw RadioError.protocolViolation("duplicate welcome") }
            welcomed = true; channel.active = true; channel.snapshot.id = id
            lastPacerSample = radioNow(); onState?("sending synthetic payload")
            let timer = DispatchSource.makeTimerSource(queue: channel.queue)
            timer.schedule(deadline: .now(), leeway: .microseconds(100))
            timer.setEventHandler { [weak self] in self?.pump() }; self.timer = timer; timer.resume()
        case let .ack(seq, time, received):
            guard channel.active, let item = outstanding.removeValue(forKey: seq), item.time == time,
                  lastAck.map({ seq > $0 }) ?? true, received == total + UInt64(item.payload) else {
                throw RadioError.protocolViolation("invalid ACK")
            }
            lastAck = seq; total = received
            channel.snapshot.outstandingBytes -= item.bytes; channel.snapshot.deliveredBytes = received
            pump()
        case .stats(let json):
            guard channel.active else { throw RadioError.protocolViolation("stats before welcome") }
            let stats = try JSONDecoder().decode(RadioSnapshot.self, from: json)
            guard stats.id == channel.snapshot.id else { throw RadioError.protocolViolation("wrong stats session") }
            channel.snapshot.seqGaps = stats.seqGaps; channel.snapshot.crcFailures = stats.crcFailures
            onReceiverStats?(stats)
        case .reject(let reason): channel.close("reject \(reason)")
        case .bye(let reason): channel.close("peer bye: \(reason)")
        default: throw RadioError.protocolViolation("unexpected sender message")
        }
    }
    private func pump() {
        guard channel.active, !channel.closed else { return }
        let ns = radioNow(), now = Double(ns) / 1e9
        if let oldest = outstanding.values.map(\.time).min(), ns - oldest > 10_000_000_000 {
            channel.close("ACK timeout"); return
        }
        guard pacer.canSend(now: now, outstanding: channel.snapshot.outstandingBytes, sending: sending) else {
            // ACK/send completion wakes a capped sender; no polling or queued payload.
            if !sending, channel.snapshot.outstandingBytes + pacer.chunk + 30 <= pacer.cap {
                timer?.schedule(deadline: .now() + max(0.0001, pacer.delay(now: now)), leeway: .microseconds(100))
            } else { timer?.schedule(deadline: .distantFuture) }
            return
        }
        timer?.schedule(deadline: .distantFuture)
        let payload = SyntheticPayload.make(seq: seq, count: pacer.chunk)
        let message = RadioMessage.data(seq: seq, time: ns, payload: payload, crc: RadioCRC32.checksum(payload))
        outstanding[seq] = Outstanding(bytes: payload.count + 30, payload: payload.count, time: ns)
        channel.snapshot.outstandingBytes += payload.count + 30
        seq += 1; sending = true; pacer.sent(now: now, payloadBytes: payload.count)
        channel.send(message) { [weak self] in self?.sending = false; self?.pump() }
    }
    private func samplePacer() {
        let now = radioNow(), blocked = pacer.blockedMS(now: Double(now) / 1e9)
        let seconds = Double(now - lastPacerSample) / 1e9
        channel.snapshot.sendBlockedMS = blocked
        if seconds > 0 { channel.snapshot.sendBlockedMSPerSecond = (blocked - lastBlockedMS) / seconds }
        lastBlockedMS = blocked; lastPacerSample = now
    }
    deinit { timer?.cancel(); channel.connection.cancel() }
}

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
    public var onState: ((String) -> Void)?
    public var onSample: ((RadioSnapshot) -> Void)?
    public var onReceiverStats: ((RadioSnapshot) -> Void)?
    public init(endpoint: NWEndpoint, code: RadioCode, rate: Int, install: UUID, label: String, log: RadioLog? = nil) {
        channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(code: code)), log: log)
        pacer = RadioPacer(mbit: rate)
        channel.snapshot.installID = install; channel.snapshot.label = String(label.prefix(60))
        channel.onReady = { [weak self] in
            guard let self else { return }
            self.onState?("TLS ready; awaiting welcome")
            self.channel.send(.hello(install: install, label: String(label.prefix(60)), version: 1, rate: UInt32(rate)))
        }
        channel.onMessage = { [weak self] in try self?.receive($0) }
        channel.onClosed = { [weak self] reason in
            guard let self else { return }; self.timer?.cancel(); self.timer = nil
            self.outstanding.removeAll(); self.channel.snapshot.outstandingBytes = 0
            let text = self.channel.snapshot.tlsVersion == nil && reason != "stopped" ? "wrong code / handshake failed: \(reason)" : reason
            self.onState?(text)
        }
        channel.onSample = { [weak self] in self?.onSample?($0) }
        channel.onTick = { [weak self] in self?.pump(); self?.samplePacer() }
    }
    public func start() {
        channel.start()
        channel.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.channel.active, !self.channel.closed else { return }
            self.channel.close("TLS/welcome timeout")
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
            channel.active = true; channel.snapshot.id = id; onState?("sending synthetic payload")
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
    private func samplePacer() { channel.snapshot.sendBlockedMS = pacer.blockedMS(now: Double(radioNow()) / 1e9) }
    deinit { timer?.cancel(); channel.connection.cancel() }
}

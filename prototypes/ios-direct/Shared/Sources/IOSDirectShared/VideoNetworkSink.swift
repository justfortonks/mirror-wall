import Foundation
import Network

public struct VideoSendSnapshot: Codable {
    public var state = "idle"
    public var session: UUID?
    public var sent = 0, acked = 0, decodedAcks = 0, sentBytes = 0
    public var queueBytes = 0, queueAgeMS: Double = 0, outstandingBytes = 0
    public var drops: [String: Int] = [:]
    public var keyframeRequests = 0, reconnects = 0, reconnectAttempts = 0
    public var rttP50MS: Double?, rttP95MS: Double?
    public init() {}
}

/// Encoder admission is synchronous under lock, so encoded data cannot accumulate in
/// dispatch blocks. A separate worker owns connection/retry/fragment sends. The single
/// in-flight frame is charged to the G2 latency window before its first fragment.
public final class VideoNetworkSink {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "iosdirect.video.network", qos: .userInitiated)
    private var pending = VideoSendQueue()
    private var encoderGeneration = 0
    private var config: VideoConfig?
    private var ready = false
    private var workerScheduled = false
    private var value = VideoSendSnapshot()
    private var channel: RadioChannel?
    private var timer: DispatchSourceTimer?
    private var run = UUID()
    private var retryDelay = 0.5
    private var stopped = true
    private var everWelcomed = false
    private var sequence: UInt64 = 0
    private var wireGeneration: UInt32 = 0
    private var sentConfig: UInt32?
    private var sending: (frame: VideoAccessUnit, config: VideoConfig, fragments: [VideoFragment], index: Int)?
    private struct Outstanding { let bytes: Int; let pts: UInt64; let sentAt: UInt64 }
    private var outstanding: [UInt64: Outstanding] = [:]
    private var rtt = RadioRTT()
    private let cap = RadioWindowMode.latency.bytes(mbit: 6)
    /// Installed once, before start. These callbacks must return quickly.
    public var requestIDR: (() -> Void)?
    public var onState: ((String, Bool) -> Void)?
    public var onEvent: ((String, String) -> Void)?
    public var onRadioSample: ((RadioSnapshot) -> Void)?
    public init() {}
    public func snapshot() -> VideoSendSnapshot {
        lock.lock(); defer { lock.unlock() }
        var result = value; result.queueBytes = pending.bytes
        result.queueAgeMS = pending.age(now: Double(radioNow()) / 1e9) * 1000
        result.drops = pending.drops.merging(value.drops, uniquingKeysWith: +)
        return result
    }
    private func update(_ body: (inout VideoSendSnapshot) -> Void) { lock.lock(); body(&value); lock.unlock() }
    private func event(_ name: String, _ details: String = "") { onEvent?(name, details) }
    private func state(_ text: String, ready: Bool) {
        lock.lock(); self.ready = ready; value.state = text; lock.unlock()
        event("video.connection", text); onState?(text, ready)
    }
    public func start(endpoint: NWEndpoint, code: RadioCode, install: UUID, label: String, log: RadioLog? = nil) {
        queue.async {
            self.stopOnQueue(); self.stopped = false; self.everWelcomed = false; self.retryDelay = 0.5
            let run = self.run
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
            self.connect(endpoint: endpoint, code: code, install: install, label: label, log: log, run: run)
        }
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        stopped = true; run = UUID(); timer?.cancel(); timer = nil
        let old = channel; channel = nil
        old?.queue.async { if old?.active == true { old?.finish(.bye("user stop"), reason: "stopped") } else { old?.close("stopped") } }
        lock.lock(); ready = false; pending.discontinuity("disconnect"); lock.unlock()
        outstanding.removeAll(); sending = nil; sentConfig = nil
        update { $0.outstandingBytes = 0 }; state("disconnected", ready: false)
    }
    private func connect(endpoint: NWEndpoint, code: RadioCode, install: UUID, label: String, log: RadioLog?, run: UUID) {
        guard !stopped, self.run == run else { return }
        state(everWelcomed ? "reconnecting" : "connecting with TLS-PSK", ready: false)
        let channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(code: code)), log: log)
        self.channel = channel; channel.protocolVersion = 2
        channel.snapshot.installID = install; channel.snapshot.label = String(label.prefix(60)); channel.snapshot.mode = .video
        channel.snapshot.windowMode = .latency; channel.snapshot.windowBytes = cap
        channel.onReady = { [weak channel] in
            channel?.send(.hello(install: install, label: String(label.prefix(60)), version: 2, rate: 6, mode: .video))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            if !channel.active {
                switch message {
                case .welcome, .reject: break
                default: throw RadioError.protocolViolation("message before welcome")
                }
            }
            switch message {
            case .stats: return // Do not copy unused JSON into a second dispatch queue.
            case .welcome, .reject, .videoAck, .keyframeRequest, .bye: break
            default: throw RadioError.protocolViolation("unexpected video sender message")
            }
            // Activate ping/pong interception immediately on the channel queue.
            if case .welcome(let id, _) = message {
                guard !channel.active else { throw RadioError.protocolViolation("duplicate welcome") }
                channel.active = true; channel.snapshot.id = id
            }
            self.queue.async { [weak self, weak channel] in
                guard let self, let channel, self.channel === channel, self.run == run else { return }
                self.receive(message, channel: channel)
            }
        }
        channel.onSample = { [weak self] in self?.onRadioSample?($0) }
        channel.onClosed = { [weak self, weak channel] reason in
            self?.queue.async { [weak self, weak channel] in
                guard let self, let channel, self.channel === channel, self.run == run, !self.stopped else { return }
                self.channel = nil; self.sending = nil; self.outstanding.removeAll(); self.sentConfig = nil
                self.lock.lock(); self.ready = false; self.pending.discontinuity("disconnect"); self.lock.unlock()
                self.update { $0.outstandingBytes = 0 }
                let delay = self.retryDelay; self.retryDelay = min(4, delay * 2)
                self.state("reconnecting", ready: false)
                self.event("video.reconnectScheduled", "delay=\(delay) reason=\(reason)")
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.run == run, !self.stopped else { return }
                    self.update { $0.reconnectAttempts += 1 }
                    self.connect(endpoint: endpoint, code: code, install: install, label: label, log: log, run: run)
                }
            }
        }
        channel.start()
        channel.queue.asyncAfter(deadline: .now() + 1.5) { [weak channel] in
            guard let channel, !channel.active else { return }; channel.close("TLS/welcome deadline (1.5 s)")
        }
    }
    private func receive(_ message: RadioMessage, channel: RadioChannel) {
        switch message {
        case .welcome(let session, _):
            lock.lock(); pending.discontinuity("reconnect"); ready = true; lock.unlock()
            wireGeneration &+= 1; sentConfig = nil; sequence = 0; rtt = RadioRTT()
            update { $0.session = session; $0.rttP50MS = nil; $0.rttP95MS = nil; if everWelcomed { $0.reconnects += 1 } }
            event("video.welcome", "session=\(session) reconnect=\(everWelcomed)")
            everWelcomed = true; retryDelay = 0.5; state("authenticated; ready to share", ready: true)
            requestIDR?(); pump()
        case let .videoAck(seq, pts, status):
            guard let item = outstanding.removeValue(forKey: seq), item.pts == pts else {
                channel.queue.async { channel.close("invalid video ACK") }; return
            }
            let now = radioNow()
            rtt.add(milliseconds: Double(now - item.sentAt) / 1e6, now: Double(now) / 1e9)
            let percentiles = rtt.values(now: Double(now) / 1e9)
            update {
                $0.acked += 1; if status == .decoded { $0.decodedAcks += 1 }
                $0.outstandingBytes -= item.bytes; $0.rttP50MS = percentiles.0; $0.rttP95MS = percentiles.1
            }
            if status != .decoded { discontinuity("receiverDrop") }
            pump()
        case .keyframeRequest(let reason):
            update { $0.keyframeRequests += 1 }; event("video.keyframeRequest", reason)
            discontinuity("keyframeRequest")
        case .stats: break // Receiver's transport diagnostics remain in its radio log.
        case .reject(let reason): channel.queue.async { channel.close("reject \(reason)") }
        case .bye(let reason): channel.queue.async { channel.close("peer bye: \(reason)") }
        default: channel.queue.async { channel.close("unexpected video sender message") }
        }
    }
    public func begin(encoderGeneration: Int) {
        lock.lock(); self.encoderGeneration = encoderGeneration; config = nil
        pending.discontinuity("generation"); lock.unlock()
        // The old in-flight unit is completed in order. No later generation can be sent
        // before it; fresh config is emitted immediately before the next admitted IDR.
    }
    public func discontinuity(_ reason: String) {
        lock.lock(); pending.discontinuity(reason); lock.unlock(); requestIDR?()
    }
    public func offer(_ data: Data, ptsNs: UInt64, keyframe: Bool, encoderGeneration: Int, config nextConfig: VideoConfig?) {
        lock.lock()
        guard encoderGeneration == self.encoderGeneration else { lock.unlock(); return }
        if let nextConfig { config = nextConfig }
        guard ready, config != nil else {
            value.drops[ready ? "missingConfig" : "disconnected", default: 0] += 1; lock.unlock(); return
        }
        // Sequence and wire generation are assigned by the worker, after bounded admission.
        let unit = VideoAccessUnit(generation: UInt32(truncatingIfNeeded: encoderGeneration), seq: 0, ptsNs: ptsNs, keyframe: keyframe, data: data)
        let wasWaiting = pending.waitingForKeyframe
        let accepted = pending.offer(unit, now: Double(radioNow()) / 1e9)
        let needsIDR = pending.waitingForKeyframe
        if accepted && !workerScheduled {
            workerScheduled = true
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.workerScheduled = false; self.lock.unlock(); self.pump()
            }
        }
        lock.unlock()
        if needsIDR || wasWaiting && !accepted { requestIDR?() }
    }
    private func pump() {
        guard !stopped, let channel else { return }
        lock.lock()
        let wasWaiting = pending.waitingForKeyframe
        pending.expire(now: Double(radioNow()) / 1e9)
        let needsIDR = !wasWaiting && pending.waitingForKeyframe
        let ready = self.ready
        lock.unlock()
        if needsIDR { requestIDR?() }
        guard ready else { return }
        let now = radioNow()
        if outstanding.values.contains(where: { now - $0.sentAt > 10_000_000_000 }) {
            channel.queue.async { channel.close("video ACK timeout") }; return
        }
        guard sending == nil else { return }
        lock.lock()
        guard let first = pending.peek(), let config else { lock.unlock(); return }
        // A frame larger than the window (typically an IDR) goes alone when nothing is in flight;
        // dropping it would request another IDR of the same size and never recover.
        let fits = value.outstandingBytes + first.wireBytes <= cap
        guard fits || value.outstandingBytes == 0,
              let frame = pending.pop(now: Double(now) / 1e9) else { lock.unlock(); return }
        if !fits { value.drops["oversizeAdmittedAlone", default: 0] += 1 }
        lock.unlock()
        // A generation switch or reconnect always starts with config and an IDR.
        if sentConfig != frame.generation {
            wireGeneration &+= 1; sentConfig = frame.generation
        }
        let wire = VideoAccessUnit(generation: wireGeneration, seq: sequence, ptsNs: frame.ptsNs, keyframe: frame.keyframe, data: frame.data)
        sequence &+= 1
        guard let fragments = try? wire.fragments() else { discontinuity("fragmentation"); return }
        outstanding[wire.seq] = Outstanding(bytes: wire.wireBytes, pts: wire.ptsNs, sentAt: now)
        update { $0.outstandingBytes += wire.wireBytes }
        let wireConfig = config.withGeneration(wireGeneration)
        sending = (wire, wireConfig, fragments, 0)
        // Repeating config on every IDR also repairs a missing-config receiver.
        if wire.keyframe {
            channel.queue.async { [weak self, weak channel] in
                guard let channel else { return }
                channel.send(.videoConfig(wireConfig)) { self?.queue.async { self?.sendFragment(channel) } }
            }
        } else { sendFragment(channel) }
    }
    private func sendFragment(_ channel: RadioChannel) {
        guard self.channel === channel, let sending else { return }
        let fragment = sending.fragments[sending.index]
        channel.queue.async { [weak self, weak channel] in
            guard let channel else { return }
            channel.send(.videoFragment(fragment)) {
                self?.queue.async { [weak self, weak channel] in
                    guard let self, let channel, self.channel === channel, var sending = self.sending else { return }
                    sending.index += 1
                    if sending.index == sending.fragments.count {
                        self.update { $0.sent += 1; $0.sentBytes += sending.frame.data.count }
                        self.sending = nil; self.pump()
                    } else { self.sending = sending; self.sendFragment(channel) }
                }
            }
        }
    }
    deinit { timer?.cancel(); channel?.connection.cancel() }
}

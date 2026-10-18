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
    private var orientationHints: [OrientationSource: OrientationHint] = [:] // Lock; at most two metadata values.
    private var sentOrientationHints: [OrientationSource: OrientationHint] = [:] // Worker only.
    private var orientationSendPending = false
    private var lastOrientationSend: UInt64?
    private var ready = false
    private var workerScheduled = false
    private var value = VideoSendSnapshot()
    private var channel: RadioChannel?
    private var timer: DispatchSourceTimer?
    private var run = UUID()
    private var backoff = ReconnectBackoff()
    private var reconnectAllowed = true
    private var needsReconnect = false
    private var retryWork: DispatchWorkItem?
    private var resolution = UUID()
    private var resolvingReceiver = false
    private var retryConnection: (() -> Void)?
    private var stopped = true
    private var policy = ClientSessionPolicy()
    private var receiverDiscovered = false
    private var sequence: UInt64 = 0
    private var wireGeneration: UInt32 = 0
    private var sentConfig: UInt32?
    private var sending: (frame: VideoAccessUnit, config: VideoConfig, fragments: [VideoFragment], index: Int)?
    private struct Outstanding { let bytes: Int; let pts: UInt64; let sentAt: UInt64 }
    private var outstanding: [UInt64: Outstanding] = [:]
    private var rtt = RadioRTT()
    /// Installed once, before start. These callbacks must return quickly.
    public var requestIDR: (() -> Void)?
    public var onState: ((String, Bool) -> Void)?
    public var onEvent: ((String, String) -> Void)?
    public var onStopped: (() -> Void)?
    public var onUnreachable: (() -> Void)?
    public var onPairingRejected: ((UUID, PairingRejection) -> Void)?
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
    public func start(endpoint: NWEndpoint, credential: DeviceCredential, install: UUID, label: String, log: RadioLog? = nil, receiverDiscovered: Bool = false, pairingStore: PairingKeyStore? = nil,
                      refreshReceiver: ((@escaping (NWEndpoint?) -> Void) -> Void)? = nil) {
        queue.async {
            self.stopOnQueue(); self.stopped = false; self.policy = ClientSessionPolicy(); self.backoff = ReconnectBackoff()
            self.receiverDiscovered = receiverDiscovered
            let run = self.run
            self.retryConnection = { [weak self] in
                guard let self else { return }
                self.resolveReceiver(refreshReceiver, credential: credential, install: install, label: label,
                                     log: log, pairingStore: pairingStore, run: run)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
            self.connect(endpoint: endpoint, credential: credential, install: install, label: label, log: log, pairingStore: pairingStore, run: run)
        }
    }
    public func setReceiverDiscovered(_ discovered: Bool) { queue.async { self.receiverDiscovered = discovered } }
    /// Keep recovery available during runnable background capture. Once capture
    /// ends and suspension is possible, admission waits for fresh foreground discovery.
    public func setRecoveryAllowed(_ active: Bool) {
        queue.async {
            self.reconnectAllowed = active
            if !active {
                self.receiverDiscovered = false
                self.retryWork?.cancel(); self.retryWork = nil; self.resolution = UUID(); self.resolvingReceiver = false
                if let channel = self.channel { channel.queue.async {
                    if !channel.active { channel.close("admission interrupted by background", cause: .admissionDeadline(tlsReady: channel.tlsReady, preparing: channel.isPreparing)) }
                } }
            } else if self.needsReconnect { self.scheduleReconnect(reason: "foreground recovery") }
        }
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        stopped = true; run = UUID(); timer?.cancel(); timer = nil
        retryWork?.cancel(); retryWork = nil; resolution = UUID(); resolvingReceiver = false; needsReconnect = false; retryConnection = nil
        let old = channel; channel = nil
        old?.queue.async { if old?.active == true { old?.finish(.bye("user stop"), reason: "stopped") } else { old?.close("stopped", cause: .localStop) } }
        lock.lock(); ready = false; pending.discontinuity("disconnect"); lock.unlock()
        outstanding.removeAll(); sending = nil; sentConfig = nil
        update { $0.outstandingBytes = 0 }; state("disconnected", ready: false)
    }
    private func connect(endpoint: NWEndpoint, credential: DeviceCredential, install: UUID, label: String, log: RadioLog?, pairingStore: PairingKeyStore?, run: UUID) {
        guard !stopped, self.run == run else { return }
        policy.beginAttempt()
        state(policy.everWelcomed || needsReconnect ? "Reconnecting…" : "connecting with TLS-PSK", ready: false)
        needsReconnect = false
        let channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(credential: credential)), log: log)
        self.channel = channel; channel.protocolVersion = 3
        channel.snapshot.installID = install; channel.snapshot.label = String(label.prefix(60)); channel.snapshot.mode = .video
        channel.snapshot.windowMode = .latency; channel.snapshot.windowBytes = StreamSettings().latencyWindowBytes
        channel.snapshot.deviceID = credential.deviceID
        var challenged = false
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            if case .authChallenge = message {
                guard !challenged else { throw RadioError.protocolViolation("duplicate challenge") }
                challenged = true
                _ = try credential.authenticate(message, on: channel)
                channel.send(.hello(install: install, label: String(label.prefix(60)), version: 3, rate: 6, mode: .video))
                return
            }
            if case .welcome = message, !challenged { throw RadioError.protocolViolation("authentication required") }
            if !channel.active {
                switch message {
                case .welcome, .reject, .bye: break
                default: throw RadioError.protocolViolation("message before welcome")
                }
            }
            switch message {
            case .bye(let reason): channel.close("peer bye: \(reason)", cause: reason == "revoked" ? .revoked : .peerEnded); return
            case .reject(let reason): channel.close("reject \(reason)", cause: .rejected(reason)); return
            case .stats: return // Do not copy unused JSON into a second dispatch queue.
            case .welcome, .videoAck, .keyframeRequest: break
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
                let action = self.policy.action(for: channel.closeCause, receiverDiscovered: self.receiverDiscovered)
                switch action {
                case .pairingRejected(let rejection):
                    self.stopped = true; self.timer?.cancel(); self.timer = nil
                    if let pairingStore {
                        do { try rejection.apply(to: pairingStore, rid: credential.rid, deviceID: credential.deviceID) }
                        catch { self.event("pairing.storageError", "could not remove revoked credential") }
                    }
                    self.state(rejection.message, ready: false); self.onPairingRejected?(credential.rid, rejection); self.onStopped?()
                    return
                case .unreachable:
                    self.stopped = true; self.timer?.cancel(); self.timer = nil
                    self.state(ClientSessionPolicy.unreachableMessage, ready: false); self.onUnreachable?(); self.onStopped?(); return
                case .stop:
                    self.stopped = true; self.timer?.cancel(); self.timer = nil
                    self.state(channel.closeCause == .linkLoss ? "Disconnected — tap Connect" : reason, ready: false); self.onStopped?(); return
                case .retry: break
                }
                self.scheduleReconnect(reason: reason)
            }
        }
        channel.start()
        channel.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak channel] in
            guard let self, let channel, !channel.active else { return }; self.queue.async { [weak self, weak channel] in
                guard let self, let channel, self.channel === channel, self.run == run else { return }
                channel.queue.async { guard !channel.active else { return }; channel.close("TLS/auth/welcome deadline (5 s)", cause: .admissionDeadline(tlsReady: channel.tlsReady, preparing: channel.isPreparing)) }
            }
        }
    }
    private func scheduleReconnect(reason: String) {
        guard !stopped else { return }
        needsReconnect = true; state("Reconnecting…", ready: false)
        guard reconnectAllowed, retryWork == nil, !resolvingReceiver else { return }
        let run = self.run, delay = backoff.next()
        event("video.reconnectScheduled", "delay=\(delay) reason=\(reason)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.run == run, !self.stopped, self.reconnectAllowed, self.needsReconnect else { return }
            self.retryWork = nil; self.retryConnection?()
        }
        retryWork = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func resolveReceiver(_ refresh: ((@escaping (NWEndpoint?) -> Void) -> Void)?, credential: DeviceCredential,
                                 install: UUID, label: String, log: RadioLog?, pairingStore: PairingKeyStore?, run: UUID) {
        guard let refresh else {
            // No fallback to the endpoint captured by start. Apps must refresh
            // Bonjour; loopback callers explicitly supply a resolver when retrying.
            stopped = true; timer?.cancel(); timer = nil
            state(ClientSessionPolicy.unreachableMessage, ready: false); onUnreachable?(); onStopped?(); return
        }
        resolution = UUID(); let request = resolution; resolvingReceiver = true
        refresh { [weak self] endpoint in self?.queue.async { [weak self] in
            guard let self, self.run == run, self.resolution == request, !self.stopped, self.reconnectAllowed else { return }
            self.resolution = UUID(); self.resolvingReceiver = false
            guard let endpoint else {
                self.receiverDiscovered = false; self.policy.receiverUnavailable()
                self.scheduleReconnect(reason: "receiver not freshly discovered"); return
            }
            self.receiverDiscovered = true; self.update { $0.reconnectAttempts += 1 }
            self.connect(endpoint: endpoint, credential: credential, install: install, label: label,
                         log: log, pairingStore: pairingStore, run: run)
        } }
    }
    private func receive(_ message: RadioMessage, channel: RadioChannel) {
        switch message {
        case .welcome(let session, _):
            lock.lock(); pending.discontinuity("reconnect"); ready = true; lock.unlock()
            sentOrientationHints.removeAll(); orientationSendPending = false; lastOrientationSend = nil
            wireGeneration &+= 1; sentConfig = nil; sequence = 0; rtt = RadioRTT()
            update { $0.session = session; $0.rttP50MS = nil; $0.rttP95MS = nil; if policy.everWelcomed { $0.reconnects += 1 } }
            event("video.welcome", "session=\(session) reconnect=\(policy.everWelcomed)")
            policy.welcomed(); backoff = ReconnectBackoff(); state("authenticated; ready to share", ready: true)
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
        case .reject(let reason): channel.queue.async { channel.close("reject \(reason)", cause: .rejected(reason)) }
        case .bye(let reason): channel.queue.async { channel.close("peer bye: \(reason)", cause: reason == "revoked" ? .revoked : .peerEnded) }
        default: channel.queue.async { channel.close("unexpected video sender message") }
        }
    }
    /// Coalesces before dispatch: no notification backlog and no media retention.
    public func orientationHint(_ hint: OrientationHint) {
        guard (try? hint.validate()) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = orientationHints[hint.source], old.monotonicNs >= hint.monotonicNs { return }
        orientationHints[hint.source] = hint
    }
    private func sendOrientationHint(_ channel: RadioChannel, now: UInt64) {
        guard !orientationSendPending, lastOrientationSend.map({ now - $0 >= 1_000_000_000 }) ?? true else { return }
        lock.lock()
        let hint = [OrientationSource.capture, .device].compactMap { orientationHints[$0] }
            .first { sentOrientationHints[$0.source] != $0 }
        lock.unlock()
        guard let hint else { return }
        orientationSendPending = true; lastOrientationSend = now; sentOrientationHints[hint.source] = hint
        channel.queue.async { [weak self, weak channel] in
            guard let channel, channel.active else { return }
            channel.send(.orientationHint(hint)) { [weak self, weak channel] in
                self?.queue.async { [weak self, weak channel] in
                    guard let self, self.channel === channel else { return }
                    self.orientationSendPending = false
                }
            }
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
        sendOrientationHint(channel, now: now)
        if outstanding.values.contains(where: { now - $0.sentAt > 10_000_000_000 }) {
            channel.queue.async { channel.close("video ACK timeout", cause: .linkLoss) }; return
        }
        guard sending == nil else { return }
        lock.lock()
        guard let first = pending.peek(), let config else { lock.unlock(); return }
        // A frame larger than the window (typically an IDR) goes alone when nothing is in flight;
        // dropping it would request another IDR of the same size and never recover.
        let cap = (config.streamSettings ?? StreamSettings()).latencyWindowBytes
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
                channel.snapshot.windowBytes = (wireConfig.streamSettings ?? StreamSettings()).latencyWindowBytes
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
    deinit { retryWork?.cancel(); timer?.cancel(); channel?.connection.cancel() }
}

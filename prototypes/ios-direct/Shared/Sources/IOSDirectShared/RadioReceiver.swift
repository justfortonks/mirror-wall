import Foundation
import Network

private final class ReceiverSessionState {
    var helloSeen = false
    var authenticated = false
    var deviceID: UUID?
    var pairing = false
    var requestSeen = false
    var nonce = Data()
    var admitted = false
    var expected: UInt64 = 0
    var mode = RadioMode.synthetic
    var video: RadioVideoConsumer?
    var assembly = VideoReassembler()
    var lastRequest: UInt64 = 0
}

/// Admission is serialized here; parsing, payload validation, metrics and sends
/// remain on the individual channel queues. No display label is a routing key.
public final class RadioReceiver {
    private let queue = DispatchQueue(label: "iosdirect.radio.listener")
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var listenerGeneration = UUID()
    private var restartWork: DispatchWorkItem?
    private var retryDelay = 0.5
    private var channels: [UUID: RadioChannel] = [:]
    private var pending = Set<UUID>()
    private var active: [UUID: UUID] = [:] // Session -> HMAC-verified device UUID.
    private var generation = UUID()
    private var state = "stopped"
    public let store: ReceiverPairingStore
    private var label: String { store.identity.name }
    private var invitation: PairingInvitation?
    private let now: () -> Date
    private var failures = 0
    private var tokenOwner: UUID?
    private var grants: [UUID: (PairedDevice, Data)] = [:]
    private var advertise = true, loopbackOnly = false
    public var onInvitation: ((PairingInvitation?) -> Void)?
    public var onApproval: ((PairingApproval?) -> Void)?
    public var onDevices: (([PairedDevice], Set<UUID>) -> Void)?
    private let log: RadioLog?
    // Configure callbacks before start; retain the receiver until stop.
    public var onState: ((String, NWEndpoint.Port?) -> Void)?
    public var onSample: ((RadioSnapshot) -> Void)?
    public var onRemoved: ((UUID) -> Void)?
    public var onEvent: ((String) -> Void)?
    public var onData: ((UUID, Int) -> Void)? // Metadata-only test/diagnostic hook; session queue.
    /// Factory runs on the session queue. The consumer owns decoding/display/timing;
    /// completion must report actual decode output, never mere VT submission.
    public var makeVideoSession: ((UUID, String, @escaping (String) -> Void) -> RadioVideoConsumer)?
    public init(store: ReceiverPairingStore, log: RadioLog? = nil, now: @escaping () -> Date = Date.init) { self.store = store; self.log = log; self.now = now }
    private func publishDevices() { onDevices?(store.devices, Set(active.values)) }
    public func pairNewDevice() {
        queue.async {
            self.burnToken(reason: "replaced")
            do {
                let invitation = try PairingInvitation(rid: self.store.identity.id, name: self.label, now: self.now())
                self.invitation = invitation; self.failures = 0; self.onInvitation?(invitation)
                self.event("pair.invitationCreated"); self.refreshListener()
                self.queue.asyncAfter(deadline: .now() + max(0, invitation.expires.timeIntervalSince(self.now()))) {
                    if self.invitation?.tokenID == invitation.tokenID { self.burnToken(reason: "expired"); self.refreshListener() }
                }
            } catch { self.event("pair.error", "secure random unavailable") }
        }
    }
    public func cancelPairing() { queue.async { self.burnToken(reason: "cancelled"); self.refreshListener() } }
    private func burnToken(reason: String, keeping: UUID? = nil) {
        guard invitation != nil else { return }
        invitation = nil; failures = 0
        if let owner = tokenOwner, owner != keeping, let channel = channels[owner] {
            channel.queue.async { channel.finish(.pairDenied, reason: "pairing ended") }
        }
        if let owner = tokenOwner, let grant = grants.removeValue(forKey: owner) { try? store.keys.delete(account: grant.0.id.uuidString) }
        if let owner = tokenOwner { granted.remove(owner); awaitingApproval.remove(owner) }
        tokenOwner = nil; onInvitation?(nil); onApproval?(nil); event("pair.invitationEnded", reason)
    }
    public func approve(_ session: UUID, allow: Bool) {
        queue.async {
            guard let invitation = self.invitation, invitation.expires > self.now(), self.tokenOwner == session,
                  let channel = self.channels[session], let grant = self.grants[session], self.awaitingApproval.remove(session) != nil else { return }
            self.onApproval?(nil)
            guard allow else { self.burnToken(reason: "denied"); self.refreshListener(); return }
            do {
                try self.store.keys.write(grant.1, account: grant.0.id.uuidString)
                let credential = DeviceCredential(deviceID: grant.0.id, deviceKey: grant.1,
                    rid: self.store.identity.id, receiverName: self.label)
                self.granted.insert(session)
                channel.queue.async { channel.send(.pairGrant(credential)) }
                self.event("pair.allowed", "session=\(session)")
            } catch { self.burnToken(reason: "storage failed"); self.refreshListener() }
        }
    }
    private var granted = Set<UUID>()
    private var awaitingApproval = Set<UUID>()
    public func forget(_ device: UUID) {
        queue.async {
            do { try self.store.forget(device) }
            catch { self.event("pair.storageError", "forget failed") }
            // A successful key deletion denies admission even if metadata persistence failed.
            if (try? self.store.key(device)) == nil {
                for (session, id) in self.active where id == device {
                    if let channel = self.channels[session] { channel.queue.async { channel.finish(.bye("revoked"), reason: "revoked") } }
                }
                self.event("device.revoked", "device=\(device)"); self.refreshListener(); self.publishDevices()
            }
        }
    }
    private func refreshListener() {
        guard timer != nil else { return }
        listenerGeneration = UUID(); listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        restartWork?.cancel(); restartWork = nil
        createListener(run: generation)
    }
    private func event(_ name: String, _ details: String = "") { log?.event(name, details); onEvent?("\(name) \(details)") }
    public func start(advertise: Bool = true, loopbackOnly: Bool = false) {
        queue.async { [self] in
            stopOnQueue(); self.advertise = advertise; self.loopbackOnly = loopbackOnly; let run = generation; publishDevices()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let token = self.invitation, token.expires <= self.now() { self.burnToken(reason: "expired"); self.refreshListener() }
                self.event("listener.sample", "state=\(self.state) active=\(self.active.count) pending=\(self.pending.count) thermal=\(radioThermalState()) memoryMB=\(radioMemoryMB().map { String($0) } ?? "unavailable")")
            }
            self.timer = timer; timer.resume()
            createListener(run: run)
        }
    }
    private func createListener(run: UUID) {
        guard generation == run else { return }
        listenerGeneration = UUID(); let attempt = listenerGeneration
        do {
            var identities = try store.identities()
            if let invitation, invitation.expires > self.now() { identities.append((invitation.identity, invitation.key)) }
            let parameters = RadioTLS.parameters(identities: identities)
            if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            if advertise {
                listener.service = NWListener.Service(name: label, type: RadioTLS.service,
                    txtRecord: NWTXTRecord(["rid": store.identity.id.uuidString, "v": "3"]))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.generation == run, self.listenerGeneration == attempt else { return }
                self.state = String(describing: state); self.event("listener.state", self.state)
                self.onState?(self.state, listener?.port)
                if case .ready = state { self.retryDelay = 0.5 }
                if case .failed = state {
                    self.restartListener(run: run)
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, self.generation == run, self.listenerGeneration == attempt else { return }
                self.event("listener.service", String(describing: change))
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.listenerGeneration == attempt else { connection.cancel(); return }
                self.accept(connection, run: run)
            }
            listener.start(queue: queue)
        } catch {
            state = "failed: \(error)"; event("listener.error", state); onState?(state, nil)
            restartListener(run: run)
        }
    }
    private func restartListener(run: UUID) {
        listenerGeneration = UUID()
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        restartWork?.cancel()
        let delay = retryDelay; retryDelay = min(4, delay * 2)
        event("listener.restart", "delay=\(delay)s reason=\(state); preserving admitted sessions")
        state = "restarting in \(delay) s"; onState?(state, nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == run else { return }
            self.restartWork = nil
            self.createListener(run: run)
        }
        restartWork = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        burnToken(reason: "receiver stopped")
        generation = UUID(); listenerGeneration = UUID(); retryDelay = 0.5
        restartWork?.cancel(); restartWork = nil
        timer?.cancel(); timer = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        event("listener.stopped")
        for (id, channel) in channels { channel.queue.async { channel.close("receiver stopped") }; onRemoved?(id) }
        channels.removeAll(); pending.removeAll(); active.removeAll(); publishDevices(); state = "stopped"; onState?(state, nil)
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
        let acceptedToken = invitation?.tokenID
        do { session.nonce = try PairCrypto.random(32) } catch { connection.cancel(); channels.removeValue(forKey: id); pending.remove(id); return }
        channel.onReady = { [weak channel] in
            guard let channel else { return }
            channel.send(.authChallenge(session.nonce))
            channel.queue.asyncAfter(deadline: .now() + 5) {
                if !session.authenticated { channel.close("5 s authentication timeout") }
            }
        }
        let handleAssembly: (VideoAssemblyEvent) -> Void = { [weak channel] event in
            guard let channel else { return }
            switch event {
            case let .dropped(seq, pts, reason):
                channel.send(.videoAck(seq: seq, ptsNs: pts, status: .dropped))
                session.video?.discontinuity(reason)
                if session.video == nil, radioNow() - session.lastRequest > 250_000_000 {
                    session.lastRequest = radioNow(); channel.send(.keyframeRequest(reason))
                }
            case .frame(let frame):
                guard let video = session.video else {
                    channel.send(.videoAck(seq: frame.seq, ptsNs: frame.ptsNs, status: .dropped))
                    channel.send(.keyframeRequest("video consumer unavailable")); return
                }
                let seq = frame.seq, pts = frame.ptsNs, size = frame.data.count
                video.receive(frame) { [weak channel] status in
                    channel?.queue.async { [weak channel] in
                        guard let channel, channel.active else { return }
                        channel.snapshot.deliveredBytes += UInt64(size)
                        channel.send(.videoAck(seq: seq, ptsNs: pts, status: status))
                    }
                }
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            if !session.authenticated {
                guard case let .authResponse(identity, proof) = message else { throw RadioError.protocolViolation("authentication required") }
                let verified: (UUID?, Bool) = try self.queue.sync {
                    guard self.generation == run, self.pending.contains(id) else { throw RadioError.protocolViolation("stale authentication") }
                    if let device = UUID(uuidString: identity), identity == device.uuidString, let key = try self.store.key(device),
                       PairCrypto.verify(proof, key: key, nonce: session.nonce, rid: self.store.identity.id, identity: identity) {
                        return (device, false)
                    }
                    if let token = self.invitation, token.expires > self.now(), token.tokenID == acceptedToken,
                       token.identity == identity, self.tokenOwner == nil,
                       PairCrypto.verify(proof, key: token.key, nonce: session.nonce, rid: self.store.identity.id, identity: identity) {
                        self.tokenOwner = id; return (nil, true)
                    }
                    throw RadioError.protocolViolation("authentication failed")
                }
                session.authenticated = true; session.deviceID = verified.0; session.pairing = verified.1
                channel.snapshot.deviceID = verified.0
                return
            }
            if session.pairing {
                try self.queue.sync {
                    guard let token = self.invitation, token.expires > self.now(), self.tokenOwner == id else {
                        throw RadioError.protocolViolation("pairing expired or used")
                    }
                    switch message {
                    case let .pairRequest(install, label, model):
                        guard !session.requestSeen else { throw RadioError.protocolViolation("duplicate pair request") }
                        session.requestSeen = true
                        let device = PairedDevice(id: UUID(), installID: install, label: label, model: model)
                        self.grants[id] = (device, try PairCrypto.random(32)); self.awaitingApproval.insert(id)
                        self.event("pair.request", "session=\(id)")
                        if let approval = self.onApproval {
                            approval(PairingApproval(id: id, label: label, model: model, expires: token.expires))
                        } else { self.burnToken(reason: "no approver"); self.refreshListener() }
                    case .pairDone:
                        guard self.granted.contains(id), let grant = self.grants[id] else {
                            throw RadioError.protocolViolation("grant required")
                        }
                        try self.store.add(grant.0, key: grant.1)
                        self.grants.removeValue(forKey: id); self.granted.remove(id)
                        self.burnToken(reason: "paired", keeping: id); self.refreshListener(); self.publishDevices()
                        self.event("pair.completed", "device=\(grant.0.id)")
                        channel.finish(.bye("paired"), reason: "paired")
                    default: throw RadioError.protocolViolation("unexpected pairing message")
                    }
                }
                return
            }
            if !session.helloSeen {
                guard case let .hello(install, label, version, rate, window, mode) = message else { throw RadioError.protocolViolation("hello required") }
                session.helloSeen = true; session.mode = mode; channel.snapshot.label = label; channel.snapshot.installID = install
                channel.snapshot.mode = mode
                channel.snapshot.windowMode = window; channel.snapshot.windowBytes = window.bytes(mbit: Int(rate))
                self.queue.async {
                    guard self.generation == run, self.pending.contains(id), self.channels[id] === channel else { return }
                    let rejection: String?
                    if version != 3 || (mode == .video && window != .latency) { rejection = "version" }
                    else if self.active.count >= 2 { rejection = "capacity" }
                    else if self.active.values.contains(session.deviceID!) { rejection = "busy" }
                    else if !RadioPacer.rates.contains(Int(rate)) { rejection = "version" }
                    else { rejection = nil }
                    // Recheck the current key set: listener snapshots can predate revocation.
                    if (try? self.store.key(session.deviceID!)) == nil {
                        channel.queue.async { channel.finish(.bye("revoked"), reason: "revoked") }; return
                    }
                    if let rejection {
                        self.event("session.reject", "session=\(id) reason=\(rejection)")
                        channel.queue.async { channel.finish(.reject(rejection), reason: "reject \(rejection)") }
                    } else {
                        self.pending.remove(id); self.active[id] = session.deviceID!
                        try? self.store.seen(session.deviceID!); self.publishDevices()
                        self.event("session.admit", "session=\(id) device=\(session.deviceID!)")
                        channel.queue.async {
                            guard !channel.closed else { return }; session.admitted = true; channel.active = true
                            if mode == .video {
                                session.video = self.makeVideoSession?(id, label, { [weak channel] reason in
                                    channel?.queue.async { [weak channel] in
                                        guard let channel, channel.active else { return }
                                        channel.send(.keyframeRequest(String(reason.prefix(100))))
                                    }
                                })
                            }
                            channel.send(.welcome(session: id, label: self.label)); channel.sample()
                        }
                    }
                }
                return
            }
            guard session.admitted else { throw RadioError.protocolViolation("payload before welcome") }
            switch message {
            case let .data(seq, time, payload, crc):
                guard session.mode == .synthetic else { throw RadioError.protocolViolation("synthetic data in video session") }
                guard !payload.isEmpty else { throw RadioError.protocolViolation("empty data") }
                if RadioCRC32.checksum(payload) != crc {
                    channel.snapshot.crcFailures += 1; throw RadioError.protocolViolation("CRC failure")
                }
                guard seq >= session.expected, seq != UInt64.max else { throw RadioError.protocolViolation("sequence regression/overflow") }
                channel.snapshot.seqGaps += seq - session.expected; session.expected = seq + 1
                channel.snapshot.deliveredBytes += UInt64(payload.count)
                channel.send(.ack(seq: seq, time: time, total: channel.snapshot.deliveredBytes))
                self.onData?(id, payload.count)
            case .videoConfig(let config):
                guard session.mode == .video else { throw RadioError.protocolViolation("video in synthetic session") }
                for event in session.assembly.abandon("config changed mid-frame") { handleAssembly(event) }
                try session.video?.configure(config)
            case .videoFragment(let fragment):
                guard session.mode == .video else { throw RadioError.protocolViolation("video in synthetic session") }
                for event in try session.assembly.accept(fragment, now: Double(radioNow()) / 1e9) { handleAssembly(event) }
            case .stats(let json):
                let stats = try JSONDecoder().decode(RadioSnapshot.self, from: json)
                guard stats.id == id, stats.installID == channel.snapshot.installID, stats.deviceID == channel.snapshot.deviceID,
                      stats.windowMode == channel.snapshot.windowMode, stats.windowBytes == channel.snapshot.windowBytes,
                      stats.sendBlockedMS.isFinite, stats.sendBlockedMS >= 0,
                      let blocked = stats.sendBlockedMSPerSecond, blocked.isFinite, blocked >= 0 else {
                    throw RadioError.protocolViolation("invalid sender stats")
                }
                // Sender-reported pacing counters; throughput/path/RTT stay local.
                channel.snapshot.sendBlockedMS = stats.sendBlockedMS
                channel.snapshot.sendBlockedMSPerSecond = blocked
            case .bye(let reason): channel.close("peer bye: \(reason)")
            default: throw RadioError.protocolViolation("unexpected receiver message")
            }
        }
        channel.onTick = { [weak channel] in
            guard let channel, channel.active else { return }
            for event in session.assembly.expire(now: Double(radioNow()) / 1e9) { handleAssembly(event) }
            session.video?.tick()
            guard let json = try? JSONEncoder().encode(channel.snapshot) else { return }
            channel.send(.stats(json))
        }
        channel.onSample = { [weak self] sample in
            self?.queue.async { [weak self] in
                guard let self, self.generation == run, self.channels[id] != nil else { return }
                self.onSample?(sample)
            }
        }
        channel.onClosed = { [weak self] reason in
            session.video?.close(reason); session.video = nil
            self?.queue.async { [weak self] in
                guard let self, self.generation == run else { return }
                self.channels.removeValue(forKey: id); self.pending.remove(id); self.active.removeValue(forKey: id)
                if self.tokenOwner == id { self.burnToken(reason: "pairing disconnected"); self.refreshListener() }
                else if !session.authenticated, self.invitation?.tokenID == acceptedToken, acceptedToken != nil {
                    self.failures += 1; self.event("pair.failedAttempt", "count=\(self.failures)")
                    if self.failures >= 3 { self.burnToken(reason: "attempt limit"); self.refreshListener() }
                }
                self.granted.remove(id); self.publishDevices()
                self.event("session.removed", "session=\(id) reason=\(reason)"); self.onRemoved?(id)
            }
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak channel] in
            guard let self, self.generation == run, self.pending.contains(id), let channel else { return }
            channel.queue.async {
                if !session.authenticated || !session.pairing && !session.admitted { channel.close("5 s TLS/auth/hello timeout") }
            }
        }
    }
    deinit { restartWork?.cancel(); timer?.cancel(); listener?.stateUpdateHandler = nil; listener?.cancel(); for channel in channels.values { channel.connection.cancel() } }
}

public struct PairingApproval: Identifiable {
    public let id: UUID
    public let label: String, model: String
    public let expires: Date
}

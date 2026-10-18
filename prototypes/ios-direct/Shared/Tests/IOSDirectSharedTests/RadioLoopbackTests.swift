#if os(macOS)
import XCTest
import Network
@testable import IOSDirectShared

final class RadioLoopbackTests: XCTestCase {
    private var receivers: [RadioReceiver] = []
    private var clients: [RadioChannel] = []
    private var pairers: [PairingClient] = []
    private var senders: [RadioSender] = []
    private var sinks: [VideoNetworkSink] = []
    private let lock = NSLock()
    private var endpoints: [ObjectIdentifier: NWEndpoint] = [:]
    override func tearDown() {
        for sink in sinks { sink.stop() }
        sinks.removeAll()
        for sender in senders { sender.stop() }
        for pairer in pairers { pairer.cancel() }
        for client in clients { client.queue.sync { client.close("test teardown") } }
        for receiver in receivers { receiver.stop() }
        clients.removeAll(); receivers.removeAll(); pairers.removeAll(); senders.removeAll()
        super.tearDown()
    }
    private func receiver(devices: Int = 0, deviceIDs: [UUID] = [], identity: ReceiverIdentity = ReceiverIdentity(name: "Loopback"), log: RadioLog? = nil, now: @escaping () -> Date = Date.init) throws -> (RadioReceiver, [DeviceCredential]) {
        let store = try ReceiverPairingStore(identity: identity, keys: MemoryPairingKeyStore())
        var credentials: [DeviceCredential] = []
        for index in 0..<devices {
            let credential = DeviceCredential(deviceID: deviceIDs.indices.contains(index) ? deviceIDs[index] : UUID(), deviceKey: try PairCrypto.random(32), rid: identity.id, receiverName: identity.name)
            try store.add(PairedDevice(id: credential.deviceID, installID: UUID(), label: "same name", model: "test phone"), key: credential.deviceKey)
            credentials.append(credential)
        }
        let receiver = RadioReceiver(store: store, log: log, now: now); receivers.append(receiver)
        let ready = expectation(description: "listener ready")
        var first = true
        receiver.onState = { state, port in
            if state == "ready", let port {
                self.lock.lock(); self.endpoints[ObjectIdentifier(receiver)] = .hostPort(host: "127.0.0.1", port: port)
                let fulfill = first; first = false; self.lock.unlock()
                if fulfill { ready.fulfill() }
            }
        }
        receiver.start(advertise: false, loopbackOnly: true); wait(for: [ready], timeout: 5)
        return (receiver, credentials)
    }
    private func endpoint(_ receiver: RadioReceiver) throws -> NWEndpoint {
        lock.lock(); defer { lock.unlock() }; return try XCTUnwrap(endpoints[ObjectIdentifier(receiver)])
    }
    private func changedListener(_ receiver: RadioReceiver, action: () -> Void) {
        let ready = expectation(description: "replacement listener ready")
        receiver.onState = { state, port in
            if state == "ready", let port {
                self.lock.lock(); self.endpoints[ObjectIdentifier(receiver)] = .hostPort(host: "127.0.0.1", port: port); self.lock.unlock(); ready.fulfill()
            }
        }
        action(); wait(for: [ready], timeout: 5)
        receiver.onState = { state, port in
            if state == "ready", let port {
                self.lock.lock(); self.endpoints[ObjectIdentifier(receiver)] = .hostPort(host: "127.0.0.1", port: port); self.lock.unlock()
            }
        }
    }
    private func invitation(_ receiver: RadioReceiver) throws -> PairingInvitation {
        let created = expectation(description: "QR created"); var token: PairingInvitation?
        receiver.onInvitation = { value in if let value { token = value; created.fulfill() } }
        changedListener(receiver) { receiver.pairNewDevice() }
        wait(for: [created], timeout: 2); return try XCTUnwrap(token)
    }
    private func client(_ receiver: RadioReceiver, credential: DeviceCredential, claim: UUID? = nil, mode: RadioMode = .synthetic,
                        handler: @escaping (RadioChannel, RadioMessage) throws -> Void) throws -> RadioChannel {
        let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(credential: credential)))
        clients.append(channel)
        channel.onMessage = { [weak channel] message in
            guard let channel else { return }
            if case .authChallenge(let nonce) = message {
                let id = (claim ?? credential.deviceID).uuidString
                channel.send(.authResponse(id, PairCrypto.proof(key: credential.deviceKey, nonce: nonce, rid: credential.rid, identity: id)))
                channel.send(.hello(install: UUID(), label: "same name", version: 3, rate: 12, mode: mode)); return
            }
            try handler(channel, message)
        }
        return channel
    }
    private func handshakeFails(_ receiver: RadioReceiver, identity: String, key: Data, log: RadioLog? = nil) throws {
        let closed = expectation(description: "TLS rejected without application bytes")
        let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(identities: [(identity, key)])), log: log)
        clients.append(channel)
        channel.onReady = { XCTFail("unauthorized TLS ready") }
        channel.onMessage = { _ in XCTFail("unauthorized application message") }
        channel.onClosed = { _ in XCTAssertEqual(channel.snapshot.receivedWireBytes, 0); XCTAssertEqual(channel.snapshot.sentWireBytes, 0); closed.fulfill() }
        channel.start()
        channel.queue.asyncAfter(deadline: .now() + 1.5) { if !channel.closed { channel.close("handshake deadline") } }
        wait(for: [closed], timeout: 3)
    }
    func testPendingLimitAuthenticationDeadlineAndSlotReuse() throws {
        let (receiver, keys) = try receiver(devices: 1)
        let ready = expectation(description: "two TLS pending clients"); ready.expectedFulfillmentCount = 2
        let timedOut = expectation(description: "authentication slots expire"); timedOut.expectedFulfillmentCount = 2
        let refused = expectation(description: "third pending socket refused")
        receiver.onEvent = { event in
            if event.contains("pending handshake limit") { refused.fulfill() }
            if event.contains("session.removed"), event.contains("timeout") { timedOut.fulfill() }
        }
        for _ in 0..<2 {
            let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(credential: keys[0])))
            clients.append(channel); channel.onReady = { ready.fulfill() }; channel.start()
        }
        wait(for: [ready], timeout: 3)
        let third = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(credential: keys[0])))
        clients.append(third); third.onReady = { XCTFail("third handshake exceeded pending bound") }; third.start()
        wait(for: [refused, timedOut], timeout: 7)
        let welcome = expectation(description: "slots reusable after auth timeout")
        let normal = try client(receiver, credential: keys[0]) { channel, message in
            if case .welcome = message { channel.active = true; welcome.fulfill() }
        }; normal.start(); wait(for: [welcome], timeout: 3)
    }
    func testCapacityProbeAndPacingTelemetryAfterV3Authentication() throws {
        let (receiver, keys) = try receiver(devices: 1)
        let sampled = expectation(description: "pacing telemetry at receiver"); var received = false
        receiver.onSample = { sample in
            guard sample.sendBlockedMSPerSecond != nil, !received else { return }; received = true
            XCTAssertEqual(sample.deviceID, keys[0].deviceID); XCTAssertEqual(sample.windowMode, .capacityProbe)
            XCTAssertEqual(sample.windowBytes, 2_097_152); XCTAssertGreaterThan(sample.deliveredBytes, 0); sampled.fulfill()
        }
        let sender = RadioSender(endpoint: try endpoint(receiver), credential: keys[0], rate: 48, window: .capacityProbe, install: UUID(), label: "probe")
        senders.append(sender); sender.start(); wait(for: [sampled], timeout: 4)
    }
    func testVideoSinkAuthenticationFailureStopsWithoutRetryAndRetainsAmbiguousCredential() throws {
        let (receiver, keys) = try receiver(devices: 1), original = keys[0]
        let wrong = DeviceCredential(deviceID: original.deviceID, deviceKey: try PairCrypto.random(32), rid: original.rid, receiverName: "Mac")
        let store = MemoryPairingKeyStore(); try store.save(wrong)
        let sink = VideoNetworkSink(); sinks.append(sink)
        let rejected = expectation(description: "authentication failure is terminal")
        let noRetry = expectation(description: "no auth retry"); noRetry.isInverted = true
        sink.onPairingRejected = { rid, reason in
            XCTAssertEqual(rid, wrong.rid); XCTAssertEqual(reason, .notAccepted); rejected.fulfill()
        }
        sink.onEvent = { name, _ in if name == "video.reconnectScheduled" { noRetry.fulfill() } }
        sink.start(endpoint: try endpoint(receiver), credential: wrong, install: UUID(), label: "Phone", receiverDiscovered: true, pairingStore: store)
        wait(for: [rejected], timeout: 7); wait(for: [noRetry], timeout: 0.7)
        XCTAssertEqual(sink.snapshot().reconnectAttempts, 0)
        XCTAssertEqual(sink.snapshot().state, PairingRejection.notAccepted.message)
        XCTAssertNotNil(try store.credential(rid: wrong.rid))
    }
    func testPeerCloseAfterTLSReadyBeforeWelcomeIsNotAccepted() throws {
        let key = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: UUID(), receiverName: "Mac")
        let listener = try NWListener(using: RadioTLS.parameters(credential: key), on: .any)
        let queue = DispatchQueue(label: "peer.close.test"), ready = expectation(description: "TLS listener")
        var servers: [RadioChannel] = []
        listener.newConnectionHandler = { connection in
            let channel = RadioChannel(connection); servers.append(channel)
            channel.onReady = { [weak channel] in channel?.queue.asyncAfter(deadline: .now() + 0.05) { [weak channel] in channel?.close("peer ended admission") } }
            channel.start()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue); wait(for: [ready], timeout: 3)
        defer { listener.cancel(); queue.sync { for server in servers { server.queue.sync { server.close("test end") } } } }
        let rejected = expectation(description: "real peer close after TLS is rejection")
        let sender = RadioSender(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), credential: key,
                                 rate: 6, install: UUID(), label: "Phone", receiverDiscovered: true)
        senders.append(sender); sender.onPairingRejected = { XCTAssertEqual($0, .notAccepted); rejected.fulfill() }
        sender.start(); wait(for: [rejected], timeout: 3)
    }
    func testPreparingDeadlinesRetryFreshDiscoveryThenStopUnreachableWithCredentialKept() throws {
        // A TCP peer that never starts TLS reproduces preparing without any TLS
        // rejection or application data. Exercise actual five-second deadlines.
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "stall.test.tcp"), listening = expectation(description: "TCP listener")
        var connections: [NWConnection] = []
        listener.newConnectionHandler = { connection in connections.append(connection); connection.start(queue: queue) }
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: queue); wait(for: [listening], timeout: 3)
        defer { listener.cancel(); queue.sync { for connection in connections { connection.cancel() } } }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port))
        let credential = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: UUID(), receiverName: "Mac")
        let store = MemoryPairingKeyStore(); try store.save(credential)
        let sink = VideoNetworkSink(); sinks.append(sink)
        let ended = expectation(description: "three stalls end as unreachable")
        var resolutions = 0
        sink.onUnreachable = { ended.fulfill() }
        sink.onPairingRejected = { _, _ in XCTFail("silent preparing is not rejection") }
        sink.start(endpoint: endpoint, credential: credential, install: UUID(), label: "Phone", receiverDiscovered: true, pairingStore: store,
            refreshReceiver: { completion in resolutions += 1; completion(endpoint) })
        wait(for: [ended], timeout: 22)
        XCTAssertEqual(resolutions, 2); XCTAssertEqual(sink.snapshot().reconnectAttempts, 2)
        XCTAssertEqual(sink.snapshot().state, ClientSessionPolicy.unreachableMessage)
        XCTAssertEqual(try store.credential(rid: credential.rid), credential)
        XCTAssertEqual(ReceiverPairingStatus().label(rid: credential.rid, hasCredential: true), "Paired")
    }
    func testVideoSinkAuthenticatedRevokedByeDeletesCredentialAndNeverRetries() throws {
        let (receiver, keys) = try receiver(devices: 1), key = keys[0]
        let store = MemoryPairingKeyStore(); try store.save(key)
        let sink = VideoNetworkSink(); sinks.append(sink)
        let welcome = expectation(description: "welcomed before revocation"), revoked = expectation(description: "authenticated revocation")
        let noRetry = expectation(description: "no revoked retry"); noRetry.isInverted = true
        sink.onState = { _, ready in if ready { welcome.fulfill() } }
        sink.onPairingRejected = { rid, reason in
            XCTAssertEqual(rid, key.rid); XCTAssertEqual(reason, .revoked); revoked.fulfill()
        }
        sink.onEvent = { name, _ in if name == "video.reconnectScheduled" { noRetry.fulfill() } }
        sink.start(endpoint: try endpoint(receiver), credential: key, install: UUID(), label: "Phone", receiverDiscovered: true, pairingStore: store)
        wait(for: [welcome], timeout: 3)
        changedListener(receiver) { receiver.forget(key.deviceID) }
        wait(for: [revoked], timeout: 3); wait(for: [noRetry], timeout: 0.7)
        XCTAssertNil(try store.credential(rid: key.rid)); XCTAssertEqual(sink.snapshot().reconnectAttempts, 0)
        XCTAssertEqual(sink.snapshot().state, PairingRejection.revoked.message)
    }
    func testVideoSinkRecoversForegroundLinkLossWithFreshDiscoveryAndAuthentication() throws {
        let (receiver, keys) = try receiver(devices: 1), sink = VideoNetworkSink(); sinks.append(sink)
        var made = 0
        receiver.makeVideoSession = { _, device, _, _ in
            XCTAssertEqual(device, keys[0].deviceID); made += 1
            let consumer = LoopbackVideoConsumer()
            if made == 1 { consumer.onConfig = { _ in throw RadioError.protocolViolation("test link interruption") } }
            return consumer
        }
        let recovered = expectation(description: "second authenticated welcome")
        var welcomes = 0, resolutions = 0, foreground = false, resuming = false
        sink.onEvent = { name, details in
            if name == "video.connection", details == "Reconnecting…", !resuming {
                resuming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { foreground = true; sink.setRecoveryAllowed(true) }
            }
            if name == "video.reconnectScheduled" { XCTAssertTrue(foreground, "recovery must wait for foreground") }
        }
        sink.onState = { _, ready in
            guard ready else { return }; welcomes += 1
            if welcomes == 1 {
                sink.setRecoveryAllowed(false)
                sink.begin(encoderGeneration: 1)
                sink.offer(Data(repeating: 1, count: 128), ptsNs: 100, keyframe: true, encoderGeneration: 1, config: VideoTests.config)
            } else { recovered.fulfill() }
        }
        sink.onPairingRejected = { _, _ in XCTFail("link loss classified as authentication rejection") }
        sink.start(endpoint: try endpoint(receiver), credential: keys[0], install: UUID(), label: "Phone", receiverDiscovered: true,
            refreshReceiver: { completion in
                resolutions += 1
                sink.setRecoveryAllowed(true) // Duplicate foreground while resolving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    completion(try? self.endpoint(receiver))
                    completion(try? self.endpoint(receiver)) // A result is consumed once.
                }
            })
        wait(for: [recovered], timeout: 4)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(sink.snapshot().reconnects, 1); XCTAssertEqual(sink.snapshot().reconnectAttempts, 1)
    }
    func testShareAgainUsesNewConfigAndIDROnTheSameAuthenticatedSession() throws {
        let (receiver, keys) = try receiver(devices: 1), sink = VideoNetworkSink(); sinks.append(sink)
        let first = expectation(description: "first capture"), second = expectation(description: "second capture")
        var generations: [UInt32] = [], factoryCalls = 0
        receiver.makeVideoSession = { _, device, label, _ in
            XCTAssertEqual(device, keys[0].deviceID); XCTAssertEqual(label, "same name")
            factoryCalls += 1; let consumer = LoopbackVideoConsumer()
            consumer.onConfig = { generations.append($0.generation) }
            consumer.onFrame = { frame in
                XCTAssertTrue(frame.keyframe)
                if frame.ptsNs == 100 { first.fulfill() } else if frame.ptsNs == 200 { second.fulfill() }
            }
            return consumer
        }
        let ready = expectation(description: "one authenticated welcome")
        sink.onState = { _, active in if active { ready.fulfill() } }
        sink.start(endpoint: try endpoint(receiver), credential: keys[0], install: UUID(), label: "untrusted hello label", receiverDiscovered: true)
        wait(for: [ready], timeout: 3); let session = sink.snapshot().session
        sink.begin(encoderGeneration: 1)
        sink.offer(Data(repeating: 1, count: 128), ptsNs: 100, keyframe: true, encoderGeneration: 1, config: VideoTests.config)
        wait(for: [first], timeout: 3)
        // Encoder stop/start invalidates generations without sink.stop/disconnect.
        sink.begin(encoderGeneration: 2)
        sink.offer(Data(repeating: 2, count: 128), ptsNs: 200, keyframe: true, encoderGeneration: 2, config: VideoTests.config)
        wait(for: [second], timeout: 3)
        XCTAssertEqual(factoryCalls, 1); XCTAssertEqual(sink.snapshot().session, session)
        XCTAssertEqual(generations.count, 2); XCTAssertLessThan(generations[0], generations[1])
        XCTAssertEqual(sink.snapshot().reconnects, 0)
    }
    func testQualityChangesAndLargeNativeIDROnSameAuthenticatedSession() throws {
        let (receiver, keys) = try receiver(devices: 1), sink = VideoNetworkSink(); sinks.append(sink)
        let ready = expectation(description: "authenticated")
        let pictures = (0..<3).map { expectation(description: "preset \($0)") }
        var factoryCalls = 0, configs = [VideoConfig]()
        receiver.makeVideoSession = { _, _, _, _ in
            factoryCalls += 1; let consumer = LoopbackVideoConsumer()
            consumer.onConfig = { configs.append($0) }
            consumer.onFrame = { frame in
                XCTAssertTrue(frame.keyframe)
                let index = Int(frame.ptsNs)
                XCTAssertEqual(configs.last?.streamSettings?.preset, StreamPreset.allCases[index])
                XCTAssertEqual(frame.data.count, index == 2 ? Int(3.9 * 1_048_576) : 100_000)
                pictures[index].fulfill()
            }
            return consumer
        }
        sink.onState = { _, active in if active { ready.fulfill() } }
        sink.start(endpoint: try endpoint(receiver), credential: keys[0], install: UUID(), label: "Phone", receiverDiscovered: true)
        wait(for: [ready], timeout: 3); let session = sink.snapshot().session
        for (index, preset) in StreamPreset.allCases.enumerated() {
            let settings = StreamSettings(preset: preset, sixtyFPS: index != 0)
            let size = try XCTUnwrap(preset.output(width: 1320, height: 2868))
            let config = VideoConfig(generation: UInt32(index + 1), width: UInt16(size.width), height: UInt16(size.height),
                orientation: 1, streamSettings: settings, avcC: VideoTests.config.avcC)
            sink.begin(encoderGeneration: index + 1)
            sink.offer(Data(repeating: 1, count: index == 2 ? Int(3.9 * 1_048_576) : 100_000), ptsNs: UInt64(index),
                keyframe: true, encoderGeneration: index + 1, config: config)
            wait(for: [pictures[index]], timeout: 4)
            // 100 KB exceeds Standard's 75 KB window but fits High's 150 KB.
            XCTAssertEqual(sink.snapshot().drops["oversizeAdmittedAlone"], index == 2 ? 2 : 1)
        }
        XCTAssertEqual(factoryCalls, 1); XCTAssertEqual(sink.snapshot().session, session)
        XCTAssertEqual(sink.snapshot().reconnects, 0)
        XCTAssertEqual(configs.map { $0.streamSettings?.fps }, [30, 60, 60])
        XCTAssertEqual(configs.map { $0.streamSettings?.targetBitrate }, [6_000_000, 12_000_000, 20_000_000])
        XCTAssertLessThan(configs[0].generation, configs[1].generation)
        XCTAssertLessThan(configs[1].generation, configs[2].generation)
        XCTAssertEqual(sink.snapshot().drops["oversizeAdmittedAlone"], 2)
    }
    func testPreferredCipherProbe() throws {
        // Force CCAC alone at both ends. No negotiation fallback in the test.
        let done = expectation(description: "CCAC negotiated or TLS engine rejected")
        let key = try PairCrypto.random(32)
        let listener = try NWListener(using: RadioTLS.parameters(identities: [("probe", key)], cipher: 0xCCAC), on: .any)
        var client: RadioChannel?, server: RadioChannel?
        var finished = false
        let finish: (String) -> Void = { text in
            self.lock.lock(); defer { self.lock.unlock() }
            if !finished { finished = true; XCTAssertEqual(text, "CCAC negotiated"); print("G3b cipher probe: \(text)"); done.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let channel = RadioChannel(connection); server = channel
            channel.onReady = { XCTAssertEqual(channel.snapshot.cipherSuite, 0xCCAC); finish("CCAC negotiated") }
            channel.onClosed = { finish("CCAC rejected: \($0)") }; channel.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                let channel = RadioChannel(NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: RadioTLS.parameters(identities: [("probe", key)], cipher: 0xCCAC)))
                client = channel
                channel.onReady = { XCTAssertEqual(channel.snapshot.cipherSuite, 0xCCAC); finish("CCAC negotiated") }
                channel.onClosed = { finish("CCAC rejected: \($0)") }; channel.start()
            }
            if case .failed(let error) = state { XCTFail("probe listener: \(error)"); finish("listener failure") }
        }
        listener.start(queue: DispatchQueue(label: "cipher.probe"))
        wait(for: [done], timeout: 5)
        client?.queue.sync { client?.close("probe complete") }; server?.queue.sync { server?.close("probe complete") }; listener.cancel()
    }
    func testExpiredInvitationRejectedAndApprovalAutoDenied() throws {
        let clock = TestClock()
        let (receiver, _) = try receiver(now: { clock.now() }), token = try invitation(receiver)
        let request = expectation(description: "approval shown"), denied = expectation(description: "expiry denies approval")
        receiver.onApproval = { if $0 != nil { request.fulfill() } }
        let pairer = PairingClient(endpoint: try endpoint(receiver), invitation: token, install: UUID(), label: "Phone", model: "test", store: MemoryPairingKeyStore())
        pairers.append(pairer)
        pairer.onState = { if $0.hasPrefix("Denied on Mac") { denied.fulfill() } }
        pairer.onPaired = { _ in XCTFail("expired approval granted") }; pairer.start(); wait(for: [request], timeout: 3)
        changedListener(receiver) { clock.advance(121) }
        wait(for: [denied], timeout: 3)
        try handshakeFails(receiver, identity: token.identity, key: token.key)
    }
    func testDenialBurnsTokenAndCannotAdmitMedia() throws {
        let (receiver, _) = try receiver(), token = try invitation(receiver)
        receiver.onApproval = { if let request = $0 { receiver.approve(request.id, allow: false) } }
        let denied = expectation(description: "denied on Mac")
        let pairer = PairingClient(endpoint: try endpoint(receiver), invitation: token, install: UUID(), label: "Phone", model: "test", store: MemoryPairingKeyStore())
        pairers.append(pairer); pairer.onState = { if $0.hasPrefix("Denied on Mac") { denied.fulfill() } }
        pairer.onPaired = { _ in XCTFail("denied phone paired") }; pairer.start(); wait(for: [denied], timeout: 3)
        try handshakeFails(receiver, identity: token.identity, key: token.key)
    }
    func testAllowedPairingWithoutPairDoneEndsWithinFiveSecondsOfDecision() throws {
        let (receiver, _) = try receiver(), token = try invitation(receiver)
        let ended = expectation(description: "allowed but unconfirmed pairing ended")
        var decision: UInt64 = 0
        receiver.onApproval = { if let request = $0 { decision = radioNow(); receiver.approve(request.id, allow: true) } }
        let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(identities: [(token.identity, token.key)])))
        clients.append(channel)
        channel.onMessage = { [weak channel] message in
            guard let channel else { return }
            switch message {
            case .authChallenge(let nonce):
                channel.send(.authResponse(token.identity, PairCrypto.proof(key: token.key, nonce: nonce, rid: token.rid, identity: token.identity)))
                channel.send(.pairRequest(install: UUID(), label: "phone", model: "test"))
            case .pairGrant: break // Simulate a phone that never confirms the grant.
            case .pairDenied:
                XCTAssertLessThan(Double(radioNow() - decision) / 1e9, 5)
                ended.fulfill()
            default: XCTFail("unexpected pairing message")
            }
        }
        channel.start(); wait(for: [ended], timeout: 5.5)
    }
    func testCapturedLogsContainNoInvitationSecretDerivedKeyOrDeviceKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("g3b-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try RadioLog(url: url)
        let (receiver, keys) = try receiver(devices: 1, log: log), token = try invitation(receiver)
        receiver.onApproval = { if let request = $0 { receiver.approve(request.id, allow: true) } }
        let paired = expectation(description: "pairing logged"); var newKey = Data()
        let pairer = PairingClient(endpoint: try endpoint(receiver), invitation: token, install: UUID(), label: "Phone", model: "test", store: MemoryPairingKeyStore(), log: log)
        pairers.append(pairer); pairer.onPaired = { newKey = $0.deviceKey; paired.fulfill() }; changedListener(receiver) { pairer.start() }; wait(for: [paired], timeout: 3)
        let welcome = expectation(description: "normal authentication logged")
        let channel = try client(receiver, credential: keys[0]) { channel, message in
            if case .welcome = message { channel.active = true; welcome.fulfill() }
        }
        channel.start(); wait(for: [welcome], timeout: 3); channel.queue.sync { channel.close("test closed") }
        let wrongKey = try PairCrypto.random(32)
        try handshakeFails(receiver, identity: keys[0].tlsIdentity, key: wrongKey, log: log)
        log.flush(); let lines = try String(contentsOf: url)
        XCTAssertTrue(lines.contains("pair.completed")); XCTAssertTrue(lines.contains("tls.negotiated"))
        XCTAssertFalse(lines.contains(token.payload)); XCTAssertFalse(lines.contains("mwiospoc://pair"))
        for secret in [token.secret, token.key, keys[0].deviceKey, newKey, wrongKey] {
            XCTAssertFalse(lines.contains(secret.base64EncodedString())); XCTAssertFalse(lines.contains(secret.base64url))
            XCTAssertFalse(lines.contains(secret.map { String(format: "%02x", $0) }.joined()))
        }
    }
    func testLegacyHelloWithoutAuthenticationAndUnauthenticatedMediaRejected() throws {
        let (receiver, keys) = try receiver(devices: 1)
        for version: UInt8 in [1, 2, 3] {
            let rejected = expectation(description: "unbound hello rejected")
            let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(credential: keys[0])))
            clients.append(channel)
            channel.onReady = { channel.send(.hello(install: UUID(), label: "legacy", version: version, rate: 12)) }
            channel.onMessage = { if case .welcome = $0 { XCTFail("hello bypassed authentication") } }
            channel.onClosed = { _ in rejected.fulfill() }; channel.start(); wait(for: [rejected], timeout: 3)
        }
        let rejected = expectation(description: "screen data before auth rejected")
        let channel = RadioChannel(NWConnection(to: try endpoint(receiver), using: RadioTLS.parameters(credential: keys[0])))
        clients.append(channel); receiver.makeVideoSession = { _, _, _, _ in XCTFail("unbound media reached decoder"); return LoopbackVideoConsumer() }
        channel.onReady = { channel.send(.videoConfig(VideoTests.config)) }
        channel.onClosed = { _ in rejected.fulfill() }; channel.start(); wait(for: [rejected], timeout: 3)
    }
    func testCapacityAndBusyRejectionsRemainAuthenticated() throws {
        let (receiver, keys) = try receiver(devices: 3)
        for key in keys.prefix(2) {
            let welcome = expectation(description: "admitted")
            let channel = try client(receiver, credential: key) { channel, message in
                if case .welcome = message { channel.active = true; welcome.fulfill() }
            }; channel.start(); wait(for: [welcome], timeout: 3)
        }
        let capacity = expectation(description: "authenticated capacity reject")
        let third = try client(receiver, credential: keys[2]) { _, message in
            if case .reject("capacity") = message { capacity.fulfill() }
        }; third.start(); wait(for: [capacity], timeout: 3)
        clients[1].queue.sync { clients[1].close("free slot") }
        let busy = expectation(description: "verified device uniqueness")
        let duplicate = try client(receiver, credential: keys[0]) { _, message in
            if case .reject("busy") = message { busy.fulfill() }
        }; duplicate.start(); wait(for: [busy], timeout: 3)
    }
    func testVideoConfigFragmentReassemblyAckAndGapRecoveryOverV3TLS() throws {
        let (receiver, keys) = try receiver(devices: 1)
        let configured = expectation(description: "config"), reassembled = expectation(description: "frame"), acked = expectation(description: "decode ACK")
        let gap = expectation(description: "gap recovery"), dropped = expectation(description: "drop ACK")
        let frame = VideoAccessUnit(generation: 7, seq: 0, ptsNs: 987654, keyframe: true, data: Data(repeating: 9, count: 140_000))
        receiver.makeVideoSession = { _, _, _, request in
            let consumer = LoopbackVideoConsumer(); consumer.request = request
            consumer.onConfig = { XCTAssertEqual($0, VideoTests.config); configured.fulfill() }
            consumer.onFrame = { XCTAssertEqual($0, frame); reassembled.fulfill() }; return consumer
        }
        let channel = try client(receiver, credential: keys[0], mode: .video) { channel, message in
            switch message {
            case .welcome:
                channel.active = true; channel.send(.videoConfig(VideoTests.config))
                for fragment in try frame.fragments() { channel.send(.videoFragment(fragment)) }
                let missing = VideoAccessUnit(generation: 7, seq: 1, ptsNs: 999, keyframe: false, data: frame.data)
                let parts = try missing.fragments(); channel.send(.videoFragment(parts[0])); channel.send(.videoFragment(parts[2]))
            case .videoAck(seq: 0, ptsNs: 987654, status: .decoded): acked.fulfill()
            case .videoAck(seq: 1, ptsNs: 999, status: .dropped): dropped.fulfill()
            case .keyframeRequest: gap.fulfill()
            case .stats: break
            default: XCTFail("unexpected video control")
            }
        }
        channel.start(); wait(for: [configured, reassembled, acked, gap, dropped], timeout: 3)
    }
    func testOrientationBetweenFragmentsPreservesDecodeAndConfigurationOverTLS() throws {
        let (receiver, keys) = try receiver(devices: 1)
        let hints = expectation(description: "rotation delivered"); hints.expectedFulfillmentCount = 2
        let acked = expectation(description: "unchanged frame decoded and ACKed")
        let frame = VideoAccessUnit(generation: 7, seq: 0, ptsNs: 10, keyframe: true, data: Data(repeating: 7, count: 140_000))
        receiver.makeVideoSession = { _, _, _, _ in
            let consumer = LoopbackVideoConsumer()
            var configurations = 0, rotations = VideoRotationState()
            rotations.automatic = true
            consumer.onConfig = { _ in configurations += 1; XCTAssertEqual(configurations, 1) }
            consumer.onOrientation = { hint in rotations.accept(hint); hints.fulfill() }
            consumer.request = { reason in XCTFail("rotation caused decode recovery: \(reason)") }
            consumer.onFrame = { unit in
                XCTAssertEqual(configurations, 1); XCTAssertEqual(unit, frame)
                XCTAssertEqual(rotations.degrees, 90); XCTAssertEqual(rotations.sourceLabel, "capture")
            }
            return consumer
        }
        let channel = try client(receiver, credential: keys[0], mode: .video) { channel, message in
            switch message {
            case .welcome:
                channel.active = true; channel.send(.videoConfig(VideoTests.config))
                let parts = try frame.fragments(); channel.send(.videoFragment(parts[0]))
                channel.send(.orientationHint(OrientationHint(degrees: 90, source: .capture, monotonicNs: 1)))
                channel.send(.orientationHint(OrientationHint(degrees: 270, source: .device, monotonicNs: 2)))
                for part in parts.dropFirst() { channel.send(.videoFragment(part)) }
            case .videoAck(seq: 0, ptsNs: 10, status: .decoded): acked.fulfill()
            case .stats: break
            default: XCTFail("rotation disturbed video: \(message)")
            }
        }
        channel.start(); wait(for: [hints, acked], timeout: 3)
    }
    func testFullPairThenNormalConnectAndTokenReuseRejected() throws {
        let (receiver, _) = try receiver(), token = try invitation(receiver)
        let paired = expectation(description: "full pairing flow")
        let phoneStore = MemoryPairingKeyStore(); var credential: DeviceCredential?
        receiver.onApproval = { request in if let request { receiver.approve(request.id, allow: true) } }
        let pairer = PairingClient(endpoint: try endpoint(receiver), invitation: token, install: UUID(), label: "phone", model: "iPhone", store: phoneStore)
        pairers.append(pairer); pairer.onPaired = { credential = $0; paired.fulfill() }; changedListener(receiver) { pairer.start() }
        wait(for: [paired], timeout: 5)
        let value = try XCTUnwrap(credential)
        XCTAssertTrue(try phoneStore.credential(rid: token.rid) == value)
        let welcomed = expectation(description: "new device credential works")
        let normal = try client(receiver, credential: value) { channel, message in
            if case .welcome = message { channel.active = true; welcomed.fulfill() }
        }
        normal.start(); wait(for: [welcomed], timeout: 5)
        try handshakeFails(receiver, identity: token.identity, key: token.key)
    }
    func testTwoKeysConcurrentIdentityBindingRevocationAndStreamingIsolation() throws {
        let (receiver, keys) = try receiver(devices: 2)
        let admitted = expectation(description: "both distinct keys selected"); admitted.expectedFulfillmentCount = 2
        let ack = expectation(description: "both video stream ACKs"); ack.expectedFulfillmentCount = 2
        var verifiedIDs = Set<UUID>()
        receiver.onSample = { sample in
            if let id = sample.deviceID { self.lock.lock(); verifiedIDs.insert(id); self.lock.unlock() }
        }
        receiver.makeVideoSession = { _, _, _, _ in LoopbackVideoConsumer() }
        let first = VideoAccessUnit(generation: 7, seq: 0, ptsNs: 10, keyframe: true, data: Data(repeating: 7, count: 1024))
        for key in keys {
            let channel = try client(receiver, credential: key, mode: .video) { channel, message in
                if case .welcome = message {
                    channel.active = true; admitted.fulfill(); channel.send(.videoConfig(VideoTests.config))
                    for part in try first.fragments() { channel.send(.videoFragment(part)) }
                }
                if case .videoAck(seq: 0, ptsNs: 10, status: .decoded) = message {
                    XCTAssertEqual(channel.snapshot.cipherSuite, RadioTLS.cipherSuite)
                    XCTAssertEqual(channel.snapshot.tlsVersion, 0x0303); ack.fulfill()
                }
            }; channel.start()
        }
        wait(for: [admitted, ack], timeout: 5)
        lock.lock(); let verified = verifiedIDs; lock.unlock()
        XCTAssertEqual(verified, Set(keys.map(\.deviceID)))
        // Both keys are registered: identity A with key B and unknown identity with
        // a valid registered key must fail in TLS, not merely at the HMAC gate.
        try handshakeFails(receiver, identity: keys[0].tlsIdentity, key: keys[1].deviceKey)
        try handshakeFails(receiver, identity: "dev:\(UUID().uuidString)", key: keys[0].deviceKey)
        let token = try invitation(receiver)
        changedListener(receiver) { receiver.cancelPairing() }
        try handshakeFails(receiver, identity: token.identity, key: token.key)
        let forged = try client(receiver, credential: keys[0], claim: keys[1].deviceID) { _, message in
            if case .welcome = message { XCTFail("A claimed B") }
        }
        let rejected = expectation(description: "forged device rejected"); forged.onClosed = { _ in rejected.fulfill() }; forged.start()
        wait(for: [rejected], timeout: 5)
        let revoked = expectation(description: "only A receives revoked")
        clients[0].queue.sync { clients[0].onMessage = { if case .bye("revoked") = $0 { revoked.fulfill() } } }
        changedListener(receiver) { receiver.forget(keys[0].deviceID) }; wait(for: [revoked], timeout: 3)
        let continues = expectation(description: "B keeps streaming across listener recreation")
        let second = VideoAccessUnit(generation: 7, seq: 1, ptsNs: 20, keyframe: false, data: first.data)
        try clients[1].queue.sync {
            clients[1].onMessage = { if case .videoAck(seq: 1, ptsNs: 20, status: .decoded) = $0 { continues.fulfill() } }
            for part in try second.fragments() { clients[1].send(.videoFragment(part)) }
        }
        wait(for: [continues], timeout: 3)
        try handshakeFails(receiver, identity: keys[0].tlsIdentity, key: keys[0].deviceKey)
    }
    func testWrongSecretThreeFailuresBurnTokenAndUnpairedIdentityFails() throws {
        let (receiver, _) = try receiver(), token = try invitation(receiver)
        let burned = expectation(description: "three failures burn invitation")
        receiver.onInvitation = { if $0 == nil { burned.fulfill() } }
        for _ in 0..<3 { try handshakeFails(receiver, identity: token.identity, key: PairCrypto.random(32)) }
        wait(for: [burned], timeout: 3); receiver.onInvitation = nil
        try handshakeFails(receiver, identity: token.identity, key: token.key)
        try handshakeFails(receiver, identity: "dev:\(UUID().uuidString)", key: PairCrypto.random(32))
    }
    func testImpostorWithSameReceiverIDFailsBeforeAppData() throws {
        let id = ReceiverIdentity(name: "Same routing hint")
        let (_, keys) = try receiver(devices: 1, identity: id)
        let (impostor, _) = try receiver(devices: 1, deviceIDs: [keys[0].deviceID], identity: id)
        try handshakeFails(impostor, identity: keys[0].tlsIdentity, key: keys[0].deviceKey)
    }
}
private final class TestClock {
    private let lock = NSLock(); private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}
private final class LoopbackVideoConsumer: RadioVideoConsumer {
    var request: ((String) -> Void)?
    var onOrientation: ((OrientationHint) -> Void)?
    func orientationHint(_ hint: OrientationHint) { onOrientation?(hint) }
    var onConfig: ((VideoConfig) throws -> Void)?
    var onFrame: ((VideoAccessUnit) -> Void)?
    func configure(_ config: VideoConfig) throws { try onConfig?(config) }
    func receive(_ frame: VideoAccessUnit, completion: @escaping (VideoDecodeStatus) -> Void) { onFrame?(frame); completion(.decoded) }
    func discontinuity(_ reason: String) { request?(reason) }
    func tick() {}
    func close(_ reason: String) {}
}
#endif

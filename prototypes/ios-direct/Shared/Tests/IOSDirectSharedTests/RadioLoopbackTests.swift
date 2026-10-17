#if os(macOS)
import XCTest
import Network
@testable import IOSDirectShared

/// Uses the production TLS configuration, parser and admission registry. No mocks,
/// plaintext listener, skipped handshake or verification bypass. Requires sockets.
final class RadioLoopbackTests: XCTestCase {
    private var receivers: [RadioReceiver] = []
    private var clients: [RadioChannel] = []
    private var senders: [RadioSender] = []
    private let lock = NSLock()
    override func tearDown() {
        for sender in senders { sender.stop() }
        for client in clients { client.queue.sync { client.close("test teardown") } }
        for receiver in receivers { receiver.stop() }
        clients.removeAll(); senders.removeAll(); receivers.removeAll(); super.tearDown()
    }
    private func receiver(code: RadioCode, onEvent: ((String) -> Void)? = nil,
                          onData: ((UUID, Int) -> Void)? = nil) throws -> (RadioReceiver, NWEndpoint) {
        let receiver = RadioReceiver(label: "Loopback test")
        receivers.append(receiver); receiver.onEvent = onEvent; receiver.onData = onData
        let ready = expectation(description: "TLS listener ready")
        var boundPort: NWEndpoint.Port?
        receiver.onState = { state, port in
            if state == "ready", let port {
                self.lock.lock(); let first = boundPort == nil; boundPort = port; self.lock.unlock()
                if first { ready.fulfill() }
            }
            if state.contains("failed") { XCTFail(state); ready.fulfill() }
        }
        receiver.start(code: code, advertise: false, loopbackOnly: true)
        wait(for: [ready], timeout: 5)
        lock.lock(); let port = boundPort; lock.unlock()
        return (receiver, .hostPort(host: "127.0.0.1", port: try XCTUnwrap(port)))
    }
    private func client(endpoint: NWEndpoint, code: RadioCode, install: UUID = UUID(), version: UInt8 = 1, mode: RadioMode = .synthetic,
                        handler: @escaping (RadioChannel, RadioMessage) throws -> Void) -> RadioChannel {
        let channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(code: code)))
        clients.append(channel); channel.protocolVersion = version
        channel.onReady = { [weak channel] in
            channel?.send(.hello(install: install, label: "same display name", version: version, rate: 12, mode: mode))
        }
        channel.onMessage = { [weak channel] message in guard let channel else { return }; try handler(channel, message) }
        return channel
    }
    func testCorrectCodeHelloWelcomeDataAckAndIndependentSessions() throws {
        let code = try RadioCode(bytes: Data(0..<10)), (_, endpoint) = try receiver(code: code)
        let welcomed = expectation(description: "two distinct sessions"); welcomed.expectedFulfillmentCount = 2
        let acked = expectation(description: "both data ACKs"); acked.expectedFulfillmentCount = 2
        var sessions = Set<UUID>()
        let payload = SyntheticPayload.make(seq: 0, count: 4096)
        for _ in 0..<2 {
            let channel = client(endpoint: endpoint, code: code) { channel, message in
                switch message {
                case .welcome(let session, _):
                    self.lock.lock(); sessions.insert(session); self.lock.unlock()
                    channel.active = true
                    channel.send(.data(seq: 0, time: 111, payload: payload, crc: RadioCRC32.checksum(payload)))
                    welcomed.fulfill()
                case let .ack(seq, time, total):
                    XCTAssertEqual(seq, 0); XCTAssertEqual(time, 111); XCTAssertEqual(total, 4096)
                    XCTAssertEqual(channel.snapshot.tlsVersion, 0x0303)
                    XCTAssertEqual(channel.snapshot.cipherSuite, 0x00a8); acked.fulfill()
                case .stats: break
                default: XCTFail("unexpected \(message)")
                }
            }
            channel.start()
        }
        wait(for: [welcomed, acked], timeout: 8)
        lock.lock(); let count = sessions.count; lock.unlock(); XCTAssertEqual(count, 2)
        clients[0].queue.sync { clients[0].close("isolation test") }
        let continued = expectation(description: "second session continues after first closes")
        clients[1].queue.sync {
            clients[1].onMessage = { message in
                if case let .ack(seq, _, total) = message { XCTAssertEqual(seq, 1); XCTAssertEqual(total, 8192); continued.fulfill() }
            }
            clients[1].send(.data(seq: 1, time: 222, payload: payload, crc: RadioCRC32.checksum(payload)))
        }
        wait(for: [continued], timeout: 5)
    }
    func testWrongCodeFailsHandshakeAndNeverDeliversPayload() throws {
        let good = try RadioCode(bytes: Data(repeating: 0, count: 10))
        let wrong = try RadioCode(bytes: Data(repeating: 1, count: 10))
        let noData = expectation(description: "no payload delivered"); noData.isInverted = true
        let (_, endpoint) = try receiver(code: good, onData: { _, _ in noData.fulfill() })
        let failed = expectation(description: "client reports wrong code within two seconds")
        let sender = RadioSender(endpoint: endpoint, code: wrong, rate: 12, install: UUID(), label: "wrong code test")
        senders.append(sender)
        let started = radioNow()
        sender.onSample = { sample in
            XCTAssertNil(sample.tlsVersion)
            XCTAssertEqual(sample.sentBytes, 0)
        }
        sender.onState = { state in
            XCTAssertNotEqual(state, "TLS ready; awaiting welcome")
            XCTAssertNotEqual(state, "sending synthetic payload")
            if state.hasPrefix("Wrong code or handshake failed") {
                XCTAssertLessThan(Double(radioNow() - started) / 1e9, 2, state)
                failed.fulfill()
            }
        }
        sender.start()
        wait(for: [failed], timeout: 2); wait(for: [noData], timeout: 0.5)
    }
    func testCapacityProbeAndBlockedTelemetryReachReceiver() throws {
        let code = try RadioCode(bytes: Data(0..<10)), (receiver, endpoint) = try receiver(code: code)
        let sampled = expectation(description: "receiver has sender pacing telemetry")
        var receivedSample = false
        receiver.onSample = { sample in
            guard sample.sendBlockedMSPerSecond != nil, !receivedSample else { return }
            receivedSample = true
            XCTAssertEqual(sample.windowMode, .capacityProbe)
            XCTAssertEqual(sample.windowBytes, 2_097_152)
            XCTAssertGreaterThan(sample.deliveredBytes, 0)
            XCTAssertGreaterThanOrEqual(sample.sendBlockedMSPerSecond ?? -1, 0)
            sampled.fulfill()
        }
        let sender = RadioSender(endpoint: endpoint, code: code, rate: 48, window: .capacityProbe,
                                 install: UUID(), label: "probe")
        senders.append(sender); sender.start()
        wait(for: [sampled], timeout: 5)
    }
    func testThirdClientReceivesExplicitCapacityRejection() throws {
        let code = try RadioCode(bytes: Data(0..<10)), (_, endpoint) = try receiver(code: code)
        let welcomed = expectation(description: "two active clients"); welcomed.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            let channel = client(endpoint: endpoint, code: code) { channel, message in
                if case .welcome = message { channel.active = true; welcomed.fulfill() }
                else if case .stats = message {} else { XCTFail("unexpected message") }
            }
            channel.start()
        }
        wait(for: [welcomed], timeout: 8)
        let rejected = expectation(description: "explicit authenticated reject capacity")
        let third = client(endpoint: endpoint, code: code) { channel, message in
            guard case .reject(let reason) = message else { XCTFail("third client admitted"); return }
            XCTAssertEqual(reason, "capacity"); XCTAssertEqual(channel.snapshot.tlsVersion, 0x0303); rejected.fulfill()
        }
        third.start(); wait(for: [rejected], timeout: 8)
    }
    func testPendingLimitAndFiveSecondHelloTimeout() throws {
        let code = try RadioCode(bytes: Data(0..<10))
        let ready = expectation(description: "two pending TLS clients"); ready.expectedFulfillmentCount = 2
        let timedOut = expectation(description: "hello timeout releases both slots"); timedOut.expectedFulfillmentCount = 2
        let refused = expectation(description: "third pending socket refused before TLS")
        let (_, endpoint) = try receiver(code: code, onEvent: { event in
            if event.contains("pending handshake limit") { refused.fulfill() }
            if event.contains("session.removed"), event.contains("5 s TLS/hello timeout") { timedOut.fulfill() }
        })
        for _ in 0..<2 {
            let channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(code: code)))
            clients.append(channel)
            channel.onReady = { ready.fulfill() } // Deliberately omit hello.
            channel.start()
        }
        wait(for: [ready], timeout: 3)
        let third = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(code: code)))
        clients.append(third)
        third.onReady = { XCTFail("pending cap allowed a third TLS handshake") }
        third.start(); wait(for: [refused], timeout: 1)
        wait(for: [timedOut], timeout: 6)
        let admitted = expectation(description: "pending slots reusable after timeout")
        let fresh = client(endpoint: endpoint, code: code) { channel, message in
            if case .welcome = message { channel.active = true; admitted.fulfill() }
        }
        fresh.start(); wait(for: [admitted], timeout: 5)
    }

    func testVideoConfigFragmentedBytesAndDecodeStatusAckOverTLS() throws {
        let code = try RadioCode(bytes: Data(0..<10)), (receiver, endpoint) = try receiver(code: code)
        let configured = expectation(description: "v2 config delivered")
        let reassembled = expectation(description: "identical fragmented access unit")
        let acked = expectation(description: "per-frame ACK after consumer result")
        let frame = VideoAccessUnit(generation: 7, seq: 0, ptsNs: 987654, keyframe: true,
                                    data: SyntheticPayload.make(seq: 0, count: 140_000))
        receiver.makeVideoSession = { _, _, request in
            let consumer = LoopbackVideoConsumer(request: request)
            consumer.onConfig = { config in XCTAssertEqual(config, VideoTests.config); configured.fulfill() }
            consumer.onFrame = { unit in XCTAssertEqual(unit, frame); reassembled.fulfill(); return .decoded }
            return consumer
        }
        let client = client(endpoint: endpoint, code: code, version: 2, mode: .video) { channel, message in
            switch message {
            case .welcome:
                channel.active = true
                channel.send(.videoConfig(VideoTests.config))
                for fragment in try frame.fragments() { channel.send(.videoFragment(fragment)) }
            case let .videoAck(seq, pts, status):
                XCTAssertEqual(seq, 0); XCTAssertEqual(pts, frame.ptsNs); XCTAssertEqual(status, .decoded)
                XCTAssertEqual(channel.snapshot.tlsVersion, 0x0303); XCTAssertEqual(channel.snapshot.cipherSuite, 0x00a8)
                acked.fulfill()
            case .stats: break
            default: XCTFail("unexpected video message \(message)")
            }
        }
        client.start(); wait(for: [configured, reassembled, acked], timeout: 8)
    }
    func testVideoFragmentGapRequestsKeyframeAndAcksDroppedFrameOverTLS() throws {
        let code = try RadioCode(bytes: Data(0..<10)), (receiver, endpoint) = try receiver(code: code)
        let request = expectation(description: "fragment gap requests keyframe")
        let dropped = expectation(description: "abandoned frame releases sender window")
        receiver.makeVideoSession = { _, _, request in LoopbackVideoConsumer(request: request) }
        let frame = VideoAccessUnit(generation: 7, seq: 0, ptsNs: 123, keyframe: true, data: Data(count: 140_000))
        let client = client(endpoint: endpoint, code: code, version: 2, mode: .video) { channel, message in
            switch message {
            case .welcome:
                channel.active = true; channel.send(.videoConfig(VideoTests.config))
                let fragments = try frame.fragments()
                channel.send(.videoFragment(fragments[0])); channel.send(.videoFragment(fragments[2]))
            case .keyframeRequest: request.fulfill()
            case let .videoAck(seq, pts, status):
                XCTAssertEqual(seq, 0); XCTAssertEqual(pts, 123); XCTAssertEqual(status, .dropped); dropped.fulfill()
            case .stats: break
            default: XCTFail("unexpected gap message \(message)")
            }
        }
        client.start(); wait(for: [request, dropped], timeout: 8)
    }

}

/// This consumer deliberately tests transport/reassembly only, not H.264 decoding.
private final class LoopbackVideoConsumer: RadioVideoConsumer {
    var onConfig: ((VideoConfig) -> Void)?
    var onFrame: ((VideoAccessUnit) -> VideoDecodeStatus)?
    let request: (String) -> Void
    init(request: @escaping (String) -> Void) { self.request = request }
    func configure(_ config: VideoConfig) throws { onConfig?(config) }
    func receive(_ frame: VideoAccessUnit, completion: @escaping (VideoDecodeStatus) -> Void) {
        completion(onFrame?(frame) ?? .dropped)
    }
    func discontinuity(_ reason: String) { request(reason) }
    func tick() {}
    func close(_ reason: String) {}
}
#endif

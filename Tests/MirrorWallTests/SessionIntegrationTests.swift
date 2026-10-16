import XCTest
import Network
import CoreGraphics
import MirrorCore
@testable import MirrorWall

final class SessionIntegrationTests: XCTestCase {
    func testInvalidatedAndReplacedStreamsRejectQueuedWork() {
        let lifetime = StreamLifetime()
        let old = lifetime.stamp
        lifetime.advance()
        XCTAssertFalse(lifetime.isCurrent(old))
        XCTAssertTrue(lifetime.isCurrent(lifetime.stamp))
        lifetime.invalidate()
        XCTAssertFalse(lifetime.isCurrent(lifetime.stamp))
    }

    @MainActor func testScreenOffGraceAndPersistentHide() {
        let slot = Slot(config: SlotConfig(id: 1, name: "Test"))
        slot.setShowsOnStage(false)
        slot.apply(.clientConnecting(name: "Test", model: "iPhone14,6", deviceID: "test"))
        slot.apply(.streamStarted)
        slot.apply(.streamPaused)
        slot.receivedFrame(dimensions: nil) // late lock-screen frame is not a resume
        XCTAssertEqual(slot.state, .paused)
        slot.checkForSilence(now: Date().addingTimeInterval(61))
        XCTAssertEqual(slot.state, .paused)
        slot.checkForSilence(now: Date().addingTimeInterval(301))
        XCTAssertEqual(slot.state, .disconnected)
        slot.apply(.clientConnecting(name: "Test", model: "iPhone14,6", deviceID: "test"))
        XCTAssertFalse(slot.showsOnStage)
    }

    @MainActor func testFreezeSurvivesSameDeviceButNotReplacement() async throws {
        let slot = Slot(config: SlotConfig(id: 1, name: "Test"))
        slot.apply(.clientConnecting(name: "A", model: "", deviceID: "a"))
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        slot.freeze(try XCTUnwrap(context.makeImage()))
        slot.stop()
        await slot.finishStopping()
        slot.apply(.clientConnecting(name: "A", model: "", deviceID: "a"))
        XCTAssertTrue(slot.isFrozen)
        slot.apply(.clientConnecting(name: "B", model: "", deviceID: "b"))
        XCTAssertFalse(slot.isFrozen)
    }

    func testSecondInstanceCannotAcquireOwnership() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var first: InstanceLock? = InstanceLock()
        let second = InstanceLock()
        XCTAssertTrue(first!.acquire(at: url))
        XCTAssertFalse(second.acquire(at: url))
        first = nil
        XCTAssertTrue(second.acquire(at: url))
    }

    func testStopMessageArrivesBeforeServerCloses() async throws {
        let ready = expectation(description: "listener")
        let welcomed = expectation(description: "welcome")
        let stopped = expectation(description: "intentional stop")
        let server = CastServer(port: 0, name: "Regression test") { phone in
            phone.onMessage = { message in
                if case .hello = message { phone.accept(CastWelcome(slot: "Test", maxFrameRate: 30)) }
            }
        }
        try server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listeningPort)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { client.cancel(); server.stop() }
        let reader = CastReader()
        func receive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, ended, error in
                if let data, let messages = try? reader.push(Array(data)) {
                    for message in messages {
                        if case .welcome = message { welcomed.fulfill() }
                        if case .stopSharing = message { stopped.fulfill() }
                    }
                }
                if !ended && error == nil { receive() }
            }
        }
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: Data(CastMessage.hello(CastHello(name: "test", model: "test", deviceID: "test")).encoded()), completion: .contentProcessed { _ in })
                receive()
            }
        }
        client.start(queue: DispatchQueue(label: "cast-test"))
        await fulfillment(of: [welcomed], timeout: 5)
        await Task.detached { server.stop(endingSharing: true) }.value
        await fulfillment(of: [stopped], timeout: 5)
    }
}

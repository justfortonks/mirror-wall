#if os(macOS)
import XCTest
import Network
@testable import IOSDirectShared

final class PairingClientLoopbackTests: XCTestCase {
    func testGrantWithoutConfirmationFailsVisiblyAndCleansStoreWithinFiveSeconds() throws {
        let token = try PairingInvitation(rid: UUID(), name: "Mac")
        let credential = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: token.rid, receiverName: "Mac")
        let store = MemoryPairingKeyStore()
        let listener = try NWListener(using: RadioTLS.parameters(identities: [(token.identity, token.key)]), on: .any)
        let listening = expectation(description: "listener ready"), failed = expectation(description: "visible terminal failure")
        var server: RadioChannel?, decision: UInt64 = 0
        listener.newConnectionHandler = { connection in
            let channel = RadioChannel(connection); server = channel
            channel.onReady = { [weak channel] in channel?.send(.authChallenge(Data(repeating: 1, count: 32))) }
            channel.onMessage = { [weak channel] message in
                guard let channel else { return }
                switch message {
                case .authResponse: break
                case .pairRequest: decision = radioNow(); channel.send(.pairGrant(credential))
                case .pairDone: break // Simulate loss of the Mac's final acknowledgement.
                default: XCTFail("unexpected pairing message")
                }
            }
            channel.start()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: DispatchQueue(label: "pairing.timeout.test"))
        wait(for: [listening], timeout: 3)
        let client = PairingClient(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)),
            invitation: token, install: UUID(), label: "Phone", model: "test", store: store)
        defer { client.cancel(); server?.queue.sync { server?.close("test end") }; listener.cancel() }
        var progress: [PairingProgress] = []
        client.onProgress = { value in
            progress.append(value)
            if case .failed(let reason) = value {
                XCTAssertTrue(reason.contains("did not confirm"))
                XCTAssertLessThan(Double(radioNow() - decision) / 1e9, 5)
                XCTAssertNil(try? store.credential(rid: token.rid))
                failed.fulfill()
            }
        }
        client.onPaired = { _ in XCTFail("unconfirmed grant must not appear paired") }
        client.start(); wait(for: [failed], timeout: 5.5)
        XCTAssertEqual(progress.count, 4)
        XCTAssertEqual(Array(progress.prefix(3)), [.connecting, .awaitingApproval, .finishing])
    }
}
#endif

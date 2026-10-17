import XCTest
@testable import IOSDirectShared

final class ClientSessionPolicyTests: XCTestCase {
    func testOnlyWelcomedAttemptCanReconnectAfterLinkLoss() {
        var policy = ClientSessionPolicy()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: true), .stop)
        policy.welcomed()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: true), .retry)
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: false), .retry)
        // The retry is a fresh TLS attempt. A prior welcome cannot authorize a
        // chain of retries of attempts that have never reached welcome themselves.
        policy.beginAttempt()
        XCTAssertTrue(policy.everWelcomed); XCTAssertFalse(policy.welcomedThisAttempt)
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: false), .stop)
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: false), .stop)
        policy.welcomed()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: false), .retry)
    }
    func testAuthenticationRejectionAlwaysStopsEvenAfterEarlierWelcome() {
        var policy = ClientSessionPolicy(); policy.welcomed()
        for cause: RadioCloseCause in [.authentication, .admissionDeadline(tlsReady: false), .admissionDeadline(tlsReady: true),
            .rejected("unpaired"), .rejected("auth failure"), .rejected("authentication failed")] {
            XCTAssertEqual(policy.action(for: cause, receiverDiscovered: true), .pairingRejected(.notAccepted))
        }
        XCTAssertEqual(policy.action(for: .revoked, receiverDiscovered: true), .pairingRejected(.revoked))
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: true), receiverDiscovered: false), .pairingRejected(.notAccepted))
        policy.beginAttempt()
        // Discovery + preparing is the silent rejection seen on the phone in run 1.
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false, preparing: true), receiverDiscovered: true), .pairingRejected(.notAccepted))
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false, preparing: false), receiverDiscovered: true), .stop)
        for cause: RadioCloseCause in [.localStop, .peerEnded, .protocolFailure, .rejected("capacity"), .rejected("busy")] {
            XCTAssertEqual(policy.action(for: cause, receiverDiscovered: true), .stop)
        }
    }
    func testRevokedDeletesOnlyThatReceiverButAmbiguousFailurePreservesCredential() throws {
        let store = MemoryPairingKeyStore(), a = UUID(), b = UUID()
        for rid in [a, b] { try store.save(DeviceCredential(deviceID: UUID(), deviceKey: PairCrypto.random(32), rid: rid, receiverName: "Mac")) }
        try PairingRejection.notAccepted.apply(to: store, rid: a)
        XCTAssertNotNil(try store.credential(rid: a))
        try PairingRejection.revoked.apply(to: store, rid: a)
        XCTAssertNil(try store.credential(rid: a)); XCTAssertNotNil(try store.credential(rid: b))
        let replacement = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: a, receiverName: "Mac")
        try store.save(replacement)
        try PairingRejection.revoked.apply(to: store, rid: a, deviceID: UUID())
        XCTAssertEqual(try store.credential(rid: a)?.deviceID, replacement.deviceID, "an old session cannot delete a newly paired identity")
    }
    func testRejectedStatusPersistsAndSuccessfulRepairClearsIt() throws {
        let a = UUID(), b = UUID(); var status = ReceiverPairingStatus()
        status.reject(a, reason: .notAccepted)
        XCTAssertEqual(status.label(rid: a, hasCredential: true), "Pairing rejected")
        XCTAssertEqual(status.label(rid: b, hasCredential: true), "Paired")
        status = try JSONDecoder().decode(ReceiverPairingStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(status[a]?.message, "This Mac didn't accept this phone. It may have been forgotten on the Mac.")
        status.clear(a); XCTAssertEqual(status.label(rid: a, hasCredential: true), "Paired")
        status.reject(a, reason: .revoked)
        XCTAssertEqual(status.label(rid: a, hasCredential: false), "Not paired")
        XCTAssertEqual(status[a]?.message, "This Mac forgot this phone. Pair again to reconnect.")
    }
    func testWindowRebindByVerifiedDeviceIgnoresObsoleteSessionCallbacks() {
        var windows = VideoWindowSessions()
        let a = UUID(), b = UUID(), a1 = UUID(), a2 = UUID(), b1 = UUID()
        XCTAssertFalse(windows.bind(device: a, session: a1))
        XCTAssertFalse(windows.bind(device: b, session: b1))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.device(for: a1), a)
        // A disconnected window remains in this registry until manual close.
        XCTAssertTrue(windows.bind(device: a, session: a2))
        XCTAssertNil(windows.device(for: a1)); XCTAssertEqual(windows.device(for: a2), a)
        XCTAssertEqual(windows.device(for: b1), b); XCTAssertEqual(windows.count, 2)
        windows.close(device: a)
        XCTAssertNil(windows.device(for: a2)); XCTAssertEqual(windows.count, 1)
        XCTAssertFalse(windows.bind(device: a, session: UUID()), "manual close reopens on the next session")
    }
}

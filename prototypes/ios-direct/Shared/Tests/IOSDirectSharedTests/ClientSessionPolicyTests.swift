import XCTest
import Network
@testable import IOSDirectShared

final class ClientSessionPolicyTests: XCTestCase {
    func testLinkLossRetriesAfterWelcomeOrAStalledAdmission() {
        var policy = ClientSessionPolicy()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: true), .stop)
        policy.welcomed()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: true), .retry)
        policy.beginAttempt()
        XCTAssertTrue(policy.everWelcomed); XCTAssertFalse(policy.welcomedThisAttempt)
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: false), .retry)
        policy = ClientSessionPolicy()
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: false), .retry)
        policy.beginAttempt()
        XCTAssertEqual(policy.action(for: .linkLoss, receiverDiscovered: false), .retry)
    }
    func testOnlyAuthenticationEvidenceRejectsPairing() {
        var policy = ClientSessionPolicy(); policy.welcomed()
        for cause: RadioCloseCause in [.authentication, .rejected("unpaired")] {
            XCTAssertEqual(policy.action(for: cause, receiverDiscovered: true), .pairingRejected(.notAccepted))
        }
        XCTAssertEqual(policy.action(for: .revoked, receiverDiscovered: true), .pairingRejected(.revoked))
        for cause: RadioCloseCause in [.localStop, .peerEnded, .protocolFailure, .rejected("capacity"), .rejected("busy"), .rejected("auth failure")] {
            XCTAssertEqual(policy.action(for: cause, receiverDiscovered: true), .stop)
        }
        // A deadline, including one after TLS ready, is not a peer rejection.
        for ready in [false, true] {
            for preparing in [false, true] {
                var attempt = ClientSessionPolicy()
                XCTAssertEqual(attempt.action(for: .admissionDeadline(tlsReady: ready, preparing: preparing), receiverDiscovered: true), .retry)
            }
        }
    }
    func testThreeConsecutiveDiscoveredStallsStopWithoutChangingPairing() throws {
        let rid = UUID(), store = MemoryPairingKeyStore()
        let credential = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: rid, receiverName: "Mac")
        try store.save(credential)
        var policy = ClientSessionPolicy()
        for index in 1...3 {
            policy.beginAttempt()
            XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false, preparing: true), receiverDiscovered: true), index == 3 ? .unreachable : .retry)
            XCTAssertEqual(policy.consecutiveStalls, index)
        }
        XCTAssertEqual(ClientSessionPolicy.unreachableMessage, "Can't reach this Mac. If it was forgotten on the Mac, pair again.")
        XCTAssertEqual(try store.credential(rid: rid), credential)
        XCTAssertEqual(ReceiverPairingStatus().label(rid: rid, hasCredential: true), "Paired")
        policy = ClientSessionPolicy() // Explicit Try again starts a new budget.
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: true), .retry)
    }
    func testStallsMustBeConsecutiveAndCurrentlyDiscovered() {
        var policy = ClientSessionPolicy()
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: true), .retry)
        policy.beginAttempt() // Starting another attempt does not reset the budget.
        XCTAssertEqual(policy.consecutiveStalls, 1)
        XCTAssertEqual(policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: false), .retry)
        XCTAssertEqual(policy.consecutiveStalls, 0)
        _ = policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: true)
        policy.receiverUnavailable(); XCTAssertEqual(policy.consecutiveStalls, 0)
        _ = policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: true)
        policy.welcomed(); XCTAssertEqual(policy.consecutiveStalls, 0)
        _ = policy.action(for: .admissionDeadline(tlsReady: false), receiverDiscovered: true)
        _ = policy.action(for: .linkLoss, receiverDiscovered: true)
        XCTAssertEqual(policy.consecutiveStalls, 0)
    }
    func testNWErrorsDistinguishPeerResetAfterTLSFromPreparingStall() {
        XCTAssertEqual(RadioChannel.classify(.tls(-9858), tlsReady: false, welcomed: false), .authentication)
        XCTAssertEqual(RadioChannel.classify(.posix(.ECONNRESET), tlsReady: false, welcomed: false), .linkLoss)
        XCTAssertEqual(RadioChannel.classify(.posix(.ECONNRESET), tlsReady: true, welcomed: false), .authentication)
        XCTAssertEqual(RadioChannel.classify(.posix(.ECONNRESET), tlsReady: true, welcomed: true), .linkLoss)
        XCTAssertEqual(RadioChannel.classify(.posix(.ECONNABORTED), tlsReady: true, welcomed: false), .linkLoss)
        XCTAssertEqual(RadioChannel.classify(.posix(.ETIMEDOUT), tlsReady: true, welcomed: false), .linkLoss)
    }
    func testFreshBrowseEpochRejectsCachedAndLateResultsAcrossSuspension() {
        let rid = UUID(); var discovery = FreshReceiverResults<String>()
        let beforeSuspension = discovery.generation
        XCTAssertTrue(discovery.update([rid: "cached endpoint"], generation: beforeSuspension))
        XCTAssertNotNil(discovery.endpoint(for: rid))
        let foreground = discovery.restart()
        XCTAssertNil(discovery.endpoint(for: rid), "never reuse pre-suspension cache")
        XCTAssertFalse(discovery.update([rid: "late old callback"], generation: beforeSuspension))
        XCTAssertNil(discovery.endpoint(for: rid))
        XCTAssertTrue(discovery.update([rid: "fresh endpoint"], generation: foreground))
        XCTAssertEqual(discovery.endpoint(for: rid), "fresh endpoint")
        _ = discovery.restart() // Each retry also requires a new browse callback.
        XCTAssertNil(discovery.endpoint(for: rid))
    }
    func testReconnectBackoffCapsAtFourSeconds() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<7).map { _ in backoff.next() }, [0.5, 1, 2, 4, 4, 4, 4])
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
    func testMigrationClearsOldTimeoutRejectionHintsButKeepsRevocation() {
        let a = UUID(), b = UUID(); var status = ReceiverPairingStatus()
        status.reject(a, reason: .notAccepted); status.reject(b, reason: .revoked)
        status.clearLegacyReachabilityRejections()
        XCTAssertEqual(status.label(rid: a, hasCredential: true), "Paired")
        XCTAssertEqual(status[b], .revoked)
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

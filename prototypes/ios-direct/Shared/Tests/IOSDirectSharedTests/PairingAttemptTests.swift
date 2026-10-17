import XCTest
@testable import IOSDirectShared

final class PairingAttemptTests: XCTestCase {
    func testScanAfterRejectionAndRevokeStartsFreshAttempt() throws {
        for rejection in [PairingRejection.notAccepted, .revoked] {
            var status = ReceiverPairingStatus(), attempt = PairingAttempt()
            let rid = UUID(); status.reject(rid, reason: rejection)
            let id = try XCTUnwrap(attempt.begin())
            XCTAssertTrue(attempt.busy)
            XCTAssertTrue(attempt.update(.connecting, attempt: id))
            XCTAssertTrue(attempt.update(.awaitingApproval, attempt: id))
            XCTAssertTrue(attempt.update(.failed("Denied on Mac"), attempt: id))
            XCTAssertFalse(attempt.busy); XCTAssertEqual(attempt.message, "Denied on Mac")
            let next = try XCTUnwrap(attempt.begin()); XCTAssertNotEqual(next, id)
            XCTAssertFalse(attempt.update(.failed("old callback"), attempt: id))
            XCTAssertTrue(attempt.update(.paired, attempt: next))
            XCTAssertEqual(attempt.message, "Paired"); XCTAssertFalse(attempt.busy)
        }
    }
    func testSecondScanIsIgnoredWithVisibleMessageAndKeepsOriginalAttempt() throws {
        var attempt = PairingAttempt()
        let id = try XCTUnwrap(attempt.begin())
        XCTAssertNil(attempt.begin()); XCTAssertEqual(attempt.id, id)
        XCTAssertTrue(attempt.message.contains("Pairing already in progress"))
        XCTAssertTrue(attempt.update(.finishing, attempt: id))
        XCTAssertTrue(attempt.update(.paired, attempt: id)); XCTAssertFalse(attempt.busy)
    }
    func testCancelInvalidatesCallbacksBeforeNextScan() throws {
        var attempt = PairingAttempt()
        let first = try XCTUnwrap(attempt.begin()); attempt.cancel()
        let second = try XCTUnwrap(attempt.begin())
        XCTAssertFalse(attempt.update(.paired, attempt: first)); XCTAssertEqual(attempt.id, second)
        for failure in ["Pairing failed: handshake", PairingInvitationError.expired.description, "Denied on Mac"] {
            XCTAssertTrue(attempt.update(.failed(failure), attempt: attempt.id!))
            XCTAssertFalse(attempt.busy); XCTAssertEqual(attempt.message, failure)
            XCTAssertNotNil(attempt.begin())
        }
    }
    func testSuccessRefreshesStoredPairingAndRejectionLabelWithoutRelaunch() throws {
        let store = MemoryPairingKeyStore(), rid = UUID()
        var presence = PairingCredentialPresence(), status = ReceiverPairingStatus(), attempt = PairingAttempt()
        status.reject(rid, reason: .revoked); try presence.refresh(rid, store: store)
        XCTAssertEqual(status.label(rid: rid, hasCredential: presence.receivers.contains(rid)), "Not paired")
        let id = try XCTUnwrap(attempt.begin())
        let credential = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: rid, receiverName: "Mac")
        try store.save(credential) // pairGrant, then authenticated pairDone acknowledgement.
        try presence.refresh(rid, store: store); status.clear(rid)
        XCTAssertTrue(attempt.update(.paired, attempt: id))
        XCTAssertEqual(status.label(rid: rid, hasCredential: presence.receivers.contains(rid)), "Paired")
        XCTAssertEqual(attempt.message, "Paired")
        try PairingRejection.revoked.apply(to: store, rid: rid, deviceID: credential.deviceID)
        try presence.refresh(rid, store: store); XCTAssertFalse(presence.receivers.contains(rid))
    }

}

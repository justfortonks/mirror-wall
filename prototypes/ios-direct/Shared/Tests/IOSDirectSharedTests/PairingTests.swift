import XCTest
@testable import IOSDirectShared

final class PairingTests: XCTestCase {
    func testQRCodeRoundTripCanonicalBase64AndClockSkew() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try PairingInvitation(rid: UUID(), name: "Mac & screen + café", now: now)
        let parsed = try PairingInvitation(payload: token.payload, now: now)
        XCTAssertTrue(token == parsed)
        XCTAssertEqual(token.tokenID.count, 8); XCTAssertEqual(token.secret.count, 32); XCTAssertEqual(token.key.count, 32)
        XCTAssertFalse(token.secret.base64url.contains("=")); XCTAssertFalse(token.tokenID.base64url.contains("="))
        XCTAssertNoThrow(try PairingInvitation(payload: token.payload, now: token.expires.addingTimeInterval(30)))
        XCTAssertThrowsError(try PairingInvitation(payload: token.payload, now: token.expires.addingTimeInterval(31)))
        XCTAssertThrowsError(try PairingInvitation(payload: token.payload, now: now.addingTimeInterval(-31)))
    }
    func testQRCodeRejectsBadVersionMissingDuplicateFieldsAndBadBase64() throws {
        let now = Date(), token = try PairingInvitation(rid: UUID(), name: "Mac", now: now)
        var url = try XCTUnwrap(URLComponents(string: token.payload))
        for key in ["v", "rid", "tid", "sec", "exp", "name"] {
            var missing = url; missing.queryItems?.removeAll { $0.name == key }
            XCTAssertThrowsError(try PairingInvitation(payload: missing.string!, now: now), key)
        }
        for (field, value) in [("v", "2"), ("rid", "invalid"), ("sec", "+++="), ("tid", "____"), ("exp", "NaN"), ("name", "")] {
            var bad = url; bad.queryItems?.removeAll { $0.name == field }; bad.queryItems?.append(URLQueryItem(name: field, value: value))
            XCTAssertThrowsError(try PairingInvitation(payload: bad.string!, now: now), field)
        }
        url.queryItems?.append(URLQueryItem(name: "v", value: "1"))
        XCTAssertThrowsError(try PairingInvitation(payload: url.string!, now: now))
        XCTAssertThrowsError(try PairingInvitation(payload: "https://pair?v=1", now: now))
        XCTAssertNil(Data(base64url: token.secret.base64url + "=", count: 32))
    }
    func testInvitationValidationReportsExactRecoveryErrorsBeforeConnecting() throws {
        let now = Date(), rid = UUID(), token = try PairingInvitation(rid: rid, name: "Mac", now: now)
        XCTAssertNoThrow(try PairingInvitation(payload: token.payload, expectedReceiverID: rid, now: now))
        XCTAssertThrowsError(try PairingInvitation(payload: token.payload, expectedReceiverID: UUID(), now: now)) {
            XCTAssertEqual($0 as? PairingInvitationError, .differentReceiver)
            XCTAssertEqual(String(describing: $0), "This code is for a different Mac")
        }
        XCTAssertNoThrow(try PairingInvitation(payload: token.payload, now: token.expires.addingTimeInterval(30)))
        XCTAssertThrowsError(try PairingInvitation(payload: token.payload, now: token.expires.addingTimeInterval(30.01))) {
            XCTAssertEqual($0 as? PairingInvitationError, .expired)
            XCTAssertEqual(String(describing: $0), "This pairing code has expired — make a new one on the Mac")
        }
        for payload in ["not a QR invitation", "https://example.com", token.payload.replacingOccurrences(of: "v=1", with: "v=9")] {
            XCTAssertThrowsError(try PairingInvitation(payload: payload, now: now)) {
                XCTAssertEqual($0 as? PairingInvitationError, .invalidCode)
                XCTAssertEqual(String(describing: $0), "Not a pairing code")
            }
        }
    }
    func testRepairReplacesStoredCredentialForTheSameReceiverID() throws {
        let store = MemoryPairingKeyStore(), rid = UUID()
        let first = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: rid, receiverName: "Mac")
        let second = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: rid, receiverName: "Mac")
        try store.save(first); try store.save(second)
        XCTAssertEqual(try store.credential(rid: rid)?.deviceID, second.deviceID)
        XCTAssertTrue(try store.credential(rid: rid)?.deviceKey == second.deviceKey)
    }
    func testProofBindsNonceReceiverAndDevice() throws {
        let key = try PairCrypto.random(32), nonce = try PairCrypto.random(32), rid = UUID(), device = UUID().uuidString
        let proof = PairCrypto.proof(key: key, nonce: nonce, rid: rid, identity: device)
        XCTAssertTrue(PairCrypto.verify(proof, key: key, nonce: nonce, rid: rid, identity: device))
        XCTAssertFalse(PairCrypto.verify(proof, key: key, nonce: nonce, rid: UUID(), identity: device))
        XCTAssertFalse(PairCrypto.verify(proof, key: key, nonce: nonce, rid: rid, identity: UUID().uuidString))
        XCTAssertFalse(PairCrypto.verify(proof, key: key, nonce: Data(count: 32), rid: rid, identity: device))
        XCTAssertFalse(PairCrypto.verify(Data(proof.dropLast()), key: key, nonce: nonce, rid: rid, identity: device))
    }
    func testV3AuthenticationAndPairingBinaryRoundTrips() throws {
        let credential = DeviceCredential(deviceID: UUID(), deviceKey: try PairCrypto.random(32), rid: UUID(), receiverName: "Mac")
        for message: RadioMessage in [.authChallenge(try PairCrypto.random(32)), .authResponse(credential.deviceID.uuidString, try PairCrypto.random(32)),
            .pairRequest(install: UUID(), label: "Phone", model: "iPhone"), .pairGrant(credential), .pairDone, .pairDenied,
            .hello(install: UUID(), label: "Phone", version: 3, rate: 6, mode: .video)] {
            let frame = try message.frame(); XCTAssertEqual(frame.version, 3)
            XCTAssertTrue(try RadioMessage(frame) == message)
            XCTAssertThrowsError(try RadioMessage(RadioFrame(frame.type, frame.body + Data([0]), version: 3)))
        }
    }
    func testPersistenceSeparatesKeysMetadataAndPhoneForget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receiver.json")
        let identity = try ReceiverIdentity.load(at: url, name: "First name")
        XCTAssertEqual(try ReceiverIdentity.load(at: url, name: "Changed name"), identity)
        let metadata = directory.appendingPathComponent("devices.json"), keys = MemoryPairingKeyStore()
        let store = try ReceiverPairingStore(identity: identity, keys: keys, metadataURL: metadata)
        let id = UUID(), key = try PairCrypto.random(32)
        try store.add(PairedDevice(id: id, installID: UUID(), label: "Phone", model: "iPhone"), key: key)
        let loaded = try ReceiverPairingStore(identity: identity, keys: keys, metadataURL: metadata)
        XCTAssertEqual(loaded.devices.map(\.id), [id]); XCTAssertTrue(try loaded.key(id) == key)
        let json = try String(contentsOf: metadata)
        XCTAssertFalse(json.contains(key.base64EncodedString())); XCTAssertFalse(json.contains("deviceKey"))
        let phone = MemoryPairingKeyStore()
        try phone.save(DeviceCredential(deviceID: id, deviceKey: key, rid: identity.id, receiverName: identity.name))
        try phone.delete(account: identity.id.uuidString); XCTAssertNil(try phone.credential(rid: identity.id))
        try loaded.forget(id); XCTAssertNil(try loaded.key(id)); XCTAssertNil(try keys.read(account: id.uuidString))
    }
}

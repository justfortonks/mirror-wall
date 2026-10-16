import XCTest
@testable import MirrorCore

final class SessionPolicyTests: XCTestCase {
    func testScreenOffGraceDoesNotMaskDeadAndroidConnections() {
        XCTAssertEqual(SessionLiveness.silenceLimit(screenOff: true, android: false), 300)
        XCTAssertEqual(SessionLiveness.silenceLimit(screenOff: false, android: false), 10)
        XCTAssertEqual(SessionLiveness.silenceLimit(screenOff: true, android: true), 10)
        let args = SlotConfig(id: 1, name: "Test").uxplayArguments
        let index = args.firstIndex(of: "-reset")!
        XCTAssertEqual(args[index + 1], "0")
    }

    func testIntentionalStopRefusesOnlyStoppedDeviceThroughLegacyRetryWindow() {
        let now = Date(timeIntervalSince1970: 100)
        var admission = CastAdmission()
        admission.stop(deviceID: "a", now: now)
        XCTAssertFalse(admission.permits("a", now: now.addingTimeInterval(60)))
        XCTAssertTrue(admission.permits("b", now: now))
        XCTAssertTrue(admission.permits("a", now: now.addingTimeInterval(70)))
    }

    func testNewDeliberateShareIsAllowedImmediately() {
        var admission = CastAdmission()
        admission.stop(deviceID: "a", shareID: "first")
        XCTAssertFalse(admission.permits("a", shareID: "first"))
        XCTAssertTrue(admission.permits("a", shareID: "second"))
    }

    func testStopMessageSurvivesFragmentationAlongsideOtherMessages() throws {
        let reader = CastReader()
        let bytes = CastMessage.stopSharing.encoded() + CastMessage.ping(42).encoded()
        var messages: [CastMessage] = []
        for byte in bytes { messages += try reader.push([byte]) }
        XCTAssertEqual(messages, [.stopSharing, .ping(42)])
    }
}

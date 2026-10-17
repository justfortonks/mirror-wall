import XCTest
@testable import IOSDirectShared

final class OrientationTests: XCTestCase {
    func testHintRoundTripAndStrictBounds() throws {
        for source in [OrientationSource.capture, .device] {
            for degrees: UInt16 in [0, 90, 180, 270] {
                let message = RadioMessage.orientationHint(OrientationHint(degrees: degrees, source: source, monotonicNs: .max))
                let frame = try message.frame()
                XCTAssertEqual(frame.version, 3); XCTAssertEqual(frame.type.rawValue, 20)
                XCTAssertEqual(frame.body.count, 11)
                var parser = RadioParser(), decoded = [RadioMessage]()
                for byte in try frame.encoded() {
                    try parser.feed(Data([byte])) { decoded.append(try RadioMessage($0)) }
                }
                XCTAssertEqual(decoded, [message]); try parser.finish()
                XCTAssertThrowsError(try message.frame(version: 2))
                XCTAssertThrowsError(try RadioMessage(RadioFrame(.orientationHint, frame.body, version: 2)))
                XCTAssertThrowsError(try RadioMessage(RadioFrame(.orientationHint, frame.body + Data([0]))))
                XCTAssertThrowsError(try RadioMessage(RadioFrame(.orientationHint, frame.body.dropLast())))
            }
        }
        for degrees: UInt16 in [1, 89, 360, .max] {
            XCTAssertThrowsError(try RadioMessage.orientationHint(OrientationHint(degrees: degrees, source: .device, monotonicNs: 0)).frame())
            var body = Data(); body.put(degrees); body.put(UInt8(1)); body.put(UInt64(0))
            XCTAssertThrowsError(try RadioMessage(RadioFrame(.orientationHint, body)))
        }
        var body = Data(); body.put(UInt16(90)); body.put(UInt8(2)); body.put(UInt64(0))
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.orientationHint, body)))
    }
    func testManualCycleResetAndAutoDefaultsOff() {
        var state = VideoRotationState()
        XCTAssertFalse(state.automatic)
        for degrees: UInt16 in [90, 180, 270, 0] { state.cycle(); XCTAssertEqual(state.degrees, degrees) }
        state.accept(OrientationHint(degrees: 270, source: .device, monotonicNs: 1))
        XCTAssertEqual(state.degrees, 0)
        state.automatic = true; XCTAssertEqual(state.degrees, 270)
        state.cycle(); XCTAssertEqual(state.degrees, 90); XCTAssertFalse(state.automatic)
        state.reset(); XCTAssertEqual(state.degrees, 0)
        XCTAssertEqual(VideoRotationState(manualDegrees: 180).degrees, 180)
        XCTAssertEqual(VideoRotationState(manualDegrees: 360).degrees, 0)
    }
    func testCapturePreferenceStaleHintsAndSessionReset() {
        var state = VideoRotationState(manualDegrees: 180); state.automatic = true
        XCTAssertEqual(state.degrees, 180); XCTAssertEqual(state.sourceLabel, "manual (awaiting hint)")
        state.accept(OrientationHint(degrees: 90, source: .device, monotonicNs: 10))
        XCTAssertEqual(state.degrees, 90); XCTAssertEqual(state.sourceLabel, "device")
        state.accept(OrientationHint(degrees: 270, source: .capture, monotonicNs: 9))
        state.accept(OrientationHint(degrees: 0, source: .device, monotonicNs: 100))
        XCTAssertEqual(state.degrees, 270); XCTAssertEqual(state.sourceLabel, "capture")
        state.accept(OrientationHint(degrees: 90, source: .capture, monotonicNs: 8))
        state.accept(OrientationHint(degrees: 90, source: .capture, monotonicNs: 9))
        XCTAssertEqual(state.degrees, 270)
        state.accept(OrientationHint(degrees: 0, source: .capture, monotonicNs: 10))
        XCTAssertEqual(state.degrees, 0)
        state.resetHints(); XCTAssertEqual(state.degrees, 180)
        state.accept(OrientationHint(degrees: 90, source: .device, monotonicNs: 1))
        XCTAssertEqual(state.degrees, 90, "new session uses a fresh sender clock")
    }
    func testQuarterTurnsComposeWithExistingCaptureOrientation() {
        for orientation: UInt8 in 1...8 {
            let original = VideoWindowGeometry(width: 588, height: 1280, orientation: orientation)
            for rotation: UInt16 in [0, 90, 180, 270] {
                let turned = VideoWindowGeometry(width: 588, height: 1280, orientation: orientation, rotationDegrees: rotation)
                XCTAssertEqual(turned.aspect, rotation == 90 || rotation == 270 ? 1 / original.aspect : original.aspect, accuracy: 0.00001)
            }
        }
    }
}

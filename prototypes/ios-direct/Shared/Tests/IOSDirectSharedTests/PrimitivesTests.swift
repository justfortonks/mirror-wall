import XCTest
@testable import IOSDirectShared

final class PrimitivesTests: XCTestCase {
    func testFitter() throws {
        XCTAssertEqual(Dimensions.fit(width: 1920, height: 1080), Dimensions(width: 1280, height: 720))
        XCTAssertEqual(Dimensions.fit(width: 1080, height: 1920), Dimensions(width: 720, height: 1280))
        for (w, h) in [(1179, 2556), (2556, 1179), (641, 481), (1001, 1001)] {
            let d = try XCTUnwrap(Dimensions.fit(width: w, height: h))
            XCTAssertEqual(d.width % 2, 0); XCTAssertEqual(d.height % 2, 0)
            XCTAssertLessThanOrEqual(d.width, h > w ? 720 : 1280)
            XCTAssertLessThanOrEqual(d.height, h > w ? 1280 : 720)
            XCTAssertLessThan(abs(Double(d.width) / Double(d.height) - Double(w) / Double(h)), 0.01)
        }
        XCTAssertNil(Dimensions.fit(width: 0, height: 99))
    }
    func testThirtyFPSFromSixty() {
        var pacer = FramePacer()
        let accepted = (0..<120).filter { pacer.accept(pts: Double($0) / 60) }
        XCTAssertEqual(accepted, Array(stride(from: 0, to: 120, by: 2)))
        XCTAssertFalse(pacer.accept(pts: .nan))
        XCTAssertFalse(pacer.accept(pts: 0))
    }
    func testEncoderBackoff() {
        var backoff = EncoderBackoff()
        XCTAssertTrue(backoff.canAttempt(now: 10))
        var now = 10.0
        for delay in [0.25, 0.5, 1.0, 2.0, 2.0, 2.0] {
            XCTAssertEqual(backoff.failed(now: now), delay)
            XCTAssertFalse(backoff.canAttempt(now: now + delay - 0.001))
            now += delay
            XCTAssertTrue(backoff.canAttempt(now: now))
        }
        backoff.reset()
        XCTAssertTrue(backoff.canAttempt(now: now))
        XCTAssertEqual(backoff.failed(now: now), 0.25)
    }
    func testByteLimitAndDrops() {
        var q = BoundedQueue<Int>(maxBytes: 10, maxAge: 0.1)
        XCTAssertTrue(q.enqueue(1, bytes: 6, now: 0))
        XCTAssertFalse(q.enqueue(2, bytes: 5, now: 0.01))
        XCTAssertEqual(q.bytes, 6); XCTAssertEqual(q.drops, 1)
        XCTAssertEqual(q.dequeue(now: 0.02), 1); XCTAssertEqual(q.bytes, 0)
        XCTAssertFalse(q.enqueue(3, bytes: 11, now: 0.03))
        XCTAssertEqual(q.drops, 2)
    }
    func testAgeLimitAtAdmissionAndDrain() {
        var q = BoundedQueue<Int>(maxBytes: 10, maxAge: 0.1)
        q.enqueue(1, bytes: 6, now: 0)
        XCTAssertTrue(q.enqueue(2, bytes: 6, now: 0.1))
        XCTAssertEqual(q.drops, 1); XCTAssertEqual(q.age(now: 0.15), 0.05, accuracy: 0.00001)
        XCTAssertNil(q.dequeue(now: 0.21))
        XCTAssertEqual(q.drops, 2); XCTAssertEqual(q.bytes, 0)
    }
    func testMetricsJSONLine() throws {
        var m = MetricsSnapshot(); m.monotonicTime = 12.5; m.encodeCompleted = 30
        m.dimensions = Dimensions(width: 720, height: 1280)
        m.encoderState = "unavailable: -12903"; m.encoderLastFailingOSStatus = -12903
        m.encoderRecreateAttempts = 4; m.encoderRecreateSuccesses = 2; m.encoderNoSessionDrops = 60
        m.hardwareEncoder = "unknown (not supported)"
        let data = try m.jsonLine()
        XCTAssertEqual(data.last, 10); XCTAssertEqual(data.filter { $0 == 10 }.count, 1)
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: data)
        XCTAssertEqual(decoded.encodeCompleted, 30); XCTAssertEqual(decoded.dimensions, m.dimensions)
        XCTAssertEqual(decoded.encoderState, m.encoderState)
        XCTAssertEqual(decoded.encoderLastFailingOSStatus, -12903)
        XCTAssertEqual(decoded.encoderRecreateAttempts, 4); XCTAssertEqual(decoded.encoderRecreateSuccesses, 2)
        XCTAssertEqual(decoded.encoderNoSessionDrops, 60)
        XCTAssertEqual(decoded.hardwareEncoder, "unknown (not supported)")
        let event = Event(monotonicTime: 1, wallTime: "now", name: "error", details: "line\nquote\"")
        let eventData = try JSONLine.encode(event)
        XCTAssertEqual(eventData.filter { $0 == 10 }.count, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: eventData))
    }
}

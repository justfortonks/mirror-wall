import XCTest
@testable import IOSDirectShared

final class PrimitivesTests: XCTestCase {
    func testPresetOutputForBothPhonesAndLandscape() throws {
        // Phone B: g4-run1 phoneB stream.startRequested: 390x844 points at 3x.
        for (source, expected) in [
            (Dimensions(width: 1320, height: 2868), [Dimensions(width: 588, height: 1280), Dimensions(width: 1080, height: 2346), Dimensions(width: 1320, height: 2868)]),
            (Dimensions(width: 1170, height: 2532), [Dimensions(width: 590, height: 1280), Dimensions(width: 1080, height: 2336), Dimensions(width: 1170, height: 2532)])
        ] {
            for (preset, output) in zip(StreamPreset.allCases, expected) {
                XCTAssertEqual(preset.output(width: source.width, height: source.height), output)
                XCTAssertEqual(preset.output(width: source.height, height: source.width), Dimensions(width: output.height, height: output.width))
            }
        }
        XCTAssertEqual(StreamPreset.native.output(width: 1171, height: 2533), Dimensions(width: 1170, height: 2532))
        XCTAssertEqual(StreamPreset.high.output(width: 100, height: 200), Dimensions(width: 100, height: 200), "never upscale")
        XCTAssertNil(StreamPreset.native.output(width: 0, height: 2532))
    }
    func testPresetRatesFPSAndLatencyWindows() {
        XCTAssertEqual(StreamSettings(), StreamSettings(preset: .standard, sixtyFPS: false))
        for (preset, bitrate, window) in [(StreamPreset.standard, 6_000_000, 75_000), (.high, 12_000_000, 150_000), (.native, 20_000_000, 150_000)] {
            for sixty in [false, true] {
                let settings = StreamSettings(preset: preset, sixtyFPS: sixty)
                XCTAssertEqual(settings.targetBitrate, bitrate); XCTAssertEqual(settings.latencyWindowBytes, window)
                XCTAssertEqual(settings.fps, sixty ? 60 : 30)
            }
        }
    }
    func testSixtyFPSFromSixtyAndOneTwenty() {
        for inputFPS in [60, 120] {
            var pacer = FramePacer(fps: 60)
            let accepted = (0..<inputFPS * 10).filter { pacer.accept(pts: Double($0) / Double(inputFPS)) }
            XCTAssertEqual(accepted.count, 600)
        }
    }
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
    func testThirtyFPSFromThirtySixWithDeadlineGrid() {
        var pacer = FramePacer()
        let accepted = (0..<360).filter { pacer.accept(pts: Double($0) / 36) }.count
        let rate = Double(accepted) / 10
        XCTAssertGreaterThanOrEqual(rate, 29)
        XCTAssertLessThanOrEqual(rate, 30)
    }
    func testThirtyFPSFromSixtyWithRandomJitter() {
        var pacer = FramePacer()
        let accepted = jitteredTimestamps(fps: 60, duration: 10, seed: 0x51A7)
            .filter { pacer.accept(pts: $0) }.count
        let rate = Double(accepted) / 10
        XCTAssertGreaterThanOrEqual(rate, 29)
        XCTAssertLessThanOrEqual(rate, 30)
    }
    func testThirtyFPSInputWithRandomJitterIsNotHalved() {
        var pacer = FramePacer()
        let accepted = jitteredTimestamps(fps: 30, duration: 10, seed: 0x30A7)
            .filter { pacer.accept(pts: $0) }.count
        XCTAssertGreaterThanOrEqual(Double(accepted) / 10, 28.5)
    }
    func testTwentyFourFPSInputAcceptsEveryFrame() {
        var pacer = FramePacer()
        let timestamps = (0..<240).map { Double($0) / 24 }
        let accepted = timestamps.filter { pacer.accept(pts: $0) }
        XCTAssertEqual(accepted.count, timestamps.count)
    }
    func testLongGapDoesNotCauseCatchUpBurst() {
        var pacer = FramePacer()
        for index in 0..<30 {
            _ = pacer.accept(pts: Double(index) / 60)
        }

        let gapEnd = 2.5
        var acceptedAfterGap: [Double] = []
        for index in 0..<6 {
            let pts = gapEnd + Double(index) / 60
            if pacer.accept(pts: pts) { acceptedAfterGap.append(pts) }
        }
        let acceptedWithin40msAfterGap = acceptedAfterGap.filter {
            $0 > gapEnd && $0 <= gapEnd + 0.040
        }
        XCTAssertLessThanOrEqual(acceptedWithin40msAfterGap.count, 2)
    }
    func testNonFinitePresentationTimestampsAreRejected() {
        var pacer = FramePacer()
        XCTAssertFalse(pacer.accept(pts: .nan))
        XCTAssertFalse(pacer.accept(pts: .infinity))
        XCTAssertFalse(pacer.accept(pts: -.infinity))
        XCTAssertTrue(pacer.accept(pts: 0))
    }

    private func jitteredTimestamps(fps: Double, duration: Double, seed: UInt64) -> [Double] {
        var state = seed
        return (0..<Int(fps * duration)).map { index in
            state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            let jitter = (unit * 2 - 1) * 0.003
            return Double(index) / fps + jitter
        }
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

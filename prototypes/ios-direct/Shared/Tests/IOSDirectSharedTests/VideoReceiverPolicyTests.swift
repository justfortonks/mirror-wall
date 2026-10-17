import XCTest
@testable import IOSDirectShared

final class VideoReceiverPolicyTests: XCTestCase {
    func testSixFrameBurstDecodesEveryReferenceButDisplaysNewestOnce() {
        var decode = VideoDecodeQueuePolicy(), display = VideoPresentationQueue<UInt64>()
        var recoveries = 0, decoded = 0, skipped = 0
        for seq in UInt64(0)..<6 {
            switch decode.admit(seq: seq, keyframe: seq == 0, now: 1) {
            case .decode: break
            case .recover: recoveries += 1
            case .waitForKeyframe: XCTFail("reference was skipped")
            }
        }
        XCTAssertEqual(decode.depth, 6)
        for seq in UInt64(0)..<6 {
            decode.complete(seq: seq); decoded += 1
            skipped += display.offer(seq, seq: seq, ptsNs: seq * 33_333_333, arrival: 1, now: 1.01)
        }
        let ready = display.takeReady(now: 1.011); skipped += ready.skipped
        XCTAssertEqual(decoded, 6); XCTAssertEqual(recoveries, 0)
        XCTAssertEqual(ready.value, 5); XCTAssertEqual(skipped, 5)
        XCTAssertNil(display.takeReady(now: 1.012).value)
        XCTAssertEqual(decode.samplePeakDepth(), 6, "retain peak after decode drains")
        XCTAssertEqual(decode.samplePeakDepth(), 0, "next metrics interval starts fresh")
    }
    func testNinthFrameTriggersOneRecoveryUntilNextKeyframe() {
        var decode = VideoDecodeQueuePolicy(), requests = 0
        for seq in UInt64(0)..<8 {
            XCTAssertEqual(decode.admit(seq: seq, keyframe: seq == 0, now: 0), .decode)
        }
        XCTAssertEqual(decode.depth, 8)
        if case .recover("decode queue count") = decode.admit(seq: 8, keyframe: false, now: 0.01) { requests += 1 }
        else { XCTFail("ninth frame must bound the queue") }
        for seq in UInt64(9)..<20 {
            XCTAssertEqual(decode.admit(seq: seq, keyframe: false, now: 0.02), .waitForKeyframe)
        }
        XCTAssertNil(decode.expire(now: 1)); XCTAssertEqual(requests, 1)
        XCTAssertEqual(decode.samplePeakDepth(), 8)
        XCTAssertEqual(decode.admit(seq: 20, keyframe: true, now: 1), .decode)
        XCTAssertEqual(decode.admit(seq: 21, keyframe: false, now: 1.01), .decode)
    }
    func testThreeHundredMillisecondBoundAndOnlyUnfinishedFramesExpire() {
        var decode = VideoDecodeQueuePolicy()
        XCTAssertEqual(decode.admit(seq: 0, keyframe: true, now: 10), .decode)
        XCTAssertEqual(decode.admit(seq: 1, keyframe: false, now: 10.1), .decode)
        decode.complete(seq: 0)
        XCTAssertNil(decode.expire(now: 10.301), "completed oldest frame must not expire a newer one")
        XCTAssertEqual(decode.expire(now: 10.401), "decode queue age")
        XCTAssertNil(decode.expire(now: 11), "no repeated recovery while awaiting an IDR")
        XCTAssertEqual(decode.admit(seq: 2, keyframe: false, now: 11), .waitForKeyframe)
    }
    func testIdenticalConfigSurvivesDecoderResetWithoutAnotherConfigChange() throws {
        var configuration = VideoConfigurationState(), decode = VideoDecodeQueuePolicy()
        var resets = 0, configEvents = 0
        for _ in 0..<3 {
            if try configuration.update(VideoTests.config) == .changed {
                resets += 1; configEvents += 1
            }
            decode.reset() // Model a decoder invalidation without changing its format.
            XCTAssertEqual(try configuration.update(VideoTests.config), .identical)
        }
        XCTAssertEqual(resets, 1); XCTAssertEqual(configEvents, 1)
        XCTAssertEqual(try configuration.update(VideoTests.config.withGeneration(8)), .changed)
        XCTAssertThrowsError(try configuration.update(VideoTests.config))
    }
    func testSmoothingDefaultsOffAndUsesPtsBufferWithoutErrorRecovery() {
        var display = VideoPresentationQueue<Int>()
        XCTAssertFalse(display.smooth)
        XCTAssertEqual(display.setSmoothing(true), 0)
        XCTAssertEqual(display.offer(1, seq: 1, ptsNs: 1_000_000_000, arrival: 5, now: 5), 0)
        XCTAssertNil(display.takeReady(now: 5.099).value)
        XCTAssertEqual(display.takeReady(now: 5.101).value, 1)
        _ = display.offer(2, seq: 2, ptsNs: 1_033_333_333, arrival: 5.033, now: 5.033)
        XCTAssertNil(display.takeReady(now: 5.1).value)
        XCTAssertEqual(display.takeReady(now: 5.134).value, 2)
        _ = display.offer(3, seq: 3, ptsNs: 1_066_666_666, arrival: 5.066, now: 5.066)
        XCTAssertEqual(display.setSmoothing(false), 1)
        _ = display.offer(4, seq: 4, ptsNs: 1_099_999_999, arrival: 5.1, now: 5.1)
        XCTAssertEqual(display.takeReady(now: 5.1).value, 4)
        XCTAssertEqual(display.offer(3, seq: 3, ptsNs: 0, arrival: 5.2, now: 5.2), 1, "late output cannot replace a newer picture")
    }
    func testSmoothingCoalescesOverdueBurstAndBoundsDecodedBuffers() {
        var display = VideoPresentationQueue<Int>(), skipped = 0
        display.setSmoothing(true)
        for index in 0..<12 {
            skipped += display.offer(index, seq: UInt64(index), ptsNs: UInt64(index) * 33_333_333, arrival: 1, now: 1)
            XCTAssertLessThanOrEqual(display.count, 8)
        }
        let ready = display.takeReady(now: 2)
        XCTAssertEqual(ready.value, 11); XCTAssertEqual(skipped + ready.skipped, 11)
    }
    func testPlayoutClockResetsDiscontinuitiesAndOffsetsDoNotMatter() {
        var clock = VideoPlayoutClock()
        XCTAssertEqual(clock.due(ptsNs: 500_000_000_000, arrival: 2), 2.1, accuracy: 0.0001)
        XCTAssertEqual(clock.due(ptsNs: 500_033_333_333, arrival: 2.04), 2.133333333, accuracy: 0.0001)
        let before = clock.due(ptsNs: 1, arrival: 3)
        XCTAssertEqual(before, 3.1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(clock.due(ptsNs: 10_000_000_000, arrival: 4), before)
    }
    func testWindowAspectSwapsOnQuarterTurnsAndIgnoresConfigGeneration() {
        let portrait = VideoWindowGeometry(width: 588, height: 1280, orientation: 1)
        let landscape = VideoWindowGeometry(width: 588, height: 1280, orientation: 6)
        XCTAssertLessThan(portrait.aspect, 1); XCTAssertGreaterThan(landscape.aspect, 1)
        XCTAssertEqual(portrait.aspect * landscape.aspect, 1, accuracy: 0.00001)
        XCTAssertEqual(landscape.aspect, VideoWindowGeometry(width: 588, height: 1280, orientation: 8).aspect)
        XCTAssertEqual(landscape, VideoWindowGeometry(width: 588, height: 1280, orientation: 6))
    }
    func testDisplayedFPSIncludesPartialFinalSecond() {
        var rate = VideoFrameRate(now: 10)
        XCTAssertEqual(rate.sample(total: 30, now: 11), 30)
        XCTAssertEqual(rate.sample(total: 45, now: 11.5), 30, "session-close interval uses its actual duration")
        XCTAssertEqual(rate.sample(total: 45, now: 12), 0)
        XCTAssertEqual(rate.sample(total: 45, now: 12), 0)
    }
}

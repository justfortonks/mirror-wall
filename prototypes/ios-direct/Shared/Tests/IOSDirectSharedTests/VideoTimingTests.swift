import XCTest
@testable import IOSDirectShared

final class VideoTimingTests: XCTestCase {
    func testSteadyThirtyFPSReceiveDecodeAndScheduledPresentation() throws {
        var decode = VideoDecodeQueuePolicy(), pictures = VideoPresentationQueue<UInt64>()
        var rate = VideoFrameRate(now: 0), diagnostics = VideoStageDiagnostics()
        var displayed = 0, skipped = 0
        // Synthetic receiver times: 30 fps with 2 ms of decode work, ten seconds.
        // Use the renderer's admission, completion, scheduler and display policies.
        for seq in UInt64(0)..<300 {
            let arrival = Double(seq) / 30, submitted = arrival + 0.0002, completed = submitted + 0.002
            diagnostics.arrived(at: arrival)
            XCTAssertNil(decode.expire(now: arrival))
            XCTAssertEqual(decode.admit(seq: seq, keyframe: seq % 30 == 0, now: arrival), .decode)
            diagnostics.submitted(arrival: arrival, at: submitted)
            decode.complete(seq: seq); diagnostics.completed(submitted: submitted, at: completed)
            skipped += pictures.offer(seq, seq: seq, ptsNs: seq * 33_333_333, arrival: arrival, now: completed)
            let wake = try XCTUnwrap(VideoServiceSchedule.next(now: completed, decodeDeadline: decode.deadline, pictureDue: pictures.nextDue))
            XCTAssertEqual(wake, completed, "immediate output must not wait for a timer")
            let ready = pictures.takeReady(now: wake); skipped += ready.skipped
            XCTAssertEqual(ready.value, seq); displayed += ready.value == nil ? 0 : 1
            diagnostics.enqueued(completed: completed, at: wake)
            if seq % 30 == 29 { XCTAssertEqual(rate.sample(total: displayed, now: Double(seq + 1) / 30), 30, accuracy: 0.0001) }
        }
        XCTAssertEqual(displayed, 300); XCTAssertEqual(skipped, 0)
        let timing = diagnostics.snapshot(now: 10)
        XCTAssertEqual(try XCTUnwrap(timing.interArrival.p95MS), 1000 / 30, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timing.arrivalToSubmit.p50MS), 0.2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timing.decode.p95MS), 2, accuracy: 0.00001)
        XCTAssertEqual(timing.completeToEnqueue.p95MS, 0)
    }
    func testLastSecondQuantilesForgetOldBurstAndEmptyWhenIdle() throws {
        var window = VideoTimingWindow()
        for index in 0..<30 { window.add(milliseconds: index == 29 ? 280 : 0.1, at: Double(index) / 30) }
        XCTAssertEqual(window.summary(now: 1).maxMS, 280)
        for index in 0..<30 { window.add(milliseconds: 33.333, at: 1.02 + Double(index) / 30) }
        let clean = window.summary(now: 2.01)
        XCTAssertEqual(clean.count, 30)
        XCTAssertEqual(try XCTUnwrap(clean.p50MS), 33.333, accuracy: 0.00001)
        XCTAssertEqual(clean.p95MS, clean.p50MS); XCTAssertEqual(clean.maxMS, clean.p50MS)
        XCTAssertNil(window.summary(now: 3.1).p95MS)
        XCTAssertEqual(window.summary(now: 3.1).count, 0)
    }
    func testWorkerBacklogIsChargedToArrivalSubmitAndCompleteEnqueue() throws {
        var diagnostics = VideoStageDiagnostics()
        diagnostics.arrived(at: 10); diagnostics.arrived(at: 10.03)
        diagnostics.submitted(arrival: 10, at: 10.01)
        diagnostics.completed(submitted: 10.01, at: 10.012)
        diagnostics.enqueued(completed: 10.012, at: 10.04)
        let result = diagnostics.snapshot(now: 10.1)
        XCTAssertEqual(try XCTUnwrap(result.arrivalToSubmit.p95MS), 10, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(result.decode.p95MS), 2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(result.completeToEnqueue.p95MS), 28, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(result.interArrival.p95MS), 30, accuracy: 0.00001)
    }
    func testUIStatisticsPublishAtMostTwicePerSecond() {
        var gate = VideoPublicationGate(), times: [Double] = []
        for index in 0..<300 {
            let now = Double(index) / 100
            if gate.delay(now: now) == 0 { times.append(now) }
        }
        XCTAssertEqual(times.count, 6)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.5) }
    }
}

import XCTest
@testable import IOSDirectShared

final class VideoTests: XCTestCase {
    static let config = VideoConfig(generation: 7, width: 588, height: 1280, orientation: 1,
        contentRect: VideoRect(x: 0, y: 0, width: 588, height: 1280),
        avcC: Data([1, 100, 0, 40, 255, 225, 0, 4, 0x67, 100, 0, 40, 1, 0, 2, 0x68, 0]))
    private func unit(_ seq: UInt64 = 0, key: Bool = true, bytes: Int = 140_000) -> VideoAccessUnit {
        VideoAccessUnit(generation: 7, seq: seq, ptsNs: 123_456 + seq, keyframe: key,
                        data: SyntheticPayload.make(seq: seq, count: bytes))
    }
    func testLegacyHelloDecodeAndV3VideoControls() throws {
        let messages: [RadioMessage] = [
            .hello(install: UUID(), label: "G2", version: 1, rate: 12),
            .hello(install: UUID(), label: "G3a", version: 2, rate: 6, mode: .video),
            .hello(install: UUID(), label: "v2 synthetic", version: 2, rate: 12),
            .videoConfig(Self.config), .keyframeRequest("fragment gap"), .videoAck(seq: 42, ptsNs: 123, status: .decodeError)
        ]
        for message in messages {
            let frame = try message.frame(), wire = try frame.encoded()
            var parser = RadioParser(), decoded = [RadioMessage]()
            for byte in wire { try parser.feed(Data([byte])) { decoded.append(try RadioMessage($0)) } }
            try parser.finish(); XCTAssertEqual(decoded, [message])
        }
        XCTAssertEqual(try messages[0].frame().version, 1)
        XCTAssertEqual(try messages[1].frame().version, 2)
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.keyframeRequest, Data([0, 0]), version: 1)))
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.hello, messages[1].frame().body)))
    }
    func testSplitJoinRoundTripAndLimit() throws {
        for bytes in [1, VideoFragment.maxData, VideoFragment.maxData + 1, VideoFragment.maxFrame] {
            let frame = unit(bytes: bytes); var assembler = VideoReassembler(), events = [VideoAssemblyEvent]()
            for fragment in try frame.fragments() {
                let message = try RadioMessage(RadioMessage.videoFragment(fragment).frame())
                guard case .videoFragment(let decoded) = message else { return XCTFail() }
                events += try assembler.accept(decoded, now: 1)
                XCTAssertLessThanOrEqual(assembler.bufferedBytes, VideoFragment.maxFrame)
                XCTAssertLessThanOrEqual(assembler.framesInProgress, 1)
            }
            XCTAssertEqual(events, [.frame(frame)]); XCTAssertEqual(assembler.bufferedBytes, 0)
        }
    }
    func testOversizeTotalRejectedBeforeAllocation() throws {
        let fragment = VideoFragment(generation: 1, seq: 0, ptsNs: 0, keyframe: true,
            index: 0, count: 17, total: UInt32(VideoFragment.maxFrame + 1), data: Data([1]))
        var assembler = VideoReassembler()
        XCTAssertThrowsError(try assembler.accept(fragment, now: 0))
        XCTAssertEqual(assembler.bufferedBytes, 0); XCTAssertEqual(assembler.framesInProgress, 0)
        var body = Data(); body.put(UInt32(1)); body.put(UInt64(0)); body.put(UInt64(0)); body.put(UInt8(1))
        body.put(UInt16(0)); body.put(UInt16(17)); body.put(UInt32(VideoFragment.maxFrame + 1)); body.append(1)
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.videoFragment, body, version: 2)))
    }
    func testOutOfOrderMissingAndOneFrameInProgress() throws {
        let a = unit(), fragments = try a.fragments(), b = unit(1)
        var assembler = VideoReassembler()
        XCTAssertTrue(try assembler.accept(fragments[0], now: 0).isEmpty)
        let outOfOrder = try assembler.accept(fragments[2], now: 0.01)
        XCTAssertEqual(outOfOrder, [.dropped(seq: a.seq, ptsNs: a.ptsNs, reason: "out-of-order / inconsistent fragment")])
        XCTAssertEqual(assembler.framesInProgress, 0)
        XCTAssertTrue(try assembler.accept(fragments[1], now: 0.02).isEmpty, "remaining fragments do not double ACK")
        assembler.reset()
        _ = try assembler.accept(fragments[0], now: 1)
        let replaced = try assembler.accept(b.fragments()[0], now: 1.01)
        XCTAssertEqual(replaced, [.dropped(seq: a.seq, ptsNs: a.ptsNs, reason: "missing fragment / replaced frame")])
        XCTAssertEqual(assembler.framesInProgress, 1)
        XCTAssertEqual(assembler.bufferedBytes, VideoFragment.maxData)
        XCTAssertEqual(assembler.expire(now: 2.02), [.dropped(seq: b.seq, ptsNs: b.ptsNs, reason: "fragment timeout")])
        XCTAssertEqual(assembler.framesInProgress, 0)
        XCTAssertEqual(try assembler.accept(fragments[1], now: 3), [], "old sequence cannot reopen a partial frame")
        assembler.reset()
        XCTAssertEqual(try assembler.accept(fragments[1], now: 4), [.dropped(seq: a.seq, ptsNs: a.ptsNs, reason: "missing first fragment")])
    }
    func testConfigRequiresFourByteNALAndParameterSets() throws {
        XCTAssertEqual(try Self.config.parameterSets().count, 2)
        var avcC = Self.config.avcC; avcC[4] = 254
        let bad = VideoConfig(generation: 1, width: 588, height: 1280, orientation: 1, avcC: avcC)
        XCTAssertThrowsError(try bad.parameterSets()); XCTAssertThrowsError(try RadioMessage.videoConfig(bad).frame())
    }
    func testOverflowAndExpiryResumeOnlyOnKeyframe() {
        var queue = VideoSendQueue()
        XCTAssertFalse(queue.offer(unit(0, key: false, bytes: 10), now: 0))
        XCTAssertTrue(queue.offer(unit(1, bytes: 600_000), now: 0))
        XCTAssertTrue(queue.offer(unit(2, key: false, bytes: 400_000), now: 0.01))
        XCTAssertFalse(queue.offer(unit(3, key: false, bytes: 100_000), now: 0.02))
        XCTAssertEqual(queue.bytes, 0); XCTAssertTrue(queue.waitingForKeyframe)
        XCTAssertFalse(queue.offer(unit(4, key: false, bytes: 10), now: 0.03))
        XCTAssertNil(queue.pop(now: 0.04))
        XCTAssertTrue(queue.offer(unit(5, bytes: 10), now: 0.05))
        XCTAssertEqual(queue.pop(now: 0.06)?.seq, 5, "first sent frame after overflow is an IDR")
        XCTAssertTrue(queue.offer(unit(6, key: false, bytes: 10), now: 1))
        XCTAssertNil(queue.pop(now: 1.101)); XCTAssertTrue(queue.waitingForKeyframe)
        XCTAssertFalse(queue.offer(unit(7, key: false, bytes: 10), now: 1.11))
        XCTAssertTrue(queue.offer(unit(8, bytes: 10), now: 1.12))
        XCTAssertTrue(queue.pop(now: 1.13)?.keyframe == true)
        XCTAssertGreaterThan(queue.drops["queueBytes", default: 0], 0)
        XCTAssertGreaterThan(queue.drops["queueAge", default: 0], 0)
    }
}

import XCTest
import CryptoKit
@testable import IOSDirectShared

final class RadioTests: XCTestCase {
    func testPartialCoalescedAndFragmentedFrames() throws {
        let frames = [try RadioMessage.ping(42).frame(), RadioFrame(.stats, Data("{}".utf8)), RadioFrame(.bye)]
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        for split in 0...bytes.count {
            var parser = RadioParser(), result = [RadioFrame]()
            try parser.feed(Data(bytes.prefix(split))) { result.append($0) }
            try parser.feed(Data(bytes.dropFirst(split))) { result.append($0) }
            try parser.finish(); XCTAssertEqual(result, frames)
        }
        var parser = RadioParser(), result = [RadioFrame]()
        for byte in bytes { try parser.feed(Data([byte])) { result.append($0) } }
        XCTAssertEqual(result, frames); XCTAssertEqual(parser.bufferedBytes, 0)
    }
    func testParserRejectsHeaderBeforeBodyAllocation() throws {
        let valid = try RadioMessage.ping(5).frame().encoded()
        for (offset, byte, reason) in [(0, UInt8(0), "bad magic"), (4, 2, "bad version"), (5, 255, "unknown type")] {
            var invalid = valid; invalid[offset] = byte
            var parser = RadioParser()
            XCTAssertThrowsError(try parser.feed(invalid) { _ in XCTFail("invalid frame delivered") }) {
                XCTAssertEqual($0 as? RadioError, .protocolViolation(reason))
            }
            XCTAssertLessThanOrEqual(parser.bufferedBytes, 10)
        }
        var oversized = Data("MWPD".utf8); oversized.append(contentsOf: [1, 4]); oversized.put(UInt32(65_537))
        oversized.append(Data(repeating: 0, count: 100_000))
        var parser = RadioParser()
        XCTAssertThrowsError(try parser.feed(oversized) { _ in XCTFail() }) {
            XCTAssertEqual($0 as? RadioError, .protocolViolation("oversize length"))
        }
        XCTAssertEqual(parser.bufferedBytes, 10)
        XCTAssertThrowsError(try parser.feed(valid) { _ in XCTFail() })
    }
    func testMaximumBodyIsAcceptedWithoutGrowingBeyondOneFrame() throws {
        let frame = RadioFrame(.data, Data(repeating: 42, count: RadioFrame.maxBody))
        let bytes = try frame.encoded()
        var parser = RadioParser(), count = 0
        for offset in stride(from: 0, to: bytes.count, by: 997) {
            try parser.feed(Data(bytes[offset..<min(bytes.count, offset + 997)])) {
                XCTAssertEqual($0, frame); count += 1
            }
            XCTAssertLessThanOrEqual(parser.bufferedBytes, 10 + RadioFrame.maxBody)
        }
        try parser.finish(); XCTAssertEqual(count, 1)
    }
    func testEOFMidHeaderAndBody() throws {
        let bytes = try RadioMessage.ping(42).frame().encoded()
        for count in 1..<bytes.count {
            var parser = RadioParser()
            try parser.feed(Data(bytes.prefix(count))) { _ in XCTFail() }
            XCTAssertThrowsError(try parser.finish())
        }
        var empty = RadioParser(); XCTAssertNoThrow(try empty.finish())
    }
    func testMessageRoundTripsAndBounds() throws {
        let data = SyntheticPayload.make(seq: 7, count: RadioFrame.maxData)
        let messages: [RadioMessage] = [
            .hello(install: UUID(), label: "same phone 🧪", version: 1, rate: 12),
            .welcome(session: UUID(), label: "Mac"), .reject("capacity"),
            .data(seq: 7, time: 123, payload: data, crc: RadioCRC32.checksum(data)),
            .ack(seq: 7, time: 123, total: 65_516), .ping(88), .pong(88), .stats(Data("{}".utf8)), .bye("stop")]
        for message in messages { XCTAssertEqual(try RadioMessage(message.frame()), message) }
        XCTAssertThrowsError(try RadioMessage.data(seq: 0, time: 0,
            payload: Data(count: RadioFrame.maxData + 1), crc: 0).frame())
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.ack, Data(count: 23))))
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.ping, Data(count: 9))))
        XCTAssertThrowsError(try RadioMessage(RadioFrame(.stats, Data("no JSON".utf8))))
        XCTAssertEqual(RadioCRC32.checksum(Data("123456789".utf8)), 0xcbf43926)
    }
    func testCodeParsingAndPSKDeterminism() throws {
        let raw = Data(0..<10), code = try RadioCode(bytes: raw)
        XCTAssertEqual(code.formatted, "000G-40R4-0M30-E209")
        XCTAssertEqual(try RadioCode(code.formatted.lowercased().replacingOccurrences(of: "-", with: " ")).bytes, raw)
        XCTAssertEqual(try RadioCode("OOOO OOOO OOOO OOOO").bytes, Data(count: 10))
        for invalid in ["", "123", "00000000000000000", "000000000000000U", "é000000000000000"] {
            XCTAssertThrowsError(try RadioCode(invalid))
        }
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw),
            salt: Data("mwiospoc-g2-psk-v1".utf8), info: Data(), outputByteCount: 32).withUnsafeBytes { Data($0) }
        XCTAssertEqual(code.psk.map { String(format: "%02x", $0) }.joined(), "cc725e06379b807f0693c112c4b1bd58d8e24d2bf8b6a9ec7351b9427d602ef8")
        XCTAssertEqual(code.psk, expected); XCTAssertEqual(code.psk.count, 32)
        XCTAssertEqual(try RadioCode(code.formatted).psk, code.psk)
        XCTAssertNotEqual(try RadioCode(bytes: Data(repeating: 1, count: 10)).psk, code.psk)
        let random = try RadioCode.generate(); XCTAssertEqual(try RadioCode(random.formatted).bytes, random.bytes)
    }
    func testRatePacerNoCatchupAndOutstandingLimit() {
        for rate in [2, 6, 12, 24] {
            var p = RadioPacer(mbit: rate)
            XCTAssertEqual(p.cap, min(150_000, rate * 12_500))
            XCTAssertTrue(p.canSend(now: 1, outstanding: 0, sending: false))
            p.sent(now: 1, payloadBytes: p.chunk)
            XCTAssertFalse(p.canSend(now: 1.00001, outstanding: 0, sending: false))
            XCTAssertTrue(p.canSend(now: 5, outstanding: 0, sending: false))
            p.sent(now: 5, payloadBytes: p.chunk)
            XCTAssertFalse(p.canSend(now: 5.00001, outstanding: 0, sending: false))
            XCTAssertFalse(p.canSend(now: 6, outstanding: p.cap, sending: false))
            XCTAssertFalse(p.canSend(now: 6.25, outstanding: p.cap, sending: false))
            XCTAssertEqual(p.blockedMS(now: 6.25), 250, accuracy: 0.001)
            XCTAssertTrue(p.canSend(now: 6.5, outstanding: 0, sending: false))
            XCTAssertEqual(p.blockedMS(now: 7), 500, accuracy: 0.001)
        }
    }
    func testBlockedTimeStartsAtPacingDeadlineEvenWithoutPolling() {
        var pacer = RadioPacer(mbit: 2)
        pacer.sent(now: 1, payloadBytes: pacer.chunk)
        let due = 1 + Double(pacer.chunk) / pacer.bytesPerSecond
        XCTAssertFalse(pacer.canSend(now: 1.001, outstanding: pacer.cap, sending: false))
        XCTAssertEqual(pacer.blockedMS(now: 1.002), 0)
        XCTAssertTrue(pacer.canSend(now: due + 0.2, outstanding: 0, sending: false))
        XCTAssertEqual(pacer.blockedMS(now: due + 1), 200, accuracy: 0.001)
    }
    func testRTTWindow() {
        var rtt = RadioRTT()
        for n in 1...20 { rtt.add(milliseconds: Double(n), now: 1) }
        let values = rtt.values(now: 2)
        XCTAssertEqual(values.0, 10.5); XCTAssertEqual(values.1, 19)
        XCTAssertNil(rtt.values(now: 12).0)
    }
}

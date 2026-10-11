import XCTest
@testable import MirrorCore

final class RTPPacketTests: XCTestCase {
    func testParsesHeaderAndPayload() throws {
        let packet = RTPPacket(payloadType: 96, marker: true, sequenceNumber: 0xBEEF, timestamp: 0x0102_0304, ssrc: 0xCAFE_F00D, payload: [0x65, 1, 2])
        let parsed = try XCTUnwrap(RTPPacket(packet.bytes))
        XCTAssertEqual(parsed, packet)
    }

    func testSkipsCSRCsExtensionAndPadding() throws {
        var bytes: [UInt8] = [0x80 | 0x20 | 0x10 | 0x01, 96, 0, 1, 0, 0, 0, 9, 0, 0, 0, 7]
        bytes += [1, 2, 3, 4]                // one CSRC
        bytes += [0xBE, 0xDE, 0, 1, 9, 9, 9, 9] // header extension, one word
        bytes += [0x41, 0xAA]                // payload
        bytes += [0, 0, 3]                   // three bytes of padding
        let parsed = try XCTUnwrap(RTPPacket(bytes))
        XCTAssertEqual(parsed.payload, [0x41, 0xAA])
        XCTAssertEqual(parsed.timestamp, 9)
    }

    func testRejectsGarbage() {
        XCTAssertNil(RTPPacket([0x80, 96, 0]))
        XCTAssertNil(RTPPacket([UInt8](repeating: 0, count: 20))) // version 0
    }
}

final class H264DepacketizerTests: XCTestCase {
    private func packet(_ seq: UInt16, ts: UInt32, marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        RTPPacket(marker: marker, sequenceNumber: seq, timestamp: ts, payload: payload)
    }

    func testSingleNALUnits() {
        let d = H264Depacketizer()
        XCTAssertEqual(d.push(packet(1, ts: 100, marker: false, [0x67, 1])), [])
        XCTAssertEqual(d.push(packet(2, ts: 100, marker: false, [0x68, 2])), [])
        let frames = d.push(packet(3, ts: 100, marker: true, [0x65, 3]))
        XCTAssertEqual(frames, [H264Frame(nalUnits: [[0x67, 1], [0x68, 2], [0x65, 3]], timestamp: 100)])
        XCTAssertTrue(frames[0].isKeyframe)
    }

    func testSTAPA() {
        let d = H264Depacketizer()
        let stap: [UInt8] = [0x78, 0, 2, 0x67, 1, 0, 3, 0x68, 2, 3]
        let frames = d.push(packet(1, ts: 5, marker: true, stap))
        XCTAssertEqual(frames.first?.nalUnits, [[0x67, 1], [0x68, 2, 3]])
    }

    func testFUAReassembly() {
        let d = H264Depacketizer()
        // NAL header 0x65 (nri 3, type 5) split into three fragments.
        XCTAssertEqual(d.push(packet(1, ts: 7, marker: false, [0x7C, 0x85, 1, 2])), [])
        XCTAssertEqual(d.push(packet(2, ts: 7, marker: false, [0x7C, 0x05, 3])), [])
        let frames = d.push(packet(3, ts: 7, marker: true, [0x7C, 0x45, 4, 5]))
        XCTAssertEqual(frames, [H264Frame(nalUnits: [[0x65, 1, 2, 3, 4, 5]], timestamp: 7)])
    }

    func testFragmentWithGapIsDropped() {
        let d = H264Depacketizer()
        _ = d.push(packet(1, ts: 7, marker: false, [0x7C, 0x85, 1]))
        // Sequence 2 lost.
        let frames = d.push(packet(3, ts: 7, marker: true, [0x7C, 0x45, 4]))
        XCTAssertEqual(frames, [])
        XCTAssertEqual(d.sequenceGaps, 1)
    }

    func testNewTimestampClosesFrameWhoseMarkerWasLost() {
        let d = H264Depacketizer()
        _ = d.push(packet(1, ts: 10, marker: false, [0x41, 1]))
        let frames = d.push(packet(2, ts: 20, marker: false, [0x41, 2]))
        XCTAssertEqual(frames, [H264Frame(nalUnits: [[0x41, 1]], timestamp: 10)])
        XCTAssertEqual(d.push(packet(3, ts: 20, marker: true, [0x41, 3])), [H264Frame(nalUnits: [[0x41, 2], [0x41, 3]], timestamp: 20)])
    }

    func testSequenceWrapIsNotAGap() {
        let d = H264Depacketizer()
        _ = d.push(packet(0xFFFF, ts: 1, marker: true, [0x41]))
        _ = d.push(packet(0, ts: 2, marker: true, [0x41]))
        XCTAssertEqual(d.sequenceGaps, 0)
    }

    func testAVCC() {
        XCTAssertEqual(avccData(for: [[0x65, 1], [0x06]]), [0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x06])
    }
}

final class SlotConfigTests: XCTestCase {
    func testPortsAndDeviceIDsMatchTheTestedSetup() {
        let one = SlotConfig(id: 1, name: "Mac Slot 1")
        let two = SlotConfig(id: 2, name: "Mac Slot 2")
        XCTAssertEqual(one.airplayBasePort, 7300)
        XCTAssertEqual(two.airplayBasePort, 7400)
        XCTAssertEqual(one.deviceID, "02:00:00:00:00:01")
        XCTAssertEqual(SlotConfig(id: 12, name: "x").deviceID, "02:00:00:00:00:0C")
        XCTAssertNotEqual(one.rtpPort, two.rtpPort)
    }

    func testArgumentsTurnOffTimestampSyncAndForwardVideo() {
        let args = SlotConfig(id: 2, name: "Kitchen iPhone").uxplayArguments
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "Kitchen iPhone")
        XCTAssertEqual(args[args.firstIndex(of: "-vsync")! + 1], "no")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "7400")
        XCTAssertTrue(args[args.firstIndex(of: "-vrtp")! + 1].hasSuffix("udpsink host=127.0.0.1 port=5602"))
        XCTAssertEqual(args[args.firstIndex(of: "-d")! + 1], "1")
    }
}

final class UxPlayEventTests: XCTestCase {
    func testConnectionRequest() {
        XCTAssertEqual(
            UxPlayEvent(line: "connection request from t-bone's iPhone (iPhone18,2) with deviceID = 12:34:56:78:9A:BC"),
            .clientConnecting(name: "t-bone's iPhone", model: "iPhone18,2")
        )
        XCTAssertEqual(
            UxPlayEvent(line: "connection request from Kid (2) (iPhone14,6) with deviceID = AA"),
            .clientConnecting(name: "Kid (2)", model: "iPhone14,6")
        )
    }

    func testOpenConnections() {
        XCTAssertEqual(UxPlayEvent(line: "Open connections: 0"), .openConnections(0))
        XCTAssertEqual(UxPlayEvent(line: "Open connections: 2"), .openConnections(2))
    }

    func testLostConnection() {
        XCTAssertEqual(UxPlayEvent(line: "*** ERROR lost connection with client (network problem?)"), .lostConnection)
    }

    func testStreamPauseAndResume() {
        XCTAssertEqual(UxPlayEvent(line: "This packet indicates video stream is stopping"), .streamPaused)
        XCTAssertEqual(
            UxPlayEvent(line: "Received unencrypted codec packet from client: payload_size 37 header 01 00 56 01  ts_client = 1791738799.849069"),
            .streamPaused
        )
        XCTAssertEqual(
            UxPlayEvent(line: "Received unencrypted codec packet from client: payload_size 37 header 01 00 16 01  ts_client = 1791738808.749092"),
            .streamStarted
        )
        XCTAssertEqual(UxPlayEvent(line: "video renderer resumed: state PAUSED"), .streamStarted)
        XCTAssertEqual(UxPlayEvent(line: "raop_rtp_mirror starting mirroring"), .streamStarted)
    }

    func testHeartbeat() {
        XCTAssertEqual(UxPlayEvent(line: "httpd: request POST /feedback RTSP/1.0"), .heartbeat)
    }

    func testBeginVideoStreamIsNotAResume() {
        // uxplay prints this right after a stop too.
        XCTAssertNil(UxPlayEvent(line: "begin video stream wxh = 498x1080; source 498x1080"))
    }

    func testOtherLinesAreIgnored() {
        XCTAssertNil(UxPlayEvent(line: "Initialized server socket(s)"))
        XCTAssertNil(UxPlayEvent(line: "Open connections: many"))
        XCTAssertNil(UxPlayEvent(line: "video renderer pause: NO PREROLL"))
    }
}

final class WindowTitleTests: XCTestCase {
    func testUsesLastPhoneNameElseSlotName() {
        let titles = SlotConfig.windowTitles(for: [
            SlotConfig(id: 1, name: "Mirror Wall 1", lastPhoneName: "Tom’s iPhone"),
            SlotConfig(id: 2, name: "Mirror Wall 2"),
        ])
        XCTAssertEqual(titles, [1: "MacMirror-Tom’s iPhone", 2: "MacMirror-Mirror Wall 2"])
    }

    func testClashingNamesGetTheSlotNumber() {
        let titles = SlotConfig.windowTitles(for: [
            SlotConfig(id: 1, name: "Mirror Wall 1", lastPhoneName: "iPhone"),
            SlotConfig(id: 2, name: "Mirror Wall 2", lastPhoneName: "iPhone"),
            SlotConfig(id: 3, name: "Mirror Wall 3", lastPhoneName: "iPad"),
        ])
        XCTAssertEqual(titles, [1: "MacMirror-iPhone-1", 2: "MacMirror-iPhone-2", 3: "MacMirror-iPad"])
    }

    func testOlderSavedSlotsStillDecode() throws {
        let data = Data(#"[{"id":1,"name":"Desk"}]"#.utf8)
        let slots = try JSONDecoder().decode([SlotConfig].self, from: data)
        XCTAssertEqual(slots, [SlotConfig(id: 1, name: "Desk")])
        XCTAssertNil(slots[0].lastPhoneName)
    }
}

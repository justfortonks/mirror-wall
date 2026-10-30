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
        XCTAssertEqual(d.lostPackets, 1)
    }

    func testLatePacketIsNotCountedAsLost() {
        let d = H264Depacketizer()
        _ = d.push(packet(10, ts: 1, marker: true, [0x41]))
        _ = d.push(packet(9, ts: 1, marker: true, [0x41]))
        XCTAssertEqual(d.lostPackets, 0)
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
        XCTAssertEqual(d.lostPackets, 0)
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
        XCTAssertEqual(SlotConfig(id: 3, name: "x").deviceID(computer: 0x5A1F_C309), "02:5A:1F:C3:09:03")
        let args = SlotConfig(id: 1, name: "x").uxplayArguments(maxFrameRate: 30, computer: 0xDEAD_BEEF)
        XCTAssertEqual(args[args.firstIndex(of: "-m")! + 1], "02:DE:AD:BE:EF:01")
        XCTAssertNotEqual(one.rtpPort, two.rtpPort)
    }

    func testArgumentsTurnOffTimestampSyncAndForwardVideo() {
        let args = SlotConfig(id: 2, name: "Kitchen iPhone").uxplayArguments
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "Kitchen iPhone")
        XCTAssertEqual(args[args.firstIndex(of: "-vsync")! + 1], "no")
        XCTAssertEqual(args[args.firstIndex(of: "-fps")! + 1], "30")
        let fast = SlotConfig(id: 2, name: "Kitchen iPhone").uxplayArguments(maxFrameRate: 60)
        XCTAssertEqual(fast[fast.firstIndex(of: "-fps")! + 1], "60")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "7400")
        XCTAssertTrue(args[args.firstIndex(of: "-vrtp")! + 1].hasSuffix("udpsink sync=false host=127.0.0.1 port=5602"))
        XCTAssertEqual(args[args.firstIndex(of: "-d")! + 1], "1")
        XCTAssertFalse(args.contains("-restrict"))
        XCTAssertFalse(args.contains("-h265"))
        XCTAssertEqual(args[args.firstIndex(of: "-nc")! + 1], "no")
        XCTAssertTrue(SlotConfig(id: 2, name: "x").uxplayArguments(maxFrameRate: 30, sharpPicture: true).contains("-h265"))
    }

    func testAllowList() {
        let args = SlotConfig(id: 1, name: "x").uxplayArguments(maxFrameRate: 30, allowedDevices: ["AA:BB", "CC:DD"])
        XCTAssertEqual(Array(args.suffix(5)), ["-restrict", "-allow", "AA:BB", "-allow", "CC:DD"])
    }

    func testDefaultNamesUseTheMacsName() {
        XCTAssertEqual(SlotConfig.defaultName(for: 1, computerName: "Alex's MacBook Air"), "Mirror Wall 1 · MacBook Air")
        XCTAssertEqual(SlotConfig.defaultName(for: 2, computerName: "Alex’s Mac Studio in the Office"), "Mirror Wall 2 · Mac Studio in")
        XCTAssertEqual(SlotConfig.defaultName(for: 2, computerName: "Studio"), "Mirror Wall 2 · Studio")
        XCTAssertEqual(SlotConfig.defaultName(for: 3, computerName: nil), "Mirror Wall 3")
        XCTAssertEqual(SlotConfig.defaultName(for: 3, computerName: "  "), "Mirror Wall 3")
        XCTAssertLessThanOrEqual(SlotConfig.defaultName(for: 8, computerName: "Alex's Extremely Long Mac Name").count, SlotConfig.maxNameLength)
        XCTAssertTrue(SlotConfig.isOldDefaultName("Mirror Wall 2", id: 2, computerName: nil))
        XCTAssertFalse(SlotConfig.isOldDefaultName("Mirror Wall 2", id: 1, computerName: nil))
        XCTAssertTrue(SlotConfig.isOldDefaultName("Alex's MacBook Air 1", id: 1, computerName: "Alex's MacBook Air"))
        XCTAssertFalse(SlotConfig.isOldDefaultName("Kitchen", id: 1, computerName: "Alex's MacBook Air"))
    }

    func testTidyNames() {
        XCTAssertEqual(SlotConfig.tidyName("  Kitchen   iPhone "), "Kitchen iPhone")
        XCTAssertEqual(SlotConfig.tidyName("The Very Long Name Of My Demo Phone Number Two"), "The Very Long Name Of My Demo")
        XCTAssertEqual(SlotConfig.tidyName("Supercalifragilisticexpialidocious-phone"), "Supercalifragilisticexpialidoc")
        XCTAssertEqual(SlotConfig.tidyName("   "), "")
        XCTAssertLessThanOrEqual(SlotConfig.tidyName(String(repeating: "📱", count: 30)).utf8.count, 60)
    }

    func testOldSavedSlotsStillLoad() throws {
        let json = #"[{"id":1,"name":"Mirror Wall 1","lastPhoneName":"Phone"}]"#
        let configs = try JSONDecoder().decode([SlotConfig].self, from: Data(json.utf8))
        XCTAssertNil(configs[0].standby)
        var config = configs[0]
        config.standby = .image(fileName: "standby-1.png")
        let again = try JSONDecoder().decode(SlotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.standby, .image(fileName: "standby-1.png"))
        config.standby = .message
        XCTAssertEqual(try JSONDecoder().decode(SlotConfig.self, from: JSONEncoder().encode(config)).standby, .message)
    }
}

final class UxPlayEventTests: XCTestCase {
    func testConnectionRequest() {
        XCTAssertEqual(
            UxPlayEvent(line: "connection request from t-bone's iPhone (iPhone18,2) with deviceID = 12:34:56:78:9A:BC"),
            .clientConnecting(name: "t-bone's iPhone", model: "iPhone18,2", deviceID: "12:34:56:78:9A:BC")
        )
        XCTAssertEqual(
            UxPlayEvent(line: "connection request from Kid (2) (iPhone14,6) with deviceID = AA"),
            .clientConnecting(name: "Kid (2)", model: "iPhone14,6", deviceID: "AA")
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

    func testNetworkRoundTrip() {
        XCTAssertEqual(UxPlayEvent(line: "best NTP data: offset   0.152731, delay   0.004812"), .networkRoundTrip(0.004812))
    }

    func testVideoLatency() {
        XCTAssertEqual(
            UxPlayEvent(line: "raop_rtp video: now = 8123.456789, ntp = 8123.410000, latency =  0.046789, ts = 1791738808.749092, 00 00 00 00 h264, size: 4123"),
            .videoLatency(0.046789)
        )
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

    func testRenamedSlotsUseTheirOwnName() {
        let titles = SlotConfig.windowTitles(for: [
            SlotConfig(id: 1, name: "Desk", lastPhoneName: "Tom’s iPhone"),
            SlotConfig(id: 2, name: "Mirror Wall 2 · MacBook Air", lastPhoneName: "iPad"),
        ])
        XCTAssertEqual(titles, [1: "MacMirror-Desk", 2: "MacMirror-iPad"])
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


final class PackagedReceiverTests: XCTestCase {
    private let packaged = "/Applications/MirrorWall.app/Contents/Resources/receiver/bin/uxplay"

    func testPackagedReceiverUsesOnlyItsOwnPlugins() throws {
        let environment = try XCTUnwrap(PackagedReceiver.environment(
            forExecutableAt: packaged,
            inheriting: ["HOME": "/Users/me", "GST_PLUGIN_PATH": "/opt/homebrew/lib/gstreamer-1.0"],
            registryPath: "/Users/me/Library/Caches/MirrorWall/gstreamer-registry.bin",
            fileExists: { $0 == "/Applications/MirrorWall.app/Contents/Resources/receiver/lib/gstreamer-1.0" }
        ))
        XCTAssertEqual(environment["GST_PLUGIN_SYSTEM_PATH"], "/Applications/MirrorWall.app/Contents/Resources/receiver/lib/gstreamer-1.0")
        XCTAssertEqual(environment["GST_PLUGIN_SCANNER"], "/Applications/MirrorWall.app/Contents/Resources/receiver/libexec/gst-plugin-scanner")
        XCTAssertEqual(environment["GST_REGISTRY"], "/Users/me/Library/Caches/MirrorWall/gstreamer-registry.bin")
        XCTAssertNil(environment["GST_PLUGIN_PATH"])
        XCTAssertEqual(environment["HOME"], "/Users/me")
    }

    func testOtherReceiversInheritTheEnvironment() {
        // A uxplay built against Homebrew has no plugins folder beside it.
        for path in ["/opt/homebrew/bin/uxplay", "/Users/me/UxPlay/build/uxplay", "/usr/local/bin/somethingelse"] {
            XCTAssertNil(PackagedReceiver.environment(
                forExecutableAt: path, inheriting: [:], registryPath: "/tmp/registry.bin", fileExists: { _ in false }
            ))
        }
    }
}

final class StreamMeterTests: XCTestCase {
    func testSumsUpEachSecond() throws {
        let meter = StreamMeter()
        meter.packet(bytes: 1000, lost: 0, at: 0)
        meter.frame(at: 0, isKeyframe: true, macTime: 0.002)
        XCTAssertNil(meter.snapshotIfDue(at: 0.5))
        meter.packet(bytes: 1000, lost: 2, at: 0.5)
        meter.frame(at: 0.5, isKeyframe: false, macTime: 0.004)
        meter.frame(at: 0.6, isKeyframe: false, macTime: nil)
        let snapshot = try XCTUnwrap(meter.snapshotIfDue(at: 1))
        XCTAssertEqual(snapshot.framesPerSecond, 2)
        XCTAssertEqual(snapshot.bitsPerSecond, 16000)
        XCTAssertEqual(try XCTUnwrap(snapshot.macTime), 0.003, accuracy: 1e-9)
        XCTAssertEqual(snapshot.packetsLost, 2)
        XCTAssertEqual(snapshot.totalFramesSkipped, 1)
        XCTAssertEqual(snapshot.totalKeyframes, 1)

        // The next second starts empty, but totals carry on.
        meter.packet(bytes: 10, lost: 1, at: 1.2)
        let next = try XCTUnwrap(meter.snapshotIfDue(at: 2))
        XCTAssertEqual(next.framesPerSecond, 0)
        XCTAssertEqual(next.packetsLost, 1)
        XCTAssertEqual(next.totalPacketsLost, 3)
    }

    func testJitterIgnoresPauses() throws {
        let meter = StreamMeter()
        for time in [0.0, 0.1, 0.2, 2.0, 2.1] {
            meter.frame(at: time, isKeyframe: false, macTime: 0.001)
        }
        let snapshot = try XCTUnwrap(meter.snapshotIfDue(at: 2.2))
        XCTAssertEqual(snapshot.frameJitter, 0, accuracy: 1e-9)
    }

    func testKeyframeInterval() throws {
        let meter = StreamMeter()
        meter.frame(at: 0, isKeyframe: true, macTime: 0.001)
        meter.frame(at: 0.4, isKeyframe: false, macTime: 0.001)
        meter.frame(at: 0.9, isKeyframe: true, macTime: 0.001)
        let snapshot = try XCTUnwrap(meter.snapshotIfDue(at: 1))
        XCTAssertEqual(try XCTUnwrap(snapshot.keyframeInterval), 0.9, accuracy: 1e-9)
        XCTAssertEqual(snapshot.totalKeyframes, 2)
    }

    func testCodecDescription() {
        XCTAssertEqual(h264Description(sps: [0x67, 100, 0, 42]), "H.264 High 4.2")
        XCTAssertEqual(h264Description(sps: [0x67, 77, 0, 31]), "H.264 Main 3.1")
        XCTAssertEqual(h264Description(sps: [0x67]), "H.264")
    }
}

final class PhoneModelTests: XCTestCase {
    func testFriendlyNames() {
        XCTAssertEqual(phoneModelName("iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertEqual(phoneModelName("iPhone14,6"), "iPhone SE (3rd generation)")
        XCTAssertEqual(phoneModelName("iPhone99,1"), "iPhone99,1")
    }

    func testTrueToLifeSizes() {
        // The 17 Pro Max is the reference; the SE's screen is about two-thirds as tall.
        XCTAssertEqual(trueToLifeLongSide(reference: 800, modelCode: "iPhone18,2", pictureWidth: 498, pictureHeight: 1080), 800, accuracy: 3)
        XCTAssertEqual(trueToLifeLongSide(reference: 800, modelCode: "iPhone14,6", pictureWidth: 608, pictureHeight: 1080), 524, accuracy: 5)
        // Landscape uses the same long side.
        XCTAssertEqual(trueToLifeLongSide(reference: 800, modelCode: "iPhone14,6", pictureWidth: 1080, pictureHeight: 608), 524, accuracy: 5)
        // Unknown phones keep the reference size.
        XCTAssertEqual(trueToLifeLongSide(reference: 800, modelCode: "iPhone99,1", pictureWidth: 498, pictureHeight: 1080), 800)
        XCTAssertEqual(trueToLifeLongSide(reference: 800, modelCode: nil, pictureWidth: 498, pictureHeight: 1080), 800)
    }
}

final class RecordingClockTests: XCTestCase {
    func testTimesFramesFromStampsNotBurstyArrival() {
        var clock = RecordingClock()
        let start: UInt32 = 1000
        XCTAssertEqual(clock.time(rtp: start, arrival: 10.000), 0)
        // Three frames 1/60 s apart that arrived together.
        XCTAssertEqual(clock.time(rtp: start + 1500, arrival: 10.050), 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(clock.time(rtp: start + 3000, arrival: 10.051), 2.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(clock.time(rtp: start + 4500, arrival: 10.052), 3.0 / 60, accuracy: 1e-9)
    }

    func testHandlesWrapAround() {
        var clock = RecordingClock()
        _ = clock.time(rtp: UInt32.max - 499, arrival: 0)
        XCTAssertEqual(clock.time(rtp: 1000, arrival: 0.0167), 1500 / RecordingClock.rtpRate, accuracy: 1e-9)
    }

    func testFallsBackToArrivalOnBadStamps() {
        var clock = RecordingClock()
        _ = clock.time(rtp: 90_000, arrival: 5)
        // Backwards stamp: use the time between arrivals.
        XCTAssertEqual(clock.time(rtp: 0, arrival: 5.5), 0.5, accuracy: 1e-9)
        // Repeated stamp: still moves forward.
        XCTAssertGreaterThan(clock.time(rtp: 0, arrival: 5.5), 0.5)
    }

    func testUnknownStampUsesArrival() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.time(rtp: nil, arrival: 3), 0)
        XCTAssertEqual(clock.time(rtp: 45_000, arrival: 3.2), 0.2, accuracy: 1e-9)
        XCTAssertEqual(clock.time(rtp: 46_500, arrival: 3.3), 0.2 + 1.0 / 60, accuracy: 1e-9)
    }

    func testStaysNearArrivalTime() {
        var clock = RecordingClock()
        _ = clock.time(rtp: 0, arrival: 0)
        // Stamps claim 1.9 s each while only 0.1 s passes: pulled back to the wall clock.
        _ = clock.time(rtp: 171_000, arrival: 0.1)
        XCTAssertEqual(clock.time(rtp: 342_000, arrival: 0.2), 0.2, accuracy: 1e-9)
        XCTAssertEqual(clock.time(atArrival: 1.2), 1.2, accuracy: 1e-9)
    }
}

final class PlayoutClockTests: XCTestCase {
    /// Frames captured 1/30 s apart that arrived in bursts come out evenly spaced.
    func testSpacesBurstyFramesEvenly() {
        var clock = PlayoutClock(delay: 0.1)
        let step: UInt32 = 3000 // 1/30 s
        let first = clock.due(rtp: 0, arrival: 10.000)
        XCTAssertEqual(first, 10.1, accuracy: 1e-9)
        // The next three arrive in a burst, the first of them late.
        let second = clock.due(rtp: step, arrival: 10.105)
        let third = clock.due(rtp: 2 * step, arrival: 10.106)
        let fourth = clock.due(rtp: 3 * step, arrival: 10.107)
        XCTAssertEqual(second - first, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(third - second, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(fourth - third, 1.0 / 30, accuracy: 1e-9)
    }

    func testFasterTripLowersTheDelay() {
        var clock = PlayoutClock(delay: 0.1)
        _ = clock.due(rtp: 0, arrival: 10.05)
        // Captured 0.1 s later, this frame made the trip 40 ms quicker: it waits only the delay.
        XCTAssertEqual(clock.due(rtp: 9000, arrival: 10.11), 10.21, accuracy: 1e-9)
    }

    func testLateFrameShowsAtOnceAndNeverBeforeThePreviousOne() {
        var clock = PlayoutClock(delay: 0.1)
        _ = clock.due(rtp: 0, arrival: 0)
        // Arrives 300 ms after its capture time: beyond the delay, so shown on arrival.
        XCTAssertEqual(clock.due(rtp: 3000, arrival: 0.3333), 0.3333, accuracy: 1e-9)
        // Its successor came quickly, but can't go before it.
        XCTAssertEqual(clock.due(rtp: 6000, arrival: 0.3334), 0.3334, accuracy: 1e-9)
    }

    func testStartsOverAfterAJump() {
        var clock = PlayoutClock(delay: 0.1)
        _ = clock.due(rtp: 0, arrival: 0)
        // The screen was off for a minute: the stamp jumps 60 s.
        XCTAssertEqual(clock.due(rtp: 5_400_000, arrival: 60), 60.1, accuracy: 1e-9)
        // Backwards (a new stream): starts over too.
        XCTAssertEqual(clock.due(rtp: 100, arrival: 61), 61.1, accuracy: 1e-9)
    }

    /// A network that gets slower stops making every frame late once the window turns over.
    func testAdaptsWhenTheNetworkSlows() {
        var clock = PlayoutClock(delay: 0.1)
        var arrival = 0.0
        var rtp: UInt32 = 0
        _ = clock.due(rtp: rtp, arrival: arrival)
        // From now on every frame takes 200 ms longer.
        var lastWait = 0.0
        for _ in 0..<(30 * 11) {
            rtp &+= 3000
            arrival += 1.0 / 30
            lastWait = clock.due(rtp: rtp, arrival: arrival + 0.2) - (arrival + 0.2)
        }
        XCTAssertEqual(lastWait, 0.1, accuracy: 1e-6)
    }
}

final class HEVCDepacketizerTests: XCTestCase {
    private func packet(_ seq: UInt16, ts: UInt32, marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        RTPPacket(marker: marker, sequenceNumber: seq, timestamp: ts, payload: payload)
    }

    private let vps: [UInt8] = [0x40, 0x01, 0xAA]
    private let sps: [UInt8] = [0x42, 0x01, 0xBB]
    private let pps: [UInt8] = [0x44, 0x01, 0xCC]

    /// Parameter sets as single packets, then an IDR picture in three fragments.
    func testReassemblesParameterSetsAndFragments() {
        let d = H264Depacketizer()
        XCTAssertEqual(d.push(packet(1, ts: 9, marker: false, vps)), [])
        XCTAssertEqual(d.codec, .hevc)
        _ = d.push(packet(2, ts: 9, marker: false, sps))
        _ = d.push(packet(3, ts: 9, marker: false, pps))
        // FU header: start bit, type 19 (IDR_W_RADL).
        _ = d.push(packet(4, ts: 9, marker: false, [0x62, 0x01, 0x80 | 19, 1, 2]))
        _ = d.push(packet(5, ts: 9, marker: false, [0x62, 0x01, 19, 3]))
        let frames = d.push(packet(6, ts: 9, marker: true, [0x62, 0x01, 0x40 | 19, 4]))
        XCTAssertEqual(frames, [H264Frame(nalUnits: [vps, sps, pps, [0x26, 0x01, 1, 2, 3, 4]], timestamp: 9, codec: .hevc)])
        XCTAssertTrue(frames[0].isKeyframe)
    }

    func testAggregationPacket() {
        let d = H264Depacketizer()
        var ap: [UInt8] = [0x60, 0x01]
        for nal in [vps, sps, pps] { ap += [0, UInt8(nal.count)] + nal }
        let frames = d.push(packet(1, ts: 3, marker: true, ap))
        XCTAssertEqual(frames, [H264Frame(nalUnits: [vps, sps, pps], timestamp: 3, codec: .hevc)])
    }

    func testTrailingPictureIsNotAKeyframe() {
        let d = H264Depacketizer()
        _ = d.push(packet(1, ts: 1, marker: true, vps))
        let frames = d.push(packet(2, ts: 2, marker: true, [0x02, 0x01, 7])) // TRAIL_R
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(frames[0].isKeyframe)
    }

    /// A slot whose receiver is restarted can get the other codec next; a parameter set switches.
    func testSwitchesCodecOnParameterSets() {
        let d = H264Depacketizer()
        _ = d.push(packet(1, ts: 1, marker: true, vps))
        XCTAssertEqual(d.codec, .hevc)
        _ = d.push(packet(2, ts: 2, marker: true, [0x67, 0x64, 0, 0x2A]))
        XCTAssertEqual(d.codec, .h264)
        var stap: [UInt8] = [0x78, 0, 2, 0x67, 1]
        stap += [0, 2, 0x68, 2]
        XCTAssertEqual(H264Depacketizer.codecOfParameterSets(in: stap), .h264)
        // H.264 slices and fragments, and H.265 slices, show nothing.
        for payload: [UInt8] in [[0x41, 1], [0x65, 1], [0x7C, 0x85, 1], [0x02, 0x01, 1], [0x26, 0x01, 1], [0x62, 0x01, 0x93]] {
            XCTAssertNil(H264Depacketizer.codecOfParameterSets(in: payload), "\(payload)")
        }
        d.reset()
        XCTAssertEqual(d.codec, .h264)
    }
}

final class HEVCDescriptionTests: XCTestCase {
    func testReadsProfileAndLevelThroughEmulationPrevention() {
        // NAL header, IDs, Main profile, compatibility flags, constraint flags with an emulation
        // prevention byte, level 5.1 (153).
        let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 153, 0xA0]
        XCTAssertEqual(hevcDescription(sps: sps), "H.265 Main 5.1")
        XCTAssertEqual(hevcDescription(sps: [0x42, 0x01]), "H.265")
    }
}

final class ChangeLogTests: XCTestCase {
    func testReadsTheNewestEntryWithWrappedBulletsJoined() {
        let markdown = """
        # What's changed

        Intro text.

        ## October 12, 2026: Downloads

        - First item,
          wrapped.
        - Second item.

        ## October 11, 2026: Older

        - Not included.
        """
        XCTAssertEqual(ChangeLogEntry.latest(in: markdown),
                       ChangeLogEntry(heading: "October 12, 2026: Downloads", items: ["First item, wrapped.", "Second item."]))
    }

    func testTheRepositoryChangeLogHasAnEntry() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../CHANGELOG.md")
        let entry = try XCTUnwrap(ChangeLogEntry.latest(in: String(contentsOf: url, encoding: .utf8)))
        XCTAssertFalse(entry.items.isEmpty)
    }

    func testNoEntry() {
        XCTAssertNil(ChangeLogEntry.latest(in: "# Nothing yet\n"))
    }
}

final class CastProtocolTests: XCTestCase {
    func testRoundTripsEveryMessageOneByteAtATime() throws {
        let messages: [CastMessage] = [
            .hello(CastHello(name: "Front Desk", model: "Zebra HC50", deviceID: "abc123")),
            .welcome(CastWelcome(slot: "Mirror Wall 1 · Mac", maxFrameRate: 30)),
            .video(captureMicros: 1_234_567_890_123, accessUnit: [0, 0, 0, 1, 0x65, 9]),
            .paused, .resumed, .heartbeat,
            .busy(CastBusy(reason: "In use")),
            .welcome(CastWelcome(slot: "Mirror Wall 2", maxFrameRate: 60, sharpPicture: true)),
            .ping(0x0102_0304_0506_0708), .pong(42), .orientation(2),
            .bye,
        ]
        let reader = CastReader()
        var decoded: [CastMessage] = []
        for byte in messages.flatMap({ $0.encoded() }) {
            decoded += try reader.push([byte])
        }
        XCTAssertEqual(decoded, messages)
    }

    func testSkipsUnknownMessagesAndRejectsHugeOnes() throws {
        let reader = CastReader()
        XCTAssertEqual(try reader.push([0x40, 0, 0, 0, 2, 7, 7] + CastMessage.heartbeat.encoded()), [.heartbeat])
        XCTAssertThrowsError(try CastReader().push([0x02, 0x7F, 0, 0, 0]))
    }

    func testOrientationIsOneByteOfQuarterTurns() throws {
        XCTAssertEqual(CastMessage.orientation(3).encoded(), [0x08, 0, 0, 0, 1, 3])
        XCTAssertEqual(try CastReader().push([0x08, 0, 0, 0, 1, 1]), [.orientation(1)])
    }

    /// Phones and Mirror Walls of any version have to understand each other (see "Compatibility" in
    /// docs/mirror-wall-cast.md). These are messages exactly as 0.90 and 0.91 sent them, plus a
    /// newer phone's hello with a field and a version this Mirror Wall doesn't know.
    func testUnderstandsOlderAndNewerPeers() throws {
        func payloadMessage(_ type: CastMessageType, _ json: String) -> [UInt8] {
            let payload = Array(json.utf8)
            return [type.rawValue] + withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init) + payload
        }
        let reader = CastReader()
        XCTAssertEqual(
            try reader.push(payloadMessage(.hello, #"{"protocol":1,"name":"HC50","model":"Zebra Technologies HC50","deviceID":"android-1"}"#)),
            [.hello(CastHello(protocol: 1, name: "HC50", model: "Zebra Technologies HC50", deviceID: "android-1"))]
        )
        XCTAssertEqual(
            try reader.push(payloadMessage(.hello, #"{"protocol":9,"name":"HC50","model":"Zebra","deviceID":"android-2","battery":80}"#)),
            [.hello(CastHello(protocol: 9, name: "HC50", model: "Zebra", deviceID: "android-2"))]
        )
        XCTAssertEqual(
            try reader.push(payloadMessage(.welcome, #"{"slot":"Mirror Wall 1","maxFrameRate":30,"sharpPicture":false}"#)),
            [.welcome(CastWelcome(slot: "Mirror Wall 1", maxFrameRate: 30, sharpPicture: false, protocol: nil))]
        )
        let welcome = String(decoding: CastMessage.welcome(CastWelcome(slot: "S", maxFrameRate: 30)).encoded().dropFirst(5), as: UTF8.self)
        XCTAssertTrue(welcome.contains(#""protocol":\#(castProtocolVersion)"#), welcome)
    }

    func testSplitsAnnexB() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]
        XCTAssertEqual(annexBNALUnits(stream), [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
        XCTAssertEqual(annexBNALUnits([0x65, 1]), [])
    }

    func testTellsTheCodecFromAKeyframesParameterSets() {
        XCTAssertEqual(castCodec(of: [[0x67, 0x64, 0x00, 0x2A], [0x68, 1], [0x65, 2]]), .h264)
        XCTAssertEqual(castCodec(of: [[0x40, 0x01, 0x0C], [0x42, 0x01], [0x44, 0x01], [0x26, 0x01]]), .hevc)
        XCTAssertNil(castCodec(of: [[0x41, 0x9A]])) // an H.264 P slice, whose first byte looks like a VPS
        XCTAssertNil(castCodec(of: [[0x41, 0x01, 0x9A]]))
        XCTAssertNil(castCodec(of: [[0x02, 0x01]]))
    }

    func testCaptureTimeBecomesNinetyKilohertz() {
        XCTAssertEqual(castRTPTimestamp(captureMicros: 1_000_000), 90_000)
        XCTAssertEqual(castRTPTimestamp(captureMicros: 1_000_000 + 33_333) &- castRTPTimestamp(captureMicros: 1_000_000), 2_999)
    }

    func testCastPortsSitBesideEachSlotsAirPlayPorts() {
        XCTAssertEqual(SlotConfig(id: 1, name: "a").castPort, 7350)
        XCTAssertEqual(SlotConfig(id: 8, name: "a").castPort, 8050)
    }
}

final class PhoneBezelTests: XCTestCase {
    func testPicksAStyleFromTheModel() {
        XCTAssertEqual(BezelStyle(modelCode: "iPhone14,6"), .homeButton) // SE (3rd generation)
        XCTAssertEqual(BezelStyle(modelCode: "iPhone12,8"), .homeButton) // SE (2nd generation)
        XCTAssertEqual(BezelStyle(modelCode: "iPhone10,4"), .homeButton) // iPhone 8
        XCTAssertEqual(BezelStyle(modelCode: "iPhone10,6"), .notch)      // iPhone X
        XCTAssertEqual(BezelStyle(modelCode: "iPhone14,5"), .notch)      // iPhone 13
        XCTAssertEqual(BezelStyle(modelCode: "iPhone14,7"), .notch)      // iPhone 14
        XCTAssertEqual(BezelStyle(modelCode: "iPhone17,5"), .notch)      // iPhone 16e
        XCTAssertEqual(BezelStyle(modelCode: "iPhone15,2"), .dynamicIsland) // iPhone 14 Pro
        XCTAssertEqual(BezelStyle(modelCode: "iPhone18,2"), .dynamicIsland) // iPhone 17 Pro Max
        XCTAssertEqual(BezelStyle(modelCode: "iPhone99,1"), .dynamicIsland) // newer than the list
        XCTAssertEqual(BezelStyle(modelCode: "Pixel 8"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: "iPhone"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: nil), .plain)
    }

    func testPicksAndroidPhotoFramesByWholeModelNumber() {
        XCTAssertEqual(BezelStyle(modelCode: "Zebra Technologies HC50"), .zebraHC50)
        XCTAssertEqual(BezelStyle(modelCode: "Zebra HC50"), .zebraHC50)
        XCTAssertEqual(BezelStyle(modelCode: "HC50"), .zebraHC50)
        XCTAssertEqual(BezelStyle(modelCode: "Zebra Technologies HC20"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: "Zebra Technologies HC55"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: "Honeywell CT37"), .honeywellCT37)
        XCTAssertEqual(BezelStyle(modelCode: "Honeywell CT37 HC"), .honeywellCT37)
        XCTAssertEqual(BezelStyle(modelCode: "Honeywell CT37HC"), .honeywellCT37)
        XCTAssertEqual(BezelStyle(modelCode: "Honeywell CT30"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: "Honeywell CT370"), .plain)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink 9640"), .versity95)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink Versity 9553"), .versity95)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink V9540"), .versity95)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink Versity 9753"), .versity97)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink 9740"), .versity97)
        XCTAssertEqual(BezelStyle(modelCode: "Spectralink 9240"), .plain)
        XCTAssertEqual(phoneScreenDiagonal("Zebra Technologies HC50"), 6)
    }

    func testPhotoFrameFitsThePictureInItsScreen() {
        // HC50: 1280×2640 photo, 1080×2160 screen at (100, 240).
        let exact = BezelGeometry(style: .zebraHC50, pictureWidth: 1080, pictureHeight: 2160)
        XCTAssertEqual(exact.left, 100.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(exact.top, 240.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(exact.right, 100.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(exact.bottom, 240.0 / 1080, accuracy: 1e-9)
        let outer = exact.outerSize(pictureWidth: 1080, pictureHeight: 2160)
        XCTAssertEqual(outer.width / outer.height, 1280.0 / 2640, accuracy: 1e-9)

        // A slightly narrower picture is centered, never stretched; the photo keeps its shape.
        let narrow = BezelGeometry(style: .zebraHC50, pictureWidth: 1072, pictureHeight: 2160)
        let narrowOuter = narrow.outerSize(pictureWidth: 1072, pictureHeight: 2160)
        XCTAssertEqual(narrowOuter.width / narrowOuter.height, 1280.0 / 2640, accuracy: 1e-9)
        XCTAssertEqual(narrow.left, narrow.right, accuracy: 1e-9)
        XCTAssertGreaterThan(narrow.left, narrow.artworkScreen!.x)

        // Sideways: the photo's top edge goes left. CT37: 1360×2880, screen 1080×2280 at (140, 320).
        let sideways = BezelGeometry(style: .honeywellCT37, pictureWidth: 2280, pictureHeight: 1080)
        XCTAssertTrue(sideways.landscape)
        XCTAssertEqual(sideways.left, 320.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(sideways.right, 280.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(sideways.top, 140.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(sideways.bottom, 140.0 / 1080, accuracy: 1e-9)
    }

    func testFrameTurnsTheWayThePhoneSays() {
        let upright = BezelGeometry(style: .homeButton, pictureWidth: 750, pictureHeight: 1334)
        let upsideDown = BezelGeometry(style: .homeButton, pictureWidth: 750, pictureHeight: 1334, turns: 2)
        XCTAssertEqual(upsideDown.quarterTurns, 2)
        XCTAssertEqual(upsideDown.top, upright.bottom)
        XCTAssertEqual(upsideDown.uprightTop, upright.top)
        let topRight = BezelGeometry(style: .homeButton, pictureWidth: 1334, pictureHeight: 750, turns: 3)
        XCTAssertEqual(topRight.right, upright.top)
        XCTAssertEqual(topRight.left, upright.bottom)
        // A turn that doesn't match the picture (its new picture hasn't arrived) is ignored.
        XCTAssertEqual(BezelGeometry(style: .homeButton, pictureWidth: 750, pictureHeight: 1334, turns: 1).quarterTurns, 0)
        XCTAssertEqual(BezelGeometry(style: .homeButton, pictureWidth: 1334, pictureHeight: 750, turns: 0).quarterTurns, 1)

        // CT37 upside down: 1360×2880, screen 1080×2280 at (140, 320), so 280 above, 320 below.
        let photo = BezelGeometry(style: .honeywellCT37, pictureWidth: 1080, pictureHeight: 2280, turns: 2)
        XCTAssertEqual(photo.top, 280.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(photo.bottom, 320.0 / 1080, accuracy: 1e-9)
        // Top on the right.
        let photoRight = BezelGeometry(style: .honeywellCT37, pictureWidth: 2280, pictureHeight: 1080, turns: 3)
        XCTAssertEqual(photoRight.left, 280.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(photoRight.right, 320.0 / 1080, accuracy: 1e-9)
    }

    func testFrameTurnsWithThePicture() {
        let portrait = BezelGeometry(style: .homeButton, pictureWidth: 750, pictureHeight: 1334)
        XCTAssertFalse(portrait.landscape)
        XCTAssertEqual(portrait.top, 0.215)
        XCTAssertEqual(portrait.left, 0.06)
        let landscape = BezelGeometry(style: .homeButton, pictureWidth: 1334, pictureHeight: 750)
        XCTAssertTrue(landscape.landscape)
        XCTAssertEqual(landscape.left, portrait.top)
        XCTAssertEqual(landscape.right, portrait.bottom)
        XCTAssertEqual(landscape.top, portrait.left)

        let size = portrait.outerSize(pictureWidth: 750, pictureHeight: 1334)
        XCTAssertEqual(size.width, 1.12, accuracy: 1e-9)
        XCTAssertEqual(size.height, 1334.0 / 750 + 0.43, accuracy: 1e-9)
        let sideways = landscape.outerSize(pictureWidth: 1334, pictureHeight: 750)
        XCTAssertEqual(sideways.width, size.height, accuracy: 1e-9)
        XCTAssertEqual(sideways.height, size.width, accuracy: 1e-9)
        let upright = landscape.portraitOuterSize(pictureWidth: 1334, pictureHeight: 750)
        XCTAssertEqual(upright.width, size.width, accuracy: 1e-9)
        XCTAssertEqual(upright.height, size.height, accuracy: 1e-9)
    }
}

final class StageLayoutTests: XCTestCase {
    private let big = (width: 1.0, height: 2.0)
    private let small = (width: 0.5, height: 1.0)

    func testSideBySideKeepsRelativeSizesAndCenters() {
        let frames = stageFrames(sizes: [big, small], layout: .sideBySide, areaWidth: 1000, areaHeight: 1000, spacing: 0)
        XCTAssertEqual(frames.count, 2)
        // As tall as the stage, the row centered left to right.
        XCTAssertEqual(frames[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(frames[0].height, 1000, accuracy: 1e-9)
        XCTAssertEqual(frames[0].x, 1000 - (frames[1].x + frames[1].width), accuracy: 1e-9)
        XCTAssertEqual(frames[1].height, frames[0].height / 2, accuracy: 1e-9)
        XCTAssertEqual(frames[0].y + frames[0].height / 2, 500, accuracy: 1e-9)
        XCTAssertEqual(frames[1].y + frames[1].height / 2, 500, accuracy: 1e-9)
    }

    func testStackedRunsTopToBottom() {
        let frames = stageFrames(sizes: [small, small], layout: .stacked, areaWidth: 1000, areaHeight: 1000)
        XCTAssertLessThan(frames[0].y + frames[0].height, frames[1].y)
        XCTAssertEqual(frames[0].x, frames[1].x, accuracy: 1e-9)
        XCTAssertEqual(frames[0].x + frames[0].width / 2, 500, accuracy: 1e-9)
    }

    func testGapsAndMarginsKeepPhonesApartAndInside() {
        for layout in StageLayout.allCases {
            let frames = stageFrames(sizes: [big, small, big, small, big], layout: layout, areaWidth: 1280, areaHeight: 720)
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThan(frame.x, 0)
                XCTAssertGreaterThan(frame.y, 0)
                XCTAssertLessThan(frame.x + frame.width, 1280)
                XCTAssertLessThan(frame.y + frame.height, 720)
                for other in frames[(index + 1)...] {
                    let apart = frame.x + frame.width < other.x || other.x + other.width < frame.x
                        || frame.y + frame.height < other.y || other.y + other.height < frame.y
                    XCTAssertTrue(apart, "\(layout)")
                }
            }
        }
    }

    func testGridCentersAShortLastRow() {
        let frames = stageFrames(sizes: [big, big, big], layout: .grid, areaWidth: 1000, areaHeight: 1000)
        XCTAssertEqual(frames[0].y, frames[1].y, accuracy: 1e-9)
        XCTAssertGreaterThan(frames[2].y, frames[0].y)
        XCTAssertEqual(frames[2].x + frames[2].width / 2, 500, accuracy: 1e-9)
    }

    func testNoPhonesOrNoRoom() {
        XCTAssertEqual(stageFrames(sizes: [], layout: .grid, areaWidth: 100, areaHeight: 100), [])
        XCTAssertEqual(stageFrames(sizes: [big], layout: .grid, areaWidth: 0, areaHeight: 100), [StageRect(x: 0, y: 0, width: 0, height: 0)])
    }

    func testPhoneSizesAreTrueToLife() {
        let proMax = stagePhoneSize(modelCode: "iPhone18,2", pictureWidth: 1320, pictureHeight: 2868, bezel: false)
        XCTAssertEqual(max(proMax.width, proMax.height), 1, accuracy: 0.01)
        let se = stagePhoneSize(modelCode: "iPhone14,6", pictureWidth: 750, pictureHeight: 1334, bezel: false)
        XCTAssertLessThan(se.height, 0.8)
        XCTAssertEqual(se.width / se.height, 750.0 / 1334, accuracy: 1e-9)
        // A frame adds to the size, around the same picture.
        let framed = stagePhoneSize(modelCode: "iPhone14,6", pictureWidth: 750, pictureHeight: 1334, bezel: true)
        XCTAssertGreaterThan(framed.height, se.height)
        XCTAssertGreaterThan(framed.width, se.width)
        // Sideways phones come out sideways; no picture yet is a portrait phone.
        let sideways = stagePhoneSize(modelCode: "iPhone18,2", pictureWidth: 2868, pictureHeight: 1320, bezel: false)
        XCTAssertGreaterThan(sideways.width, sideways.height)
        let waiting = stagePhoneSize(modelCode: nil, pictureWidth: 0, pictureHeight: 0, bezel: false)
        XCTAssertEqual(waiting.height, 1, accuracy: 1e-9)
    }
}

final class LatestReleaseTests: XCTestCase {
    private let answer = #"""
    {
      "tag_name": "v0.109",
      "html_url": "https://github.com/justfortonks/mirror-wall/releases/tag/v0.109",
      "body": "## What's new\n\n### October 14, 2026: Android app\n\n- Each release now includes\n  Mirror Wall Cast.\n- Second.\n\n## Install\n\n### Mac\n\nDownload it.",
      "assets": [
        {"name": "MirrorWall-Setup.exe", "browser_download_url": "https://github.com/justfortonks/mirror-wall/releases/download/v0.109/MirrorWall-Setup.exe"},
        {"name": "MirrorWall.dmg", "browser_download_url": "https://github.com/justfortonks/mirror-wall/releases/download/v0.109/MirrorWall.dmg"}
      ]
    }
    """#

    func testReadsGitHubsAnswer() throws {
        let release = try XCTUnwrap(LatestRelease(json: Data(answer.utf8), asset: "MirrorWall.dmg"))
        XCTAssertEqual(release.build, 109)
        XCTAssertEqual(release.version, "0.109")
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "MirrorWall.dmg")
        XCTAssertEqual(release.notes, "October 14, 2026: Android app\n\n• Each release now includes Mirror Wall Cast.\n• Second.")
        XCTAssertNil(LatestRelease(json: Data(answer.utf8), asset: "Other.zip")?.downloadURL)
    }

    func testTags() {
        XCTAssertEqual(BuildNumber(tag: "v0.109"), BuildNumber(build: 109))
        XCTAssertEqual(BuildNumber(tag: "0.7"), BuildNumber(build: 7))
        XCTAssertEqual(BuildNumber(tag: "v0.112-beta.7"), BuildNumber(build: 112, beta: 7))
        XCTAssertEqual(BuildNumber(tag: "v0.112-beta.7")?.version, "0.112 beta 7")
        XCTAssertNil(BuildNumber(tag: "v1.2.3"))
        XCTAssertNil(BuildNumber(tag: "v0.112-rc.1"))
        XCTAssertNil(BuildNumber(tag: "nightly"))
        XCTAssertNil(BuildNumber(tag: ""))
        XCTAssertNil(LatestRelease(json: Data("{}".utf8), asset: "MirrorWall.dmg"))
    }

    func testBetasSortBeforeTheirRelease() {
        XCTAssertLessThan(BuildNumber(build: 112, beta: 7), BuildNumber(build: 112))
        XCTAssertLessThan(BuildNumber(build: 112, beta: 7), BuildNumber(build: 112, beta: 8))
        XCTAssertLessThan(BuildNumber(build: 111), BuildNumber(build: 112, beta: 1))
    }

    func testTheBetaChannelListsEveryTestBuildNewestBuiltFirst() {
        func release(_ tag: String, name: String = "", draft: Bool = false, asset: String = "MirrorWall.dmg") -> String {
            #"{"tag_name": "\#(tag)", "name": "\#(name)", "draft": \#(draft), "body": "", "published_at": "2026-10-16T12:56:54Z", "assets": [{"name": "\#(asset)", "browser_download_url": "https://example.com/\#(tag)/\#(asset)"}]}"#
        }
        let list = "[" + [release("v0.123-beta.48", name: "Mirror Wall 0.123 beta 48: Rename a slot's OBS feed"),
                          release("v0.111"), release("v0.113-beta.9", draft: true), release("v0.125-beta.45"),
                          release("v0.112-beta.8", asset: "MirrorWall-Setup.exe"), release("v0.110")].joined(separator: ",") + "]"
        let choices = LatestRelease.choices(json: Data(list.utf8), asset: "MirrorWall.dmg")
        XCTAssertEqual(choices.map(\.number), [BuildNumber(build: 123, beta: 48), BuildNumber(build: 125, beta: 45), BuildNumber(build: 111)])
        XCTAssertEqual(choices[0].title, "Rename a slot's OBS feed")
        XCTAssertEqual(choices[0].downloadURL?.absoluteString, "https://example.com/v0.123-beta.48/MirrorWall.dmg")
        XCTAssertNotNil(choices[0].published)
        XCTAssertEqual(choices[1].title, "")
        XCTAssertEqual(LatestRelease.choices(json: Data("{}".utf8), asset: "MirrorWall.dmg"), [])
    }

    func testTitles() {
        XCTAssertEqual(LatestRelease.title(in: "Mirror Wall 0.123 beta 48: Fix: names"), "Fix: names")
        XCTAssertEqual(LatestRelease.title(in: "Mirror Wall 0.125 beta 45"), "")
        XCTAssertEqual(LatestRelease.title(in: "Something: else"), "")
    }
}

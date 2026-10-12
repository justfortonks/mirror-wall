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
        XCTAssertTrue(args[args.firstIndex(of: "-vrtp")! + 1].hasSuffix("udpsink host=127.0.0.1 port=5602"))
        XCTAssertEqual(args[args.firstIndex(of: "-d")! + 1], "1")
        XCTAssertFalse(args.contains("-restrict"))
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
